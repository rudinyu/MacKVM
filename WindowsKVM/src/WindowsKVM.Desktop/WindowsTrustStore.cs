using System.Security.Cryptography;
using System.Text.Json;
using WindowsKVM.Protocol;

namespace WindowsKVM;

/// <summary>
/// Stores the public identities approved during Windows pairing. Public keys
/// do not require DPAPI, but the file is kept under the current user's
/// LocalAppData directory and written atomically. A changed key for an
/// existing identity is rejected by default; replacement is only possible
/// when the completed pairing flow has obtained an explicit user decision.
/// Newly paired identities explicitly approved by an interactive user default
/// to automatic control approval because the pairing verification is the
/// user's trust decision. One-shot unattended pairing does not persist that
/// control approval; the UI and CLI can revoke or enable it per peer.
/// </summary>
internal sealed class WindowsTrustStore
{
    internal enum ControlAuthorizationState
    {
        Untrusted,
        Unconfigured,
        Authorized,
        Denied
    }

    private const string ApplicationDirectory = "MacKVM";
    private const string PeerFileName = "trusted-peers.json";
    private const string TrustStoreMutexName = @"Local\MacKVM.TrustStore";
    private readonly object gate = new();
    private readonly string path;
    private readonly Dictionary<Guid, PeerIdentity> peers;
    private readonly HashSet<Guid> controlAuthorized;
    private readonly HashSet<Guid> controlAuthorizationConfigured;
    private TrustFileStamp fileStamp;

    private WindowsTrustStore(
        string path,
        Dictionary<Guid, PeerIdentity> peers,
        HashSet<Guid> controlAuthorized,
        HashSet<Guid> controlAuthorizationConfigured,
        TrustFileStamp fileStamp
    )
    {
        this.path = path;
        this.peers = peers;
        this.controlAuthorized = controlAuthorized;
        this.controlAuthorizationConfigured = controlAuthorizationConfigured;
        this.fileStamp = fileStamp;
    }

    public static WindowsTrustStore Load()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                "The Windows trust store requires Windows LocalAppData."
            );
        }

        var directory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            ApplicationDirectory
        );
        var path = Path.Combine(directory, PeerFileName);
        var loaded = LoadPeers(path);

        return new WindowsTrustStore(
            path,
            loaded.Peers,
            loaded.ControlAuthorized,
            loaded.ControlAuthorizationConfigured,
            ReadFileStamp(path)
        );
    }

    public bool Matches(PeerIdentity identity)
    {
        return GetControlAuthorization(identity)
            != ControlAuthorizationState.Untrusted;
    }

    /// <summary>
    /// Returns a stable snapshot of every Mac identity currently trusted by
    /// this Windows account. Each identity owns a copy of its public key so a
    /// caller cannot mutate the store's admission data outside the lock.
    /// </summary>
    public IReadOnlyList<PeerIdentity> Snapshot()
    {
        lock (gate)
        {
            return peers.Values
                .OrderBy(peer => peer.Name, StringComparer.OrdinalIgnoreCase)
                .ThenBy(peer => peer.Id)
                .Select(CloneIdentity)
                .ToArray();
        }
    }

    /// <summary>
    /// Removes one trusted Mac identity and durably persists the new snapshot.
    /// The operation is transactional across processes: a failed write
    /// restores the last successfully loaded in-memory state.
    /// </summary>
    public bool Remove(Guid peerID)
    {
        if (peerID == Guid.Empty)
        {
            throw new ArgumentException("The peer ID must not be empty.", nameof(peerID));
        }

        lock (gate)
        {
            using var processMutex = new Mutex(false, TrustStoreMutexName);
            var ownsProcessMutex = false;
            try
            {
                try
                {
                    processMutex.WaitOne();
                    ownsProcessMutex = true;
                }
                catch (AbandonedMutexException)
                {
                    ownsProcessMutex = true;
                }

                var previous = new Dictionary<Guid, PeerIdentity>(peers);
                var previousAuthorizations = new HashSet<Guid>(controlAuthorized);
                var previousConfigured = new HashSet<Guid>(controlAuthorizationConfigured);
                try
                {
                    ReloadLocked();
                    if (!peers.Remove(peerID))
                    {
                        return false;
                    }
                    controlAuthorized.Remove(peerID);
                    controlAuthorizationConfigured.Remove(peerID);

                    SaveLocked();
                    return true;
                }
                catch
                {
                    RestoreLocked(
                        previous,
                        previousAuthorizations,
                        previousConfigured
                    );

                    throw;
                }
            }
            finally
            {
                if (ownsProcessMutex)
                {
                    processMutex.ReleaseMutex();
                }
            }
        }
    }

    /// <summary>
    /// Returns whether an incoming identity would replace a different pinned
    /// public key. The pairing receiver uses this only to add a warning to the
    /// verification-code prompt; it does not by itself change trust.
    /// </summary>
    public bool HasDifferentKey(PeerIdentity identity)
    {
        lock (gate)
        {
            return peers.TryGetValue(identity.Id, out var trusted)
                && !KeysEqual(trusted, identity);
        }
    }

    /// <summary>
    /// Returns whether this Windows account has enabled automatic remote
    /// control for the currently pinned public key of a peer. The decision is
    /// local-only and is never inferred from a peer ID without checking that
    /// the peer remains trusted.
    /// </summary>
    public bool IsControlAuthorized(Guid peerID)
        => peerID != Guid.Empty
            && IsControlAuthorizedForPeerID(peerID);

    /// <summary>
    /// Returns the durable control decision for the exact authenticated public
    /// key. This refreshes when another WindowsKVM process atomically replaces
    /// the trust file, so Forget, key replacement, and --deny-control take
    /// effect in an already-running receiver without a restart.
    /// </summary>
    public ControlAuthorizationState GetControlAuthorization(PeerIdentity identity)
    {
        if (identity.Id == Guid.Empty)
        {
            return ControlAuthorizationState.Untrusted;
        }

        lock (gate)
        {
            using var processMutex = new Mutex(false, TrustStoreMutexName);
            var ownsProcessMutex = false;
            try
            {
                try
                {
                    processMutex.WaitOne();
                    ownsProcessMutex = true;
                }
                catch (AbandonedMutexException)
                {
                    ownsProcessMutex = true;
                }

                RefreshIfChangedLocked();
                if (!peers.TryGetValue(identity.Id, out var trusted)
                    || !KeysEqual(trusted, identity))
                {
                    return ControlAuthorizationState.Untrusted;
                }

                if (!controlAuthorizationConfigured.Contains(identity.Id))
                {
                    return ControlAuthorizationState.Unconfigured;
                }

                return controlAuthorized.Contains(identity.Id)
                    ? ControlAuthorizationState.Authorized
                    : ControlAuthorizationState.Denied;
            }
            finally
            {
                if (ownsProcessMutex)
                {
                    processMutex.ReleaseMutex();
                }
            }
        }
    }

    public bool IsControlAuthorized(PeerIdentity identity)
        => GetControlAuthorization(identity)
            == ControlAuthorizationState.Authorized;

    private bool IsControlAuthorizedForPeerID(Guid peerID)
    {
        lock (gate)
        {
            using var processMutex = new Mutex(false, TrustStoreMutexName);
            var ownsProcessMutex = false;
            try
            {
                try
                {
                    processMutex.WaitOne();
                    ownsProcessMutex = true;
                }
                catch (AbandonedMutexException)
                {
                    ownsProcessMutex = true;
                }

                ReloadLocked();
                return peers.ContainsKey(peerID)
                    && controlAuthorizationConfigured.Contains(peerID)
                    && controlAuthorized.Contains(peerID);
            }
            finally
            {
                if (ownsProcessMutex)
                {
                    processMutex.ReleaseMutex();
                }
            }
        }
    }

    /// <summary>
    /// Updates the local remembered-control decision for a pinned peer. The
    /// change is written atomically under the same cross-process mutex as
    /// pairing and Forget, so an external trust-store writer cannot lose a
    /// peer or authorization update. Returns false when the peer is unknown.
    /// </summary>
    public bool SetControlAuthorization(Guid peerID, bool authorized)
    {
        if (peerID == Guid.Empty)
        {
            throw new ArgumentException("The peer ID must not be empty.", nameof(peerID));
        }

        lock (gate)
        {
            using var processMutex = new Mutex(false, TrustStoreMutexName);
            var ownsProcessMutex = false;
            try
            {
                try
                {
                    processMutex.WaitOne();
                    ownsProcessMutex = true;
                }
                catch (AbandonedMutexException)
                {
                    ownsProcessMutex = true;
                }

                var previousPeers = new Dictionary<Guid, PeerIdentity>(peers);
                var previousAuthorizations = new HashSet<Guid>(controlAuthorized);
                var previousConfigured = new HashSet<Guid>(controlAuthorizationConfigured);
                try
                {
                    ReloadLocked();
                    if (!peers.ContainsKey(peerID))
                    {
                        return false;
                    }

                    if (authorized)
                    {
                        controlAuthorized.Add(peerID);
                    }
                    else
                    {
                        controlAuthorized.Remove(peerID);
                    }
                    controlAuthorizationConfigured.Add(peerID);

                    SaveLocked();
                    return true;
                }
                catch
                {
                    RestoreLocked(
                        previousPeers,
                        previousAuthorizations,
                        previousConfigured
                    );
                    throw;
                }
            }
            finally
            {
                if (ownsProcessMutex)
                {
                    processMutex.ReleaseMutex();
                }
            }
        }
    }

    /// <summary>
    /// Records a completed, user-approved pairing. A changed key remains
    /// fail-closed unless <paramref name="allowKeyReplacement"/> is true.
    /// The return value is true when an existing key was replaced. New pins
    /// (including explicitly approved key replacements) start with automatic
    /// control approval enabled only when <paramref
    /// name="enableDefaultControlApproval"/> is true; an existing pin keeps
    /// its current opt-out. Unattended one-shot pairing passes false so a
    /// later resident receiver still asks before granting control.
    /// </summary>
    public bool Record(
        PeerIdentity identity,
        bool allowKeyReplacement = false,
        bool enableDefaultControlApproval = true
    )
    {
        ValidateIdentity(identity);
        lock (gate)
        {
            // The instance-local lock does not protect two WindowsKVM
            // processes from replacing the same trust-file snapshot. Hold a
            // named mutex across reload, merge, and atomic replace.
            using var processMutex = new Mutex(false, TrustStoreMutexName);
            var ownsProcessMutex = false;
            try
            {
                try
                {
                    processMutex.WaitOne();
                    ownsProcessMutex = true;
                }
                catch (AbandonedMutexException)
                {
                    // Ownership transfers to this process after an
                    // abnormal peer exit; reload the durable snapshot before
                    // applying this record.
                    ownsProcessMutex = true;
                }

                var previous = new Dictionary<Guid, PeerIdentity>(peers);
                var previousAuthorizations = new HashSet<Guid>(controlAuthorized);
                var previousConfigured = new HashSet<Guid>(controlAuthorizationConfigured);
                var replacedExistingKey = false;
                var shouldEnableDefaultControlApproval = false;
                try
                {
                    ReloadLocked();
                    var hadExisting = peers.TryGetValue(identity.Id, out var existing);
                    if (hadExisting)
                    {
                        if (!KeysEqual(existing!, identity))
                        {
                            if (!allowKeyReplacement)
                            {
                                throw new InvalidDataException(
                                    "The pairing peer key changed; explicitly approve re-pairing before replacing the old key."
                                );
                            }

                            replacedExistingKey = true;
                            // A new public key is a new trust decision. Never
                            // carry an old control opt-out across key
                            // replacement, even when the peer UUID is reused.
                            controlAuthorized.Remove(identity.Id);
                            controlAuthorizationConfigured.Remove(identity.Id);
                            shouldEnableDefaultControlApproval = true;
                        }

                        peers[identity.Id] = identity;
                    }
                    else
                    {
                        peers.Add(identity.Id, identity);
                        shouldEnableDefaultControlApproval = true;
                    }

                    if (shouldEnableDefaultControlApproval
                        && enableDefaultControlApproval)
                    {
                        controlAuthorized.Add(identity.Id);
                        controlAuthorizationConfigured.Add(identity.Id);
                    }

                    SaveLocked();
                    return replacedExistingKey;
                }
                catch
                {
                    // Keep admission decisions consistent with the last
                    // successfully loaded snapshot if persistence fails.
                    RestoreLocked(
                        previous,
                        previousAuthorizations,
                        previousConfigured
                    );

                    throw;
                }
            }
            finally
            {
                if (ownsProcessMutex)
                {
                    processMutex.ReleaseMutex();
                }
            }
        }
    }

    private void ReloadLocked()
    {
        var loaded = LoadPeers(path);
        RestoreLocked(
            loaded.Peers,
            loaded.ControlAuthorized,
            loaded.ControlAuthorizationConfigured
        );
        fileStamp = ReadFileStamp(path);
    }

    private void RefreshIfChangedLocked()
    {
        var currentStamp = ReadFileStamp(path);
        if (currentStamp == fileStamp)
        {
            return;
        }

        var loaded = LoadPeers(path);
        RestoreLocked(
            loaded.Peers,
            loaded.ControlAuthorized,
            loaded.ControlAuthorizationConfigured
        );
        // Read again after parsing in case an atomic writer replaced the file
        // while it was being loaded. The next admission check will retry if
        // the durable snapshot changed during this refresh.
        fileStamp = ReadFileStamp(path);
    }

    private void RestoreLocked(
        IReadOnlyDictionary<Guid, PeerIdentity> loadedPeers,
        IEnumerable<Guid> loadedAuthorizations,
        IEnumerable<Guid> loadedConfigured
    )
    {
        peers.Clear();
        foreach (var entry in loadedPeers)
        {
            peers.Add(entry.Key, entry.Value);
        }

        controlAuthorized.Clear();
        foreach (var peerID in loadedAuthorizations)
        {
            if (peers.ContainsKey(peerID))
            {
                controlAuthorized.Add(peerID);
            }
        }

        controlAuthorizationConfigured.Clear();
        foreach (var peerID in loadedConfigured)
        {
            if (peers.ContainsKey(peerID))
            {
                controlAuthorizationConfigured.Add(peerID);
            }
        }
    }

    private static LoadedPeers LoadPeers(string path)
    {
        var loaded = new Dictionary<Guid, PeerIdentity>();
        var authorizations = new HashSet<Guid>();
        var configured = new HashSet<Guid>();
        if (!File.Exists(path))
        {
            return new LoadedPeers(loaded, authorizations, configured);
        }

        var stored = JsonSerializer.Deserialize<StoredPeer[]>(
            File.ReadAllBytes(path)
        ) ?? throw new InvalidDataException("The trusted peer file is empty.");
        foreach (var entry in stored)
        {
            var identity = ToIdentity(entry);
            if (loaded.TryGetValue(identity.Id, out var existing)
                && !KeysEqual(existing, identity))
            {
                throw new InvalidDataException(
                    "The trusted peer file contains conflicting identities."
                );
            }

            loaded[identity.Id] = identity;
            // Older trust files did not carry an authorization decision. Keep
            // those records unconfigured so an upgrade never turns an
            // unattended pairing into an implicit automatic-control grant.
            if (entry.ControlAuthorizationConfigured)
            {
                configured.Add(identity.Id);
                if (entry.ControlAuthorized)
                {
                    authorizations.Add(identity.Id);
                }
            }
        }

        return new LoadedPeers(loaded, authorizations, configured);
    }

    private void SaveLocked()
    {
        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        var stored = peers.Values
            .OrderBy(peer => peer.Id)
            .Select(peer => new StoredPeer(
                peer.Id,
                peer.Name,
                Convert.ToBase64String(peer.SigningPublicKey),
                controlAuthorized.Contains(peer.Id),
                controlAuthorizationConfigured.Contains(peer.Id)
            ))
            .ToArray();
        var temporary = path + $".{Environment.ProcessId}.tmp";
        File.WriteAllBytes(
            temporary,
            JsonSerializer.SerializeToUtf8Bytes(stored)
        );
        File.Move(temporary, path, overwrite: true);
        fileStamp = ReadFileStamp(path);
    }

    private static PeerIdentity ToIdentity(StoredPeer stored)
    {
        byte[] key;
        try
        {
            key = Convert.FromBase64String(stored.SigningPublicKey);
        }
        catch (FormatException ex)
        {
            throw new InvalidDataException(
                "The trusted peer public key is not valid base64.",
                ex
            );
        }

        var identity = new PeerIdentity(stored.Id, stored.Name, key);
        ValidateIdentity(identity);
        return identity;
    }

    private static void ValidateIdentity(PeerIdentity identity)
    {
        if (identity.Id == Guid.Empty
            || !PeerIdentity.IsValidDisplayName(identity.Name)
            || identity.SigningPublicKey.Length != 65
            || identity.SigningPublicKey[0] != 0x04)
        {
            throw new InvalidDataException("The trusted peer identity is invalid.");
        }

        using var key = ECDsa.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint
            {
                X = identity.SigningPublicKey[1..33],
                Y = identity.SigningPublicKey[33..65]
            }
        });
    }

    private static bool KeysEqual(PeerIdentity lhs, PeerIdentity rhs)
        => lhs.Id == rhs.Id
            && CryptographicOperations.FixedTimeEquals(
                lhs.SigningPublicKey,
                rhs.SigningPublicKey
            );

    private static PeerIdentity CloneIdentity(PeerIdentity identity)
        => new(identity.Id, identity.Name, identity.SigningPublicKey);

    private static TrustFileStamp ReadFileStamp(string path)
    {
        var info = new FileInfo(path);
        return info.Exists
            ? new TrustFileStamp(true, info.Length, info.LastWriteTimeUtc)
            : new TrustFileStamp(false, 0, DateTime.MinValue);
    }

    private sealed record StoredPeer(
        Guid Id,
        string Name,
        string SigningPublicKey,
        bool ControlAuthorized = false,
        bool ControlAuthorizationConfigured = false
    );

    private sealed record LoadedPeers(
        Dictionary<Guid, PeerIdentity> Peers,
        HashSet<Guid> ControlAuthorized,
        HashSet<Guid> ControlAuthorizationConfigured
    );

    private readonly record struct TrustFileStamp(
        bool Exists,
        long Length,
        DateTime LastWriteTimeUtc
    );
}
