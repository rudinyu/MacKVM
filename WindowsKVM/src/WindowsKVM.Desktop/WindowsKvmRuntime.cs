using System.Runtime.InteropServices;
using WindowsKVM.Protocol;

namespace WindowsKVM;

/// <summary>
/// Shared WindowsKVM service lifecycle used by both the console receiver and
/// the resident desktop UI. Keeping listener ownership here prevents the UI
/// from starting a second mDNS/TCP stack and gives both hosts the same trust,
/// pairing, and secure-session behavior.
/// </summary>
internal sealed class WindowsKvmRuntime : IAsyncDisposable
{
    public const string ApplicationVersion = "1.02.10";
    public const string ApplicationBuild = "90";

    private readonly DeviceCredentials credentials;
    private readonly WindowsTrustStore trustStore;
    private readonly PairingTcpReceiver pairingReceiver;
    private readonly SecureSessionTcpReceiver? secureReceiver;
    private readonly object signingLock = new();
    private Task? pairingTask;
    private int started;
    private int disposed;

    public WindowsKvmRuntime(
        string requestedName,
        bool autoAccept,
        Func<PeerIdentity, string, bool, CancellationToken, Task<bool>>? pairingConsent = null,
        Func<string, CancellationToken, Task<bool>>? controlConsent = null,
        bool enableConsoleInput = true,
        int pairingPort = 0
    )
    {
        credentials = WindowsIdentityStore.LoadOrCreate(requestedName);
        trustStore = WindowsTrustStore.Load();
        Model = RuntimeInformation.OSArchitecture == Architecture.Arm64
            ? "Windows ARM64"
            : "Windows x64";
        pairingReceiver = new PairingTcpReceiver(
            credentials,
            Model,
            requestedPort: pairingPort,
            autoAccept: autoAccept,
            // Automatic pairing is intended for unattended test runs only.
            // It may create a new pin, but it must never silently replace a
            // different public key for an existing peer. Interactive UI/CLI
            // consent is the explicit authorization required for replacement.
            pairingCompleted: (peer, consentedToKeyReplacement) => RecordPairing(
                peer,
                allowKeyReplacement: consentedToKeyReplacement
            ),
            signingLock: signingLock,
            pairingConsent: pairingConsent,
            peerKeyChanged: trustStore.HasDifferentKey,
            status: PublishStatus,
            enableConsoleInput: enableConsoleInput
        );

        if (SecureSessionCapabilities.ChaCha20Poly1305Supported)
        {
            secureReceiver = new SecureSessionTcpReceiver(
                credentials,
                trustStore,
                Model,
                signingLock: signingLock,
                autoAcceptControl: autoAccept,
                promptConsent: controlConsent ?? pairingReceiver.PromptYesNoAsync,
                status: PublishStatus,
                controlStateChanged: PublishControlState
            );
        }
    }

    public PeerIdentity Identity => credentials.Identity;

    public string Model { get; }

    public bool SecureConnectAvailable => secureReceiver is not null;

    public int PairingPort => pairingReceiver.Port;

    public int SecurePort => secureReceiver?.Port ?? 0;

    public bool IsStarted => Volatile.Read(ref started) != 0;

    public IReadOnlyList<PeerIdentity> TrustedPeers => trustStore.Snapshot();

    /// <summary>
    /// Controls whether a paired Mac may request or deliver keyboard/mouse
    /// input. Pairing and the secure transport remain available when disabled.
    /// </summary>
    public void SetRemoteInputEnabled(bool enabled)
    {
        secureReceiver?.SetRemoteInputEnabled(enabled);
        if (secureReceiver is null && !enabled)
        {
            PublishStatus(
                "Local Windows input only; Secure Connect is unavailable on this build."
            );
        }
    }

    public event Action<string>? StatusChanged;

    public event Action<PeerIdentity>? PairingCompleted;

    public event Action<bool>? ControlStateChanged;

    /// <summary>
    /// Forgets a Windows-side Mac trust pin and tears down any secure session
    /// for that peer. Trust is removed before session cleanup so a concurrent
    /// handshake cannot pass admission during the user action.
    /// </summary>
    public bool ForgetPeer(Guid peerID)
    {
        var removed = trustStore.Remove(peerID);
        if (!removed)
        {
            return false;
        }

        secureReceiver?.RevokePeer(peerID);
        PublishStatus(
            $"Forgot paired Mac {Short(peerID)}; pair again before connecting."
        );
        return true;
    }

    public Task Failure => secureReceiver?.Failure
        ?? Task.CompletedTask;

    public void Start()
    {
        if (Interlocked.Exchange(ref started, 1) != 0)
        {
            return;
        }

        // RunAsync performs the listener bind synchronously up to its first
        // await, then owns the accept loop on the thread pool.
        pairingTask = pairingReceiver.RunAsync();
        secureReceiver?.Start();
        PublishStatus(
            SecureConnectAvailable
                ? "WindowsKVM is running; pairing and Secure Connect are advertised."
                : "WindowsKVM is running; pairing is advertised but Secure Connect is unavailable."
        );
    }

    public async Task WaitForShutdownAsync(CancellationToken token)
    {
        if (!IsStarted)
        {
            throw new InvalidOperationException("The WindowsKVM runtime has not been started.");
        }

        var pairing = pairingTask
            ?? throw new InvalidOperationException("The pairing listener did not start.");
        if (secureReceiver is null)
        {
            await pairing.ConfigureAwait(false);
            return;
        }

        var cancellation = Task.Delay(Timeout.InfiniteTimeSpan, token);
        var completed = await Task.WhenAny(pairing, secureReceiver.Failure, cancellation)
            .ConfigureAwait(false);
        if (completed == cancellation)
        {
            return;
        }

        if (completed == secureReceiver.Failure)
        {
            await secureReceiver.Failure.ConfigureAwait(false);
        }

        await pairing.ConfigureAwait(false);
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        try
        {
            if (secureReceiver is not null)
            {
                await secureReceiver.DisposeAsync().ConfigureAwait(false);
            }

            await pairingReceiver.DisposeAsync().ConfigureAwait(false);
            if (pairingTask is not null)
            {
                try
                {
                    await pairingTask.ConfigureAwait(false);
                }
                catch (Exception) when (secureReceiver is null || secureReceiver.Failure.IsCompleted)
                {
                    // DisposeAsync has already stopped the listener. Any
                    // cancellation-related completion is expected here.
                }
            }
        }
        finally
        {
            credentials.Dispose();
        }
    }

    private void RecordPairing(PeerIdentity peer, bool allowKeyReplacement)
    {
        // Persist before PairingTcpReceiver sends its completion barrier. A
        // UI callback is emitted only after the durable trust record exists.
        // Pairing completion is the result of a signed verification-code
        // exchange and an explicit local consent decision. That consent is
        // the only path that allows a deliberately forgotten/reset identity
        // to replace an older pin; the trust store still rejects replacement
        // for all other callers.
        var replacedExistingKey = trustStore.Record(
            peer,
            allowKeyReplacement: allowKeyReplacement
        );
        try
        {
            PairingCompleted?.Invoke(peer);
        }
        catch
        {
            // Host observers are presentation-only. A callback failure must
            // never turn a durable, authenticated pairing into a transport
            // failure or prevent the completion barrier from being sent.
        }
        PublishStatus(
            replacedExistingKey
                ? $"Re-paired with {peer.Name}; the old key was replaced."
                : $"Paired with {peer.Name}."
        );
    }

    private void PublishStatus(string message)
    {
        try
        {
            StatusChanged?.Invoke(message);
        }
        catch
        {
            // Observers belong to the host UI/logging layer and must never
            // change listener or protocol behavior.
        }
    }

    private void PublishControlState(bool active)
    {
        try
        {
            ControlStateChanged?.Invoke(active);
        }
        catch
        {
            // Host UI observers must never fault a secure-session receive loop.
        }
    }

    private static string Short(Guid peerID) => peerID.ToString("N")[..8];
}
