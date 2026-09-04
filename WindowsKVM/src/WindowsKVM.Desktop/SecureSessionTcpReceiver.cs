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
    private readonly WindowsInputSink inputSink = new();
    private readonly object activeControlLock = new();
    private Guid? activeControlPeerID;
    private Guid? activeControlRequestID;
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
        Action<bool>? controlStateChanged = null
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
        Volatile.Write(ref remoteInputEnabled, enabled ? 1 : 0);
        if (enabled)
        {
            PublishStatus("Remote keyboard and mouse input is enabled.");
            return;
        }

        Guid? peerID;
        Guid? requestID;
        lock (activeControlLock)
        {
            peerID = activeControlPeerID;
            requestID = activeControlRequestID;
        }

        if (peerID is { } peer && requestID is { } request)
        {
            EndActiveControl(peer, request);
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
        WindowsControlReleaseHotKey? releaseHotKey = null;
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

                        var controlMessage = ControlMessageCodec.Decode(plaintext);
                        if (controlMessage.Kind == ControlMessageKind.RequestControl)
                        {
                            // A hotkey teardown clears the request state before
                            // its network acknowledgement completes. Dispose
                            // the old message-thread registration here, on the
                            // receive loop, before accepting a new request.
                            if (controlRequestID.Value is null && releaseHotKey is not null)
                            {
                                releaseHotKey.Dispose();
                                releaseHotKey = null;
                            }
                            // Disabling remote input releases the shared sink
                            // immediately, while this receive loop may not see
                            // another packet until later. Treat that stale
                            // request as ended so re-enabling the setting does
                            // not leave this connection permanently blocked.
                            if (controlRequestID.Value is { } staleRequest
                                && activePeerID is { } stalePeer
                                && !IsControlActive(stalePeer, staleRequest))
                            {
                                releaseHotKey?.Dispose();
                                releaseHotKey = null;
                                controlRequestID.ClearIf(staleRequest);
                            }
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
                            if (!consent.Allowed
                                || Volatile.Read(ref remoteInputEnabled) == 0
                                || !TryActivateControl(peerIdentity, requestID))
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

                            controlRequestID.Set(requestID, consent.IsOneShot);
                            try
                            {
                                releaseHotKey = new WindowsControlReleaseHotKey(() =>
                                {
                                    _ = EndControlFromHotKeyAsync(
                                        peerID,
                                        requestID,
                                        channel,
                                        stream,
                                        outputLock,
                                        () => controlRequestID.ClearIf(requestID),
                                        token
                                    );
                                });
                            }
                            catch (Exception ex)
                            {
                                EndActiveControl(peerID, requestID);
                                controlRequestID.ClearIf(requestID);
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
                            if (Volatile.Read(ref remoteInputEnabled) == 0)
                            {
                                // A local-only switch can race with one input
                                // frame already buffered by TCP. Ignore it and
                                // clear the request admission state rather than
                                // injecting it or treating it as malformed.
                                if (controlRequestID.Value == requestID)
                                {
                                    if (activePeerID is { } disabledPeer)
                                    {
                                        EndActiveControl(disabledPeer, requestID);
                                    }
                                    controlRequestID.ClearIf(requestID);
                                    releaseHotKey?.Dispose();
                                    releaseHotKey = null;
                                    try
                                    {
                                        await SendControlMessageAsync(
                                            channel,
                                            stream,
                                            outputLock,
                                            new ControlMessage(
                                                ControlMessageKind.EndControl,
                                                requestID
                                            ),
                                            token
                                        );
                                    }
                                    catch (Exception ex) when (ex is IOException
                                        or SocketException
                                        or ObjectDisposedException
                                        or OperationCanceledException)
                                    {
                                        Console.Error.WriteLine(
                                            $"Could not notify MacKVM that remote input was disabled: {ex.Message}"
                                        );
                                    }
                                }
                                continue;
                            }
                            if (activePeerID is null
                                || controlRequestID.Value != requestID
                                || controlMessage.Input is null)
                            {
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

                            // A release hotkey can race with one final packet
                            // already in the TCP receive buffer. It is safe to
                            // ignore that packet after the authenticated grant
                            // has been ended, but an unknown request ID remains
                            // a protocol violation.
                            if (!IsControlActive(activePeerID.Value, requestID))
                            {
                                continue;
                            }

                            try
                            {
                                inputSink.Receive(controlMessage.Input);
                            }
                            catch (WindowsInputException ex)
                            {
                                Console.Error.WriteLine(
                                    $"Windows input injection failed; ending control: {ex.Message}"
                                );
                                EndActiveControl(activePeerID.Value, requestID);
                                controlRequestID.ClearIf(requestID);
                                releaseHotKey?.Dispose();
                                releaseHotKey = null;
                                await SendControlMessageAsync(
                                    channel,
                                    stream,
                                    outputLock,
                                    new ControlMessage(
                                        ControlMessageKind.EndControl,
                                        requestID
                                    ),
                                    token
                                );
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
                                controlRequestID.ClearIf(requestID);
                                releaseHotKey?.Dispose();
                                releaseHotKey = null;
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
                authenticated
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
            releaseHotKey?.Dispose();
            if (activePeerID is { } endingPeer
                && controlRequestID.Value is { } endingRequest)
            {
                EndActiveControl(endingPeer, endingRequest);
            }

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
            return new ControlConsentResult(accepted, IsOneShot: accepted);
        }
        catch (OperationCanceledException) when (promptTimeout.IsCancellationRequested)
        {
            Console.Error.WriteLine("Control request timed out and was denied.");
            return ControlConsentResult.Denied;
        }
    }

    private bool TryActivateControl(PeerIdentity peer, Guid requestID)
    {
        var peerID = peer.Id;
        var activated = false;
        lock (activeControlLock)
        {
            // The local-only setting can change while a consent dialog is
            // open. Re-check it under the same lock as activation so a stale
            // approval can never acquire the Windows input sink.
            if (Volatile.Read(ref remoteInputEnabled) == 0
                || !trustStore.Matches(peer)
                || activeControlRequestID is not null)
            {
                return false;
            }

            inputSink.Begin();
            activeControlPeerID = peerID;
            activeControlRequestID = requestID;
            activated = true;
        }

        PublishControlState(activated);
        return activated;
    }

    private bool IsControlActive(Guid peerID, Guid requestID)
    {
        lock (activeControlLock)
        {
            return activeControlPeerID == peerID
                && activeControlRequestID == requestID
                && inputSink.IsActive;
        }
    }

    private bool EndActiveControl(Guid peerID, Guid requestID)
    {
        var ended = false;
        lock (activeControlLock)
        {
            if (activeControlPeerID != peerID || activeControlRequestID != requestID)
            {
                return false;
            }

            activeControlPeerID = null;
            activeControlRequestID = null;
            inputSink.End();
            ended = true;
        }

        if (ended)
        {
            PublishControlState(false);
        }
        return ended;
    }

    private async Task EndControlFromHotKeyAsync(
        Guid peerID,
        Guid requestID,
        SecureSessionChannel? channel,
        NetworkStream stream,
        SemaphoreSlim outputLock,
        Action clearRequest,
        CancellationToken token
    )
    {
        if (!EndActiveControl(peerID, requestID))
        {
            return;
        }

        // Clear the receive-loop admission state immediately after the local
        // input sink is released. The acknowledgement may be delayed by the
        // network, but a new control request must not be rejected as a second
        // active request during that delay.
        clearRequest();

        Console.WriteLine(
            $"Windows control returned locally by hotkey ({Short(requestID)})."
        );
        PublishStatus("Keyboard/mouse control returned locally by hotkey.");
        if (channel is null)
        {
            return;
        }

        try
        {
            await SendControlMessageAsync(
                channel,
                stream,
                outputLock,
                new ControlMessage(ControlMessageKind.EndControl, requestID),
                token
            ).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is IOException or SocketException
            or ObjectDisposedException or OperationCanceledException)
        {
            Console.Error.WriteLine(
                $"Could not notify MacKVM that Windows control ended: {ex.Message}"
            );
        }
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
        private readonly object gate = new();
        private Guid? value;
        private bool oneShot;

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

        public bool IsOneShot(Guid requestID)
        {
            lock (gate)
            {
                return value == requestID && oneShot;
            }
        }

        public bool ClearIf(Guid requestID)
        {
            lock (gate)
            {
                if (value != requestID)
                {
                    return false;
                }

                value = null;
                oneShot = false;
                return true;
            }
        }
    }

    private readonly record struct ControlConsentResult(bool Allowed, bool IsOneShot)
    {
        public static ControlConsentResult Denied => new(false, false);
    }
}
