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
/// </summary>
internal sealed class WindowsTrustStore
{
    private const string ApplicationDirectory = "MacKVM";
    private const string PeerFileName = "trusted-peers.json";
    private const string TrustStoreMutexName = @"Local\MacKVM.TrustStore";
    private readonly object gate = new();
    private readonly string path;
    private readonly Dictionary<Guid, PeerIdentity> peers;

    private WindowsTrustStore(string path, Dictionary<Guid, PeerIdentity> peers)
    {
        this.path = path;
        this.peers = peers;
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
        var peers = LoadPeers(path);

        return new WindowsTrustStore(path, peers);
    }

    public bool Matches(PeerIdentity identity)
    {
        lock (gate)
        {
            return peers.TryGetValue(identity.Id, out var trusted)
                && KeysEqual(trusted, identity);
        }
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
                try
                {
                    ReloadLocked();
                    if (!peers.Remove(peerID))
                    {
                        return false;
                    }

                    SaveLocked();
                    return true;
                }
                catch
                {
                    peers.Clear();
                    foreach (var entry in previous)
                    {
                        peers.Add(entry.Key, entry.Value);
                    }

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
    /// Records a completed, user-approved pairing. A changed key remains
    /// fail-closed unless <paramref name="allowKeyReplacement"/> is true.
    /// The return value is true when an existing key was replaced.
    /// </summary>
    public bool Record(
        PeerIdentity identity,
        bool allowKeyReplacement = false
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
                var replacedExistingKey = false;
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
                        }

                        peers[identity.Id] = identity;
                    }
                    else
                    {
                        peers.Add(identity.Id, identity);
                    }

                    SaveLocked();
                    return replacedExistingKey;
                }
                catch
                {
                    // Keep admission decisions consistent with the last
                    // successfully loaded snapshot if persistence fails.
                    peers.Clear();
                    foreach (var entry in previous)
                    {
                        peers.Add(entry.Key, entry.Value);
                    }

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
        peers.Clear();
        foreach (var entry in loaded)
        {
            peers.Add(entry.Key, entry.Value);
        }
    }

    private static Dictionary<Guid, PeerIdentity> LoadPeers(string path)
    {
        var loaded = new Dictionary<Guid, PeerIdentity>();
        if (!File.Exists(path))
        {
            return loaded;
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
        }

        return loaded;
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
                Convert.ToBase64String(peer.SigningPublicKey)
            ))
            .ToArray();
        var temporary = path + $".{Environment.ProcessId}.tmp";
        File.WriteAllBytes(
            temporary,
            JsonSerializer.SerializeToUtf8Bytes(stored)
        );
        File.Move(temporary, path, overwrite: true);
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

    private sealed record StoredPeer(
        Guid Id,
        string Name,
        string SigningPublicKey
    );
}
