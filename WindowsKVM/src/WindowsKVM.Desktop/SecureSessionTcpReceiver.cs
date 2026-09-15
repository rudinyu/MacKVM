using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using WindowsKVM.Protocol;

namespace WindowsKVM;

/// <summary>
/// W3 secure-session responder. It authenticates a MacKVM peer that was
/// previously approved by the pairing receiver, completes the signed P-256 /
/// ChaChaPoly handshake, then receives authenticated control messages and
/// injects keyboard/mouse events through the Windows SendInput API.
/// </summary>
internal sealed class SecureSessionTcpReceiver : IAsyncDisposable
{
    private const int MaximumPendingConnections = 8;
    private const int MaximumPendingUnauthenticatedConnections = 2;
    private const int MaximumConnectionAttemptsPerWindow = 32;
    private const long ConnectionAttemptWindowMilliseconds = 10_000;
    private const int MaximumReadSize = SecureSessionWireCodec.MaximumFramePayloadLength + 4;
    // Match the macOS receiver's sustained input budget. This is deliberately
    // per-second rather than a lifetime cap so ordinary high-polling mice do
    // not disconnect an otherwise healthy authenticated session.
    private const int MaximumAuthenticatedPacketsPerSecond = 8_192;
    private const long MaximumAuthenticatedBytesPerSecond = 8 * 1024 * 1024;
    private static readonly TimeSpan HandshakeTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan PartialFrameTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan ControlPromptTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan TransportUnavailabilityGracePeriod =
        TimeSpan.FromSeconds(SecureSessionLivenessPolicy.TransportUnavailabilityGraceSeconds);
    private static readonly TimeSpan SocketLivenessPollInterval =
        TimeSpan.FromMilliseconds(SecureSessionLivenessPolicy.SocketPollIntervalMilliseconds);
    private static readonly string SecureServiceType = "_mackvm-secure._tcp.local";
    private readonly DeviceCredentials credentials;
    private readonly WindowsTrustStore trustStore;
    private readonly string model;
    private readonly int requestedPort;
    private TcpListener listener;
    private readonly CancellationTokenSource cancellation = new();
    private readonly SemaphoreSlim connectionSlots =
        new(MaximumPendingConnections, MaximumPendingConnections);
    private readonly SemaphoreSlim unauthenticatedSlots =
        new(MaximumPendingUnauthenticatedConnections, MaximumPendingUnauthenticatedConnections);
    private readonly object admissionLock = new();
    private readonly Queue<long> recentConnectionAttempts = [];
    private readonly HashSet<Task> connections = [];
    private readonly object connectionLock = new();
    private readonly object connectionContextLock = new();
    private readonly HashSet<ConnectionContext> pendingConnectionContexts = [];
    private readonly Dictionary<Guid, HashSet<ConnectionContext>> peerConnectionContexts = [];
    private readonly HashSet<Guid> activePeerIDs = [];
    private readonly object activePeerLock = new();
    private readonly object signingLock;
    private readonly bool autoAcceptControl;
    private readonly Func<string, CancellationToken, Task<bool>>? promptConsent;
    private readonly Action<string>? status;
    private readonly Action<bool>? controlStateChanged;
    private readonly WindowsInputSink inputSink;
    private readonly Func<Action, IDisposable> createReleaseHotKey;
    private readonly Action? beforeControlGranted;
    private readonly object activeControlLock = new();
    private Guid? activeControlPeerID;
    private Guid? activeControlRequestID;
    private ActiveControlBinding? activeControlBinding;
    private Task controlEndNotification = Task.CompletedTask;
    private long remoteInputGeneration;
    // The UI can disable remote input without stopping the authenticated
    // transport. Keep this gate separate from the active-control identity so
    // a local-only selection immediately prevents new requests and releases
    // any held Windows inputs.
    private int remoteInputEnabled = 1;
    private MdnsAdvertiser? advertiser;
    private Task? advertiserTask;
    private Task? advertiserMonitorTask;
    private Task? acceptTask;
    private Task? acceptMonitorTask;
    private readonly TaskCompletionSource<bool> failure =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int started;
    private int disposed;

    public SecureSessionTcpReceiver(
        DeviceCredentials credentials,
        WindowsTrustStore trustStore,
        string model,
        int requestedPort = 0,
        object? signingLock = null,
        bool autoAcceptControl = false,
        Func<string, CancellationToken, Task<bool>>? promptConsent = null,
        Action<string>? status = null,
        Action<bool>? controlStateChanged = null,
        WindowsInputSink? inputSink = null,
        Func<Action, IDisposable>? createReleaseHotKey = null,
        Action? beforeControlGranted = null
    )
    {
        this.credentials = credentials;
        this.trustStore = trustStore;
        this.model = model;
        this.requestedPort = requestedPort;
        this.signingLock = signingLock ?? new object();
        this.autoAcceptControl = autoAcceptControl;
        this.promptConsent = promptConsent;
        this.status = status;
        this.controlStateChanged = controlStateChanged;
        this.inputSink = inputSink ?? new WindowsInputSink();
        this.createReleaseHotKey = createReleaseHotKey
            ?? (callback => new WindowsControlReleaseHotKey(callback));
        this.beforeControlGranted = beforeControlGranted;
        listener = CreateListener(requestedPort);
    }

    public int Port { get; private set; }

    /// <summary>
    /// Faults when the listener or secure Bonjour advertiser exits
    /// unexpectedly. The console entry point observes this task so a dead
    /// secure endpoint cannot remain silently advertised as healthy.
    /// </summary>
    public Task Failure => failure.Task;

    /// <summary>
    /// Enables or disables admission of remote keyboard/mouse control. Pairing
    /// and the secure transport remain available when disabled. Disabling the
    /// setting also releases any active Windows input sink immediately.
    /// </summary>
    public void SetRemoteInputEnabled(bool enabled)
    {
        ActiveControlBinding? endedBinding = null;
        IDisposable? detachedHotKey = null;
        var ended = false;
        lock (activeControlLock)
        {
            // Every local-only transition starts a new generation. A consent
            // task that was already in flight must not acquire a grant after
            // disable->enable merely because the setting is enabled again.
            Volatile.Write(ref remoteInputEnabled, enabled ? 1 : 0);
            remoteInputGeneration++;
            if (!enabled
                && activeControlPeerID is { } peerID
                && activeControlRequestID is { } requestID)
            {
                ended = EndActiveControlLocked(
                    peerID,
                    requestID,
                    out endedBinding,
                    out detachedHotKey
                );
                if (endedBinding is not null)
                {
                    QueueControlEndNotificationLocked(endedBinding);
                }
            }
        }

        detachedHotKey?.Dispose();
        if (ended)
        {
            PublishControlState(false);
        }
        if (enabled)
        {
            PublishStatus("Remote keyboard and mouse input is enabled.");
            return;
        }

        PublishStatus(
            "Local Windows input only; remote keyboard and mouse requests are disabled."
        );
    }

    /// <summary>
    /// Immediately revokes any secure sessions that could belong to a peer
    /// whose local trust pin was forgotten. Anonymous handshakes are also
    /// cancelled because they cannot yet be proven unrelated to that peer.
    /// The trust store must be removed before calling this method so a racing
    /// new handshake fails closed at admission.
    /// </summary>
    public void RevokePeer(Guid peerID)
    {
        if (peerID == Guid.Empty)
        {
            return;
        }

        Guid? activeRequestID = null;
        lock (activeControlLock)
        {
            if (activeControlPeerID == peerID)
            {
                activeRequestID = activeControlRequestID;
            }
        }
        if (activeRequestID is { } requestID)
        {
            // Release the Windows input sink immediately. Cancelling the
            // socket below is asynchronous and could otherwise leave an
            // old-key session holding local input until its read loop exits.
            EndActiveControl(peerID, requestID);
        }

        ConnectionContext[] revoked;
        lock (connectionContextLock)
        {
            var selected = new HashSet<ConnectionContext>();
            if (peerConnectionContexts.Remove(peerID, out var peerContexts))
            {
                selected.UnionWith(peerContexts);
            }

            foreach (var context in pendingConnectionContexts)
            {
                if (context.PeerID is null || context.PeerID == peerID)
                {
                    selected.Add(context);
                }
            }

            revoked = selected.ToArray();
        }

        foreach (var context in revoked)
        {
            try
            {
                context.Cancellation.Cancel();
            }
            catch (ObjectDisposedException)
            {
                // The receive loop already reached teardown; closing the
                // socket below is still harmless and idempotent.
            }

            try
            {
                context.Client.Close();
            }
            catch (ObjectDisposedException)
            {
            }
        }

        if (revoked.Length > 0)
        {
            Console.WriteLine(
                $"Secure trust revoked for {Short(peerID)}; "
                    + $"closed {revoked.Length} connection(s)."
            );
            PublishStatus(
                $"Trust revoked for {Short(peerID)}; secure session disconnected."
            );
        }
    }

    public void Start()
    {
        if (Interlocked.Exchange(ref started, 1) != 0)
        {
            return;
        }

        StartListenerWithIPv4Fallback();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        advertiser = new MdnsAdvertiser(
            credentials.Identity,
            model,
            Port,
            enableIPv6: listener.Server.AddressFamily == AddressFamily.InterNetworkV6,
            serviceType: SecureServiceType
        );
        advertiserTask = advertiser.RunAsync();
        advertiserMonitorTask = MonitorBackgroundTaskAsync(
            "secure mDNS advertiser",
            advertiserTask
        );
        acceptTask = AcceptLoopAsync(cancellation.Token);
        acceptMonitorTask = MonitorBackgroundTaskAsync(
            "secure-session listener",
            acceptTask
        );
        Console.WriteLine($"Secure session listener ready on TCP {Port}.");
        PublishStatus($"Secure Connect listener ready on TCP {Port}.");
        Console.WriteLine(
            "Advertised as _mackvm-secure._tcp; only paired Mac identities are accepted."
        );
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        cancellation.Cancel();
        listener.Stop();
        if (advertiser is not null)
        {
            await advertiser.DisposeAsync();
        }

        if (advertiserTask is not null)
        {
            try
            {
                await advertiserTask.ConfigureAwait(false);
            }
            catch (Exception) when (cancellation.IsCancellationRequested)
            {
            }
        }

        var accept = acceptTask;
        if (accept is not null)
        {
            try
            {
                await accept.ConfigureAwait(false);
            }
            catch (Exception) when (cancellation.IsCancellationRequested)
            {
            }
        }

        if (advertiserMonitorTask is not null)
        {
            try
            {
                await advertiserMonitorTask.ConfigureAwait(false);
            }
            catch (Exception) when (cancellation.IsCancellationRequested)
            {
            }
        }

        if (acceptMonitorTask is not null)
        {
            try
            {
                await acceptMonitorTask.ConfigureAwait(false);
            }
            catch (Exception) when (cancellation.IsCancellationRequested)
            {
            }
        }

        Task[] pending;
        lock (connectionLock)
        {
            pending = connections.ToArray();
        }

        try
        {
            await Task.WhenAll(pending).ConfigureAwait(false);
        }
        catch (Exception) when (cancellation.IsCancellationRequested)
        {
        }

        connectionSlots.Dispose();
        unauthenticatedSlots.Dispose();
        inputSink.Dispose();
        cancellation.Dispose();
    }

    private static TcpListener CreateListener(int requestedPort)
    {
        if (Socket.OSSupportsIPv6)
        {
            try
            {
                var listener = new TcpListener(IPAddress.IPv6Any, requestedPort);
                listener.Server.DualMode = true;
                return listener;
            }
            catch (SocketException)
            {
                // Fall back to IPv4 below.
            }
            catch (NotSupportedException)
            {
                // Fall back to IPv4 below.
            }
        }

        return new TcpListener(IPAddress.Any, requestedPort);
    }

    private void StartListenerWithIPv4Fallback()
    {
        try
        {
            listener.Start();
        }
        catch (SocketException ex)
            when (listener.Server.AddressFamily == AddressFamily.InterNetworkV6)
        {
            listener.Stop();
            listener = new TcpListener(IPAddress.Any, requestedPort);
            listener.Start();
            Console.Error.WriteLine(
                $"Dual-stack secure-session listener unavailable; using IPv4: {ex.Message}"
            );
        }
    }

    private bool TryAdmitConnectionAttempt()
    {
        var now = Environment.TickCount64;
        lock (admissionLock)
        {
            while (recentConnectionAttempts.Count > 0
                && now - recentConnectionAttempts.Peek()
                    >= ConnectionAttemptWindowMilliseconds)
            {
                recentConnectionAttempts.Dequeue();
            }

            if (recentConnectionAttempts.Count >= MaximumConnectionAttemptsPerWindow)
            {
                return false;
            }

            recentConnectionAttempts.Enqueue(now);
            return true;
        }
    }

    private async Task MonitorBackgroundTaskAsync(string component, Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
            if (!cancellation.IsCancellationRequested)
            {
                ReportFailure($"{component} stopped unexpectedly.");
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        catch (Exception ex) when (!cancellation.IsCancellationRequested)
        {
            ReportFailure($"{component} failed: {ex.Message}", ex);
        }
    }

    private void ReportFailure(string message, Exception? inner = null)
    {
        Console.Error.WriteLine($"Secure session unavailable: {message}");
        PublishStatus($"Secure Connect unavailable: {message}");
        failure.TrySetException(
            new InvalidOperationException(
                $"The {SecureServiceType} endpoint stopped: {message}",
                inner
            )
        );
        cancellation.Cancel();
        try
        {
            listener.Stop();
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private async Task AcceptLoopAsync(CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(token);
                client.NoDelay = true;
                ConfigureSecureSessionKeepAlive(client);
                PublishStatus(
                    $"Incoming Secure Connect connection from "
                        + $"{client.Client.RemoteEndPoint?.ToString() ?? "unknown endpoint"}."
                );
                if (!TryAdmitConnectionAttempt())
                {
                    Console.Error.WriteLine(
                        "Secure session connection rejected: too many attempts in the last 10 seconds."
                    );
                    client.Close();
                    continue;
                }

                if (!connectionSlots.Wait(0))
                {
                    Console.Error.WriteLine(
                        "Secure session connection rejected: listener is busy."
                    );
                    client.Close();
                    continue;
                }

                // Keep the expensive handshake admission pool smaller than
                // the authenticated-session pool. A slow LAN client can then
                // hold only two unauthenticated sockets instead of starving
                // every later secure connection for the 15-second timeout.
                if (!unauthenticatedSlots.Wait(0))
                {
                    Console.Error.WriteLine(
                        "Secure session connection rejected: too many unauthenticated handshakes."
                    );
                    connectionSlots.Release();
                    client.Close();
                    continue;
                }

                var task = HandleConnectionAsync(client, token);
                lock (connectionLock)
                {
                    connections.Add(task);
                }

                _ = task.ContinueWith(
                    completed =>
                    {
                        lock (connectionLock)
                        {
                            connections.Remove(completed);
                        }
                    },
                    CancellationToken.None,
                    TaskContinuationOptions.ExecuteSynchronously,
                    TaskScheduler.Default
                );
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
        catch (ObjectDisposedException) when (token.IsCancellationRequested)
        {
        }
    }

    private async Task HandleConnectionAsync(
        TcpClient client,
        CancellationToken serverToken
    )
    {
        using var ownedClient = client;
        await using var stream = client.GetStream();
        using var handshakeCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            serverToken
        );
        handshakeCancellation.CancelAfter(HandshakeTimeout);
        var token = handshakeCancellation.Token;
        var connectionContext = new ConnectionContext
        {
            Client = client,
            Cancellation = handshakeCancellation
        };
        RegisterConnectionContext(connectionContext);
        SecureSessionChannel? channel = null;
        Guid? activePeerID = null;
        PeerIdentity? activePeerIdentity = null;
        var authenticated = false;
        var unauthenticatedSlotHeld = true;
        long partialFrameDeadline = 0;
        var authenticatedPayloadBudget = new InboundPayloadBudget(
            MaximumAuthenticatedPacketsPerSecond,
            MaximumAuthenticatedBytesPerSecond
        );
        var controlRequestID = new SessionControlRequestState();
        ActiveControlBinding? currentControlBinding = null;
        Task? livenessTask = null;
        var livenessTimedOut = 0;
        using var outputLock = new SemaphoreSlim(1, 1);
        var buffer = new List<byte>();
        var readBuffer = new byte[16 * 1024];
        var remote = client.Client.RemoteEndPoint?.ToString() ?? "unknown endpoint";
        Console.WriteLine($"Incoming secure-session connection from {remote}.");

        try
        {
            while (!token.IsCancellationRequested)
            {
                var count = await stream.ReadAsync(readBuffer, token);
                if (count == 0)
                {
                    break;
                }

                buffer.AddRange(readBuffer.AsSpan(0, count).ToArray());
                while (true)
                {
                    var messages = SecureSessionWireCodec.DecodeAvailableFrames(buffer);
                    var hasCompleteFrame = SecureSessionWireCodec.HasCompleteFrame(buffer);
                    if (buffer.Count > MaximumReadSize && !hasCompleteFrame)
                    {
                        throw new SecureSessionWireException(
                            SecureSessionWireErrorCode.PayloadTooLarge,
                            "The secure-session receive buffer is too large."
                        );
                    }

                    if (messages.Count == 0)
                    {
                        if (hasCompleteFrame)
                        {
                            throw new SecureSessionWireException(
                                SecureSessionWireErrorCode.InvalidFrame,
                                "The secure-session decoder made no progress."
                            );
                        }

                        break;
                    }

                    foreach (var message in messages)
                    {
                        if (!authenticated && channel is null)
                        {
                            if (message.Kind != SecureSessionWireMessageKind.Handshake
                                || message.Handshake is null
                                || message.Handshake.Role != SecureSessionRole.Initiator)
                            {
                                throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.UnexpectedMessage,
                                    "The first secure-session message must be an initiator handshake."
                                );
                            }

                            var initiator = message.Handshake;
                            if (initiator.Sender.Id == credentials.Identity.Id
                                || !trustStore.Matches(initiator.Sender))
                            {
                                Console.Error.WriteLine(
                                    $"Secure session rejected: peer {Short(initiator.Sender.Id)} "
                                        + "is not a paired identity."
                                );
                                throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.InvalidSignature,
                                    "The secure-session peer is not paired."
                                );
                            }

                            if (initiator.DisconnectSignalVersion
                                != SecureSessionHandshake.CurrentDisconnectSignalVersion)
                            {
                                Console.Error.WriteLine(
                                    $"Secure session rejected: peer {Short(initiator.Sender.Id)} "
                                        + "does not support the authenticated disconnect signal. "
                                        + "Update MacKVM before connecting."
                                );
                                throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.UnsupportedCapability,
                                    "The secure-session disconnect capability is required."
                                );
                            }

                            if (!TryReservePeer(initiator.Sender.Id))
                            {
                                throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.UnexpectedMessage,
                                    "A secure session for this peer is already active."
                                );
                            }

                            activePeerID = initiator.Sender.Id;
                            activePeerIdentity = initiator.Sender;
                            AssociateConnectionContext(
                                connectionContext,
                                initiator.Sender.Id
                            );
                            token.ThrowIfCancellationRequested();
                            using var responderEphemeral = ECDiffieHellman.Create(
                                ECCurve.NamedCurves.nistP256
                            );
                            var responder = SecureSessionHandshake.Create(
                                initiator.SessionID,
                                SecureSessionRole.Responder,
                                credentials.Identity,
                                model,
                                responderEphemeral
                            );
                            channel = new SecureSessionChannel(
                                SecureSessionRole.Responder,
                                responderEphemeral,
                                initiator,
                                responder
                            );
                            byte[] encoded;
                            lock (signingLock)
                            {
                                encoded = SecureSessionWireCodec.Encode(
                                    responder,
                                    credentials.PrivateKey
                                );
                            }

                            await stream.WriteAsync(encoded, token);
                            await stream.FlushAsync(token);
                            Console.WriteLine(
                                $"Secure handshake response sent to {initiator.Sender.Name}."
                            );
                            continue;
                        }

                        if (message.Kind != SecureSessionWireMessageKind.Packet
                            || message.Packet is null
                            || channel is null)
                        {
                            throw new SecureSessionWireException(
                                SecureSessionWireErrorCode.UnexpectedMessage,
                                "A secure session may only receive encrypted packets after handshake."
                            );
                        }

                        var plaintext = channel.Open(message.Packet);
                        if (!authenticated)
                        {
                            if (!CryptographicOperations.FixedTimeEquals(
                                    plaintext,
                                    SecureSessionChannel.KeyConfirmation
                                ))
                            {
                                throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.InvalidSignature,
                                    "The secure-session key confirmation is invalid."
                                );
                            }

                            authenticated = true;
                            if (unauthenticatedSlotHeld)
                            {
                                unauthenticatedSlots.Release();
                                unauthenticatedSlotHeld = false;
                            }
                            handshakeCancellation.CancelAfter(Timeout.InfiniteTimeSpan);
                            livenessTask = MonitorSocketLivenessAsync(
                                client.Client,
                                handshakeCancellation,
                                token,
                                remote,
                                () => Interlocked.Exchange(ref livenessTimedOut, 1)
                            );
                            Console.WriteLine(
                                $"Secure session authenticated with {Short(activePeerID)}."
                            );
                            PublishStatus(
                                $"Secure session authenticated with {Short(activePeerID)}."
                            );
                            continue;
                        }

                        if (SecureSessionControlSignal.IsDisconnect(plaintext))
                        {
                            await SendSecureSignalAsync(
                                channel,
                                stream,
                                outputLock,
                                SecureSessionControlSignal.DisconnectAcknowledgement,
                                token
                            );
                            Console.WriteLine(
                                $"Secure session disconnect received from {Short(activePeerID)}."
                            );
                            return;
                        }

                        if (SecureSessionControlSignal.IsDisconnectAcknowledgement(
                                plaintext
                            ))
                        {
                            throw new SecureSessionWireException(
                                SecureSessionWireErrorCode.UnexpectedMessage,
                                "Unexpected secure-session disconnect acknowledgement."
                            );
                        }

                        if (!authenticatedPayloadBudget.Allows(
                                plaintext.Length,
                                Environment.TickCount64
                            ))
                        {
                            throw new SecureSessionWireException(
                                SecureSessionWireErrorCode.PayloadTooLarge,
                                "The secure-session authenticated payload budget was exceeded."
                            );
                        }

                        // MacKVM sends one encrypted heartbeat at a time after
                        // key confirmation. Keep the response inside the same
                        // authenticated channel and output lock; otherwise a
                        // v2 Mac peer would treat the marker as malformed
                        // control input and tear down the session shortly
                        // after it connects.
                        if (SecureSessionControlSignal.IsHeartbeat(plaintext))
                        {
                            await SendSecureSignalAsync(
                                channel,
                                stream,
                                outputLock,
                                SecureSessionControlSignal.HeartbeatAcknowledgement,
                                token
                            );
                            Console.WriteLine(
                                $"Secure session heartbeat acknowledged for {Short(activePeerID)}."
                            );
                            continue;
                        }

                        if (SecureSessionControlSignal.IsHeartbeatAcknowledgement(
                                plaintext
                            ))
                        {
                            throw new SecureSessionWireException(
                                SecureSessionWireErrorCode.UnexpectedMessage,
                                "Unexpected secure-session heartbeat acknowledgement."
                            );
                        }

                        var controlMessage = ControlMessageCodec.Decode(plaintext);
                        if (controlMessage.Kind == ControlMessageKind.RequestControl)
                        {
                            // A local disable/hotkey teardown may have
                            // retired the previous grant while its EndControl
                            // packet is still being serialized. Do not start a
                            // fresh grant until that notification has reached
                            // the peer, otherwise the peer could observe a
                            // new ControlGranted before the old EndControl.
                            await GetControlEndNotificationBarrier()
                                .WaitAsync(token)
                                .ConfigureAwait(false);

                            // A local teardown may have happened on the UI or
                            // hotkey thread while this receive loop was idle.
                            // Dispose any old registration before allowing a
                            // new grant to attach its callback.
                            controlRequestID.DisposeHotKeyIfIdle();
                            if (controlRequestID.Value is not null)
                            {
                                throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.UnexpectedMessage,
                                    "A secure session cannot contain a second control request."
                                );
                            }

                            var requestID = controlMessage.RequestID
                                ?? throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.InvalidHandshake,
                                    "A control request has no request ID."
                                );
                            var peerID = activePeerID
                                ?? throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.InvalidHandshake,
                                    "The authenticated peer identity is missing."
                                );
                            var inputGeneration = Volatile.Read(
                                ref remoteInputGeneration
                            );
                            if (Volatile.Read(ref remoteInputEnabled) == 0)
                            {
                                await SendControlMessageAsync(
                                    channel,
                                    stream,
                                    outputLock,
                                    new ControlMessage(
                                        ControlMessageKind.ControlDenied,
                                        requestID
                                    ),
                                    token
                                );
                                Console.WriteLine(
                                    $"Denied Windows control request {Short(requestID)} "
                                        + "(remote input is disabled)."
                                );
                                PublishStatus(
                                    "Remote control request denied: local Windows input only."
                                );
                                continue;
                            }
                            var peerIdentity = activePeerIdentity
                                ?? throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.InvalidHandshake,
                                    "The authenticated peer identity is missing."
                                );
                            var consent = await RequestControlConsentAsync(
                                controlMessage,
                                peerIdentity,
                                token
                            );
                            currentControlBinding = null;
                            if (!consent.Allowed
                                || Volatile.Read(ref remoteInputEnabled) == 0
                                || !TryActivateControl(
                                    peerIdentity,
                                    requestID,
                                    inputGeneration,
                                    controlRequestID,
                                    consent.IsOneShot,
                                    () => SendControlMessageAsync(
                                        channel,
                                        stream,
                                        outputLock,
                                        new ControlMessage(
                                            ControlMessageKind.EndControl,
                                            requestID
                                        ),
                                        token
                                    ),
                                    out currentControlBinding
                                ))
                            {
                                await SendControlMessageAsync(
                                    channel,
                                    stream,
                                    outputLock,
                                    new ControlMessage(
                                        ControlMessageKind.ControlDenied,
                                        requestID
                                    ),
                                    token
                                );
                                Console.WriteLine(
                                    $"Denied Windows control request {Short(requestID)}."
                                );
                                continue;
                            }

                            try
                            {
                                var hotKey = createReleaseHotKey(() =>
                                {
                                    _ = EndControlFromHotKeyAsync(
                                        peerID,
                                        requestID
                                    );
                                });
                                if (!controlRequestID.AttachHotKey(requestID, hotKey))
                                {
                                    hotKey.Dispose();
                                    currentControlBinding?.GrantCompletion.TrySetResult(false);
                                    EndActiveControl(peerID, requestID);
                                    await SendControlMessageAsync(
                                        channel,
                                        stream,
                                        outputLock,
                                        new ControlMessage(
                                            ControlMessageKind.ControlDenied,
                                            requestID
                                        ),
                                        token
                                    );
                                    continue;
                                }
                            }
                            catch (Exception ex)
                            {
                                currentControlBinding?.GrantCompletion.TrySetResult(false);
                                EndActiveControl(peerID, requestID);
                                Console.Error.WriteLine(
                                    $"Could not register the Windows release hotkey: {ex.Message}"
                                );
                                await SendControlMessageAsync(
                                    channel,
                                    stream,
                                    outputLock,
                                    new ControlMessage(
                                        ControlMessageKind.ControlDenied,
                                        requestID
                                    ),
                                    token
                                );
                                continue;
                            }

                            // Test and host seams may retire the grant at this
                            // exact boundary. The notification path waits for
                            // GrantCompletion below, so EndControl can never
                            // overtake a ControlGranted already in flight.
                            beforeControlGranted?.Invoke();
                            try
                            {
                                await SendControlMessageAsync(
                                    channel,
                                    stream,
                                    outputLock,
                                    new ControlMessage(
                                        ControlMessageKind.ControlGranted,
                                        requestID
                                    ),
                                    token
                                );
                                currentControlBinding?.GrantCompletion.TrySetResult(true);
                            }
                            catch
                            {
                                currentControlBinding?.GrantCompletion.TrySetResult(false);
                                throw;
                            }
                            Console.WriteLine(
                                $"Windows control granted for {Short(requestID)}. "
                                    + "Ctrl+Alt+Shift+Esc returns input locally."
                            );
                            PublishStatus(
                                $"Keyboard/mouse control granted for {Short(requestID)}."
                            );
                            continue;
                        }

                        if (controlMessage.Kind == ControlMessageKind.Input)
                        {
                            var requestID = controlMessage.RequestID
                                ?? throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.InvalidHandshake,
                                    "An input message has no request ID."
                                );
                            if (activePeerID is null || controlMessage.Input is null)
                            {
                                throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.UnexpectedMessage,
                                    "Input arrived without an active Windows control grant."
                                );
                            }
                            if (controlRequestID.Value != requestID)
                            {
                                // A release hotkey or local-only transition
                                // can leave one final packet in the TCP
                                // receive buffer. Ignore only a bounded,
                                // known-ended request; unknown IDs remain a
                                // protocol violation.
                                if (controlRequestID.IsEnded(requestID))
                                {
                                    continue;
                                }

                                throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.UnexpectedMessage,
                                    "Input arrived without an active Windows control grant."
                                );
                            }
                            if (Volatile.Read(ref remoteInputEnabled) == 0)
                            {
                                // SetRemoteInputEnabled(false) already ended
                                // the grant and sent the EndControl barrier.
                                // This frame may have been buffered before that
                                // transition, so ignore only the ended request.
                                if (controlRequestID.IsEnded(requestID))
                                {
                                    continue;
                                }

                                throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.UnexpectedMessage,
                                    "Input arrived without an active Windows control grant."
                                );
                            }
                            var inputPeer = activePeerIdentity
                                ?? throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.InvalidHandshake,
                                    "The authenticated peer identity is missing."
                                );
                            var authorization = trustStore.GetControlAuthorization(
                                inputPeer
                            );
                            if (authorization is
                                WindowsTrustStore.ControlAuthorizationState.Untrusted)
                            {
                                Console.Error.WriteLine(
                                    $"Secure control authorization changed for {Short(inputPeer.Id)}; ending session."
                                );
                                throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.InvalidSignature,
                                    "The paired peer is no longer authorized for control."
                                );
                            }
                            if (authorization is
                                    WindowsTrustStore.ControlAuthorizationState.Denied
                                && !controlRequestID.IsOneShot(requestID))
                            {
                                Console.Error.WriteLine(
                                    $"Secure control authorization was revoked for {Short(inputPeer.Id)}; ending session."
                                );
                                throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.InvalidSignature,
                                    "The paired peer's remembered control approval was revoked."
                                );
                            }

                            // Check the grant and inject while holding the same
                            // lock used by teardown/new-grant activation. This
                            // prevents an old receive-loop callback from
                            // crossing into a newly activated peer's sink.
                            try
                            {
                                if (!TryReceiveControlInput(
                                    activePeerID.Value,
                                    requestID,
                                    controlMessage.Input
                                ))
                                {
                                    if (controlRequestID.IsEnded(requestID))
                                    {
                                        continue;
                                    }

                                    throw new SecureSessionWireException(
                                        SecureSessionWireErrorCode.UnexpectedMessage,
                                        "Input arrived without an active Windows control grant."
                                    );
                                }
                            }
                            catch (WindowsInputException ex)
                            {
                                Console.Error.WriteLine(
                                    $"Windows input injection failed; ending control: {ex.Message}"
                                );
                                if (EndActiveControl(
                                    activePeerID.Value,
                                    requestID,
                                    out var endedBinding
                                ) && endedBinding is not null)
                                {
                                    await NotifyControlEndedAsync(endedBinding);
                                }
                            }
                            continue;
                        }

                        if (controlMessage.Kind == ControlMessageKind.EndControl)
                        {
                            var requestID = controlMessage.RequestID
                                ?? throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.InvalidHandshake,
                                    "An end-control message has no request ID."
                                );
                            if (activePeerID is not null
                                && controlRequestID.Value == requestID
                                && EndActiveControl(activePeerID.Value, requestID))
                            {
                                Console.WriteLine(
                                    $"Windows control ended by the Mac ({Short(requestID)})."
                                );
                                PublishStatus("Keyboard/mouse control ended by the Mac.");
                            }
                            continue;
                        }

                        throw new SecureSessionWireException(
                            SecureSessionWireErrorCode.UnexpectedMessage,
                            "The Windows responder received an unexpected control response."
                        );
                    }

                    if (!SecureSessionWireCodec.HasCompleteFrame(buffer))
                    {
                        break;
                    }
                }

                if (authenticated)
                {
                    if (buffer.Count == 0)
                    {
                        partialFrameDeadline = 0;
                        handshakeCancellation.CancelAfter(Timeout.InfiniteTimeSpan);
                    }
                    else
                    {
                        var now = Environment.TickCount64;
                        if (partialFrameDeadline == 0)
                        {
                            partialFrameDeadline = now
                                + (long)PartialFrameTimeout.TotalMilliseconds;
                        }

                        var remaining = partialFrameDeadline - now;
                        if (remaining <= 0)
                        {
                            throw new OperationCanceledException(token);
                        }

                        // Re-arm with the original absolute deadline rather
                        // than extending the timeout for every trickle byte.
                        handshakeCancellation.CancelAfter(
                            TimeSpan.FromMilliseconds(remaining)
                        );
                    }
                }
            }
        }
        catch (OperationCanceledException) when (serverToken.IsCancellationRequested)
        {
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine(
                Volatile.Read(ref livenessTimedOut) != 0
                    ? "Secure session transport liveness timed out."
                    : authenticated
                    ? "Secure session partial frame timed out."
                    : "Secure session handshake timed out."
            );
        }
        catch (SecureSessionWireException ex)
        {
            Console.Error.WriteLine(
                $"Secure session rejected: {ex.Code} ({ex.Message})."
            );
        }
        catch (SocketException ex)
        {
            Console.Error.WriteLine(
                $"Secure session socket failed ({ex.SocketErrorCode}): {ex.Message}"
            );
        }
        catch (IOException ex)
        {
            Console.Error.WriteLine($"Secure session connection closed: {ex.Message}");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(
                $"Secure session failed ({ex.GetType().Name}): {ex.Message}"
            );
        }
        finally
        {
            handshakeCancellation.Cancel();
            // If the connection exits between activation and the final grant
            // write, unblock a concurrently scheduled local teardown without
            // emitting a stale EndControl notification.
            currentControlBinding?.GrantCompletion.TrySetResult(false);
            if (livenessTask is not null)
            {
                try
                {
                    await livenessTask.ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is OperationCanceledException
                    or ObjectDisposedException or SocketException)
                {
                }
            }
            if (activePeerID is { } endingPeer
                && controlRequestID.Value is { } endingRequest)
            {
                EndActiveControl(endingPeer, endingRequest);
            }
            controlRequestID.DisposeHotKeyIfIdle();

            UnregisterConnectionContext(connectionContext);
            outputLock.Dispose();
            channel?.Dispose();
            if (activePeerID is { } peerID)
            {
                ReleasePeer(peerID);
            }

            client.Close();
            if (unauthenticatedSlotHeld)
            {
                unauthenticatedSlots.Release();
            }
            connectionSlots.Release();
        }
    }

    private async Task<ControlConsentResult> RequestControlConsentAsync(
        ControlMessage request,
        PeerIdentity peer,
        CancellationToken token
    )
    {
        var peerID = peer.Id;
        var remoteVersion = request.ProtocolVersion
            ?? ControlProtocolCompatibility.MinimumCompatibleVersion;
        var remoteMinimum = request.MinimumProtocolVersion ?? remoteVersion;
        if (remoteVersion < ControlProtocolCompatibility.MinimumCompatibleVersion
            || remoteMinimum > ControlProtocolCompatibility.CurrentVersion
            || remoteMinimum > remoteVersion)
        {
            Console.Error.WriteLine(
                $"Control request from {Short(peerID)} uses an incompatible protocol."
            );
            return ControlConsentResult.Denied;
        }

        var authorization = trustStore.GetControlAuthorization(peer);
        if (authorization is WindowsTrustStore.ControlAuthorizationState.Untrusted)
        {
            Console.Error.WriteLine(
                $"Control request from {Short(peerID)} rejected: trust is no longer current."
            );
            return ControlConsentResult.Denied;
        }

        if (authorization is WindowsTrustStore.ControlAuthorizationState.Authorized)
        {
            Console.WriteLine(
                $"Control request from {Short(peerID)} accepted (remembered approval)."
            );
            PublishStatus(
                "Control request accepted using the remembered local approval."
            );
            return new ControlConsentResult(Allowed: true, IsOneShot: false);
        }

        // A durable explicit deny takes precedence over --yes. The latter is
        // a one-shot convenience, while --deny-control is a local revocation
        // that must also affect an already-running console receiver.
        if (autoAcceptControl
            && authorization is WindowsTrustStore.ControlAuthorizationState.Unconfigured)
        {
            Console.WriteLine(
                $"Control request from {Short(peerID)} accepted (--yes)."
            );
            return new ControlConsentResult(Allowed: true, IsOneShot: true);
        }

        if (promptConsent is null)
        {
            Console.Error.WriteLine(
                "Control request denied because no console consent provider is available."
            );
            return ControlConsentResult.Denied;
        }

        using var promptTimeout = CancellationTokenSource.CreateLinkedTokenSource(token);
        promptTimeout.CancelAfter(ControlPromptTimeout);
        try
        {
            var accepted = await promptConsent(
                $"Allow keyboard/mouse control from {Short(peerID)}? y/N: ",
                promptTimeout.Token
            ).ConfigureAwait(false);
            if (promptTimeout.IsCancellationRequested)
            {
                Console.Error.WriteLine(
                    "Control request consent completed after its deadline; denying it."
                );
                return ControlConsentResult.Denied;
            }
            return new ControlConsentResult(accepted, IsOneShot: accepted);
        }
        catch (OperationCanceledException) when (promptTimeout.IsCancellationRequested)
        {
            Console.Error.WriteLine("Control request timed out and was denied.");
            return ControlConsentResult.Denied;
        }
    }

    private bool TryActivateControl(
        PeerIdentity peer,
        Guid requestID,
        long inputGeneration,
        SessionControlRequestState requestState,
        bool oneShot,
        Func<Task> notifyEndAsync,
        out ActiveControlBinding? activatedBinding
    )
    {
        var peerID = peer.Id;
        var activated = false;
        activatedBinding = null;
        lock (activeControlLock)
        {
            // The local-only setting can change while a consent dialog is
            // open. Re-check it under the same lock as activation so a stale
            // approval can never acquire the Windows input sink.
            if (Volatile.Read(ref remoteInputEnabled) == 0
                || remoteInputGeneration != inputGeneration
                || !trustStore.Matches(peer)
                || activeControlRequestID is not null)
            {
                return false;
            }

            inputSink.Begin();
            requestState.Set(requestID, oneShot);
            activeControlPeerID = peerID;
            activeControlRequestID = requestID;
            activatedBinding = new ActiveControlBinding
            {
                PeerID = peerID,
                RequestID = requestID,
                RequestState = requestState,
                NotifyEndAsync = notifyEndAsync
            };
            activeControlBinding = activatedBinding;
            activated = true;
        }

        PublishControlState(activated);
        return activated;
    }

    private bool TryReceiveControlInput(
        Guid peerID,
        Guid requestID,
        RemoteInputEvent input
    )
    {
        lock (activeControlLock)
        {
            if (activeControlPeerID != peerID
                || activeControlRequestID != requestID
                || !inputSink.IsActive)
            {
                return false;
            }

            inputSink.Receive(input);
            return true;
        }
    }

    private bool EndActiveControl(Guid peerID, Guid requestID)
        => EndActiveControl(peerID, requestID, out _);

    private bool EndActiveControl(
        Guid peerID,
        Guid requestID,
        out ActiveControlBinding? endedBinding
    )
    {
        IDisposable? detachedHotKey;
        lock (activeControlLock)
        {
            var ended = EndActiveControlLocked(
                peerID,
                requestID,
                out endedBinding,
                out detachedHotKey
            );
            if (!ended)
            {
                return false;
            }

            if (endedBinding is not null)
            {
                QueueControlEndNotificationLocked(endedBinding);
            }
        }

        detachedHotKey?.Dispose();
        PublishControlState(false);
        return true;
    }

    private void QueueControlEndNotificationLocked(ActiveControlBinding binding)
    {
        // The caller holds activeControlLock. Publishing the task before the
        // lock is released closes the small race in which a new RequestControl
        // could otherwise observe the old completed barrier and overtake this
        // teardown. NotifyControlEndedAsync is once-only per binding and does
        // not re-enter activeControlLock.
        controlEndNotification = NotifyControlEndedAsync(binding);
    }

    private Task GetControlEndNotificationBarrier()
    {
        lock (activeControlLock)
        {
            return controlEndNotification;
        }
    }

    private bool EndActiveControlLocked(
        Guid peerID,
        Guid requestID,
        out ActiveControlBinding? endedBinding,
        out IDisposable? detachedHotKey
    )
    {
        endedBinding = null;
        detachedHotKey = null;
        if (activeControlPeerID != peerID || activeControlRequestID != requestID)
        {
            return false;
        }

        endedBinding = activeControlBinding;
        activeControlPeerID = null;
        activeControlRequestID = null;
        activeControlBinding = null;
        inputSink.End();
        if (endedBinding is not null)
        {
            endedBinding.RequestState.End(requestID, out detachedHotKey);
        }
        return true;
    }

    private async Task NotifyControlEndedAsync(ActiveControlBinding binding)
    {
        if (Interlocked.Exchange(ref binding.NotificationStarted, 1) != 0)
        {
            return;
        }

        try
        {
            // A local teardown may race with the receive loop's final
            // ControlGranted write. Wait for that write's outcome so MacKVM
            // never observes EndControl before the corresponding grant.
            if (!await binding.GrantCompletion.Task.ConfigureAwait(false))
            {
                return;
            }
            await binding.NotifyEndAsync().ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException
            or SocketException
            or ObjectDisposedException
            or OperationCanceledException)
        {
            Console.Error.WriteLine(
                $"Could not notify MacKVM that Windows control ended: {ex.Message}"
            );
        }
    }

    private async Task EndControlFromHotKeyAsync(
        Guid peerID,
        Guid requestID
    )
    {
        if (!EndActiveControl(peerID, requestID, out var endedBinding)
            || endedBinding is null)
        {
            return;
        }

        Console.WriteLine(
            $"Windows control returned locally by hotkey ({Short(requestID)})."
        );
        PublishStatus("Keyboard/mouse control returned locally by hotkey.");
        await NotifyControlEndedAsync(endedBinding).ConfigureAwait(false);
    }

    private static async Task SendControlMessageAsync(
        SecureSessionChannel channel,
        NetworkStream stream,
        SemaphoreSlim outputLock,
        ControlMessage message,
        CancellationToken token
    )
    {
        var payload = ControlMessageCodec.Encode(message);
        await outputLock.WaitAsync(token).ConfigureAwait(false);
        try
        {
            var packet = channel.Seal(payload);
            var frame = SecureSessionWireCodec.Encode(packet);
            await stream.WriteAsync(frame, token).ConfigureAwait(false);
            await stream.FlushAsync(token).ConfigureAwait(false);
        }
        finally
        {
            outputLock.Release();
        }
    }

    private static void ConfigureSecureSessionKeepAlive(TcpClient client)
    {
        var socket = client.Client;
        try
        {
            socket.SetSocketOption(
                SocketOptionLevel.Socket,
                SocketOptionName.KeepAlive,
                true
            );
            socket.SetSocketOption(
                SocketOptionLevel.Tcp,
                SocketOptionName.TcpKeepAliveTime,
                SecureSessionLivenessPolicy.KeepAliveIdleSeconds
            );
            socket.SetSocketOption(
                SocketOptionLevel.Tcp,
                SocketOptionName.TcpKeepAliveInterval,
                SecureSessionLivenessPolicy.KeepAliveIntervalSeconds
            );
            socket.SetSocketOption(
                SocketOptionLevel.Tcp,
                SocketOptionName.TcpKeepAliveRetryCount,
                SecureSessionLivenessPolicy.KeepAliveProbeCount
            );
            Console.WriteLine(
                "Secure session TCP keepalive configured "
                    + $"(idle={SecureSessionLivenessPolicy.KeepAliveIdleSeconds}s, "
                    + $"interval={SecureSessionLivenessPolicy.KeepAliveIntervalSeconds}s, "
                    + $"probes={SecureSessionLivenessPolicy.KeepAliveProbeCount})."
            );
        }
        catch (Exception ex) when (ex is SocketException
            or PlatformNotSupportedException or ArgumentException)
        {
            if (!OperatingSystem.IsWindows())
            {
                // The portable production-path self-test uses loopback sockets
                // on macOS. The Winsock SIO_KEEPALIVE_VALS fallback is a
                // Windows-only API and must not be probed on that host.
                Console.Error.WriteLine(
                    "Secure session TCP keepalive uses the host OS default "
                        + "outside Windows."
                );
                return;
            }

            // Windows 10 builds that do not expose the explicit TCP options
            // still support the Winsock SIO_KEEPALIVE_VALS compatibility path.
            try
            {
                socket.IOControl(
                    IOControlCode.KeepAliveValues,
                    SecureSessionLivenessPolicy.CreateWindowsKeepAliveValues(),
                    null
                );
                Console.WriteLine(
                    "Secure session TCP keepalive configured using the Winsock compatibility path."
                );
            }
            catch (Exception fallback) when (fallback is SocketException
                or PlatformNotSupportedException or ArgumentException)
            {
                Console.Error.WriteLine(
                    "Secure session TCP keepalive could not be configured; "
                        + $"the OS will use its default liveness policy ({fallback.Message})."
                );
            }
        }
    }

    private static async Task MonitorSocketLivenessAsync(
        Socket socket,
        CancellationTokenSource connectionCancellation,
        CancellationToken token,
        string remote,
        Action markTimedOut
    )
    {
        long? unavailableSince = null;
        try
        {
            while (!token.IsCancellationRequested)
            {
                await Task.Delay(SocketLivenessPollInterval, token).ConfigureAwait(false);
                var hasSocketError = socket.Poll(0, SelectMode.SelectError);
                var hasOrderlyClose = socket.Poll(0, SelectMode.SelectRead)
                    && socket.Available == 0;
                if (!hasSocketError && !hasOrderlyClose)
                {
                    unavailableSince = null;
                    continue;
                }

                var now = Environment.TickCount64;
                unavailableSince ??= now;
                if (now - unavailableSince.Value
                    < (long)TransportUnavailabilityGracePeriod.TotalMilliseconds)
                {
                    continue;
                }

                markTimedOut();
                Console.Error.WriteLine(
                    $"Secure session peer {remote} remained unavailable for "
                        + $"{TransportUnavailabilityGracePeriod.TotalSeconds:0}s; closing."
                );
                connectionCancellation.Cancel();
                return;
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
        catch (ObjectDisposedException)
        {
        }
        catch (SocketException ex)
        {
            markTimedOut();
            Console.Error.WriteLine(
                $"Secure session liveness probe failed for {remote}: {ex.Message}"
            );
            connectionCancellation.Cancel();
        }
    }

    private static async Task SendSecureSignalAsync(
        SecureSessionChannel channel,
        NetworkStream stream,
        SemaphoreSlim outputLock,
        ReadOnlyMemory<byte> signal,
        CancellationToken token
    )
    {
        await outputLock.WaitAsync(token).ConfigureAwait(false);
        try
        {
            var packet = channel.Seal(signal.Span);
            var frame = SecureSessionWireCodec.Encode(packet);
            await stream.WriteAsync(frame, token).ConfigureAwait(false);
            await stream.FlushAsync(token).ConfigureAwait(false);
        }
        finally
        {
            outputLock.Release();
        }
    }

    private void RegisterConnectionContext(ConnectionContext context)
    {
        lock (connectionContextLock)
        {
            pendingConnectionContexts.Add(context);
        }
    }

    private void AssociateConnectionContext(ConnectionContext context, Guid peerID)
    {
        lock (connectionContextLock)
        {
            pendingConnectionContexts.Remove(context);
            context.PeerID = peerID;
            if (!peerConnectionContexts.TryGetValue(peerID, out var contextsForPeer))
            {
                contextsForPeer = [];
                peerConnectionContexts.Add(peerID, contextsForPeer);
            }

            contextsForPeer.Add(context);
        }
    }

    private void UnregisterConnectionContext(ConnectionContext context)
    {
        lock (connectionContextLock)
        {
            pendingConnectionContexts.Remove(context);
            if (context.PeerID is { } peerID
                && peerConnectionContexts.TryGetValue(peerID, out var contextsForPeer))
            {
                contextsForPeer.Remove(context);
                if (contextsForPeer.Count == 0)
                {
                    peerConnectionContexts.Remove(peerID);
                }
            }
        }
    }

    private bool TryReservePeer(Guid peerID)
    {
        lock (activePeerLock)
        {
            return activePeerIDs.Add(peerID);
        }
    }

    private void ReleasePeer(Guid peerID)
    {
        lock (activePeerLock)
        {
            activePeerIDs.Remove(peerID);
        }
    }

    private static string Short(Guid? id)
        => id is null ? "none" : id.Value.ToString("N")[..8];

    private static string Short(Guid id) => id.ToString("N")[..8];

    private sealed class ConnectionContext
    {
        public required TcpClient Client { get; init; }
        public required CancellationTokenSource Cancellation { get; init; }
        public Guid? PeerID { get; set; }
    }

    private sealed class ActiveControlBinding
    {
        public required Guid PeerID { get; init; }
        public required Guid RequestID { get; init; }
        public required SessionControlRequestState RequestState { get; init; }
        public required Func<Task> NotifyEndAsync { get; init; }
        public TaskCompletionSource<bool> GrantCompletion { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int NotificationStarted;
    }

    private void PublishStatus(string message)
    {
        try
        {
            status?.Invoke(message);
        }
        catch
        {
            // A UI observer must never alter secure-session admission or
            // authenticated input handling.
        }
    }

    private void PublishControlState(bool active)
    {
        try
        {
            controlStateChanged?.Invoke(active);
        }
        catch
        {
            // A UI observer must never hold the active-control lock or fault
            // the receive loop.
        }
    }

    private sealed class SessionControlRequestState
    {
        private const int MaximumEndedRequests = 16;
        private readonly object gate = new();
        private readonly Queue<Guid> endedRequestOrder = [];
        private readonly HashSet<Guid> endedRequests = [];
        private Guid? value;
        private bool oneShot;
        private IDisposable? hotKey;

        public Guid? Value
        {
            get
            {
                lock (gate)
                {
                    return value;
                }
            }
        }

        public void Set(Guid? requestID, bool isOneShot = false)
        {
            lock (gate)
            {
                value = requestID;
                oneShot = requestID is not null && isOneShot;
            }
        }

        public bool AttachHotKey(Guid requestID, IDisposable registration)
        {
            lock (gate)
            {
                if (value != requestID || hotKey is not null)
                {
                    return false;
                }

                hotKey = registration;
                return true;
            }
        }

        public void DisposeHotKeyIfIdle()
        {
            IDisposable? registration = null;
            lock (gate)
            {
                if (value is null && hotKey is not null)
                {
                    registration = hotKey;
                    hotKey = null;
                }
            }

            registration?.Dispose();
        }

        public bool IsOneShot(Guid requestID)
        {
            lock (gate)
            {
                return value == requestID && oneShot;
            }
        }

        public bool IsEnded(Guid requestID)
        {
            lock (gate)
            {
                return endedRequests.Contains(requestID);
            }
        }

        public bool End(Guid requestID, out IDisposable? detachedHotKey)
        {
            lock (gate)
            {
                detachedHotKey = null;
                if (value != requestID)
                {
                    return false;
                }

                value = null;
                oneShot = false;
                detachedHotKey = hotKey;
                hotKey = null;
                if (endedRequests.Add(requestID))
                {
                    endedRequestOrder.Enqueue(requestID);
                    while (endedRequestOrder.Count > MaximumEndedRequests)
                    {
                        endedRequests.Remove(endedRequestOrder.Dequeue());
                    }
                }
                return true;
            }
        }

        public bool ClearIf(Guid requestID)
        {
            var ended = End(requestID, out var detachedHotKey);
            detachedHotKey?.Dispose();
            return ended;
        }
    }

    private readonly record struct ControlConsentResult(bool Allowed, bool IsOneShot)
    {
        public static ControlConsentResult Denied => new(false, false);
    }
}
