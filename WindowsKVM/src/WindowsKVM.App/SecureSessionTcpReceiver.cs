using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using WindowsKVM.Protocol;

namespace WindowsKVM;

/// <summary>
/// W2 secure-session responder. It authenticates a MacKVM peer that was
/// previously approved by the pairing receiver, completes the signed P-256 /
/// ChaChaPoly handshake, and keeps the encrypted TCP session alive. Windows
/// input capture and control-message handling are intentionally a later step.
/// </summary>
internal sealed class SecureSessionTcpReceiver : IAsyncDisposable
{
    private const int MaximumPendingConnections = 8;
    private const int MaximumPendingUnauthenticatedConnections = 2;
    private const int MaximumConnectionAttemptsPerWindow = 32;
    private const long ConnectionAttemptWindowMilliseconds = 10_000;
    private const int MaximumReadSize = SecureSessionWireCodec.MaximumFramePayloadLength + 4;
    private const int MaximumAuthenticatedPacketCount = 256;
    private const long MaximumAuthenticatedPayloadBytes = 4 * 1024 * 1024;
    private static readonly TimeSpan HandshakeTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan PartialFrameTimeout = TimeSpan.FromSeconds(5);
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
    private readonly HashSet<Guid> activePeerIDs = [];
    private readonly object activePeerLock = new();
    private readonly object signingLock;
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
        object? signingLock = null
    )
    {
        this.credentials = credentials;
        this.trustStore = trustStore;
        this.model = model;
        this.requestedPort = requestedPort;
        this.signingLock = signingLock ?? new object();
        listener = CreateListener(requestedPort);
    }

    public int Port { get; private set; }

    /// <summary>
    /// Faults when the listener or secure Bonjour advertiser exits
    /// unexpectedly. The console entry point observes this task so a dead
    /// secure endpoint cannot remain silently advertised as healthy.
    /// </summary>
    public Task Failure => failure.Task;

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
        SecureSessionChannel? channel = null;
        Guid? activePeerID = null;
        var authenticated = false;
        var unauthenticatedSlotHeld = true;
        long partialFrameDeadline = 0;
        var authenticatedPacketCount = 0;
        long authenticatedPayloadBytes = 0;
        var announcedPayloadWarning = false;
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

                            if (!TryReservePeer(initiator.Sender.Id))
                            {
                                throw new SecureSessionWireException(
                                    SecureSessionWireErrorCode.UnexpectedMessage,
                                    "A secure session for this peer is already active."
                                );
                            }

                            activePeerID = initiator.Sender.Id;
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
                            continue;
                        }

                        // W2 deliberately proves transport authentication
                        // first. Keep the channel alive while the Windows
                        // input/control implementation is developed in the
                        // next step, but do not interpret an encrypted payload
                        // as input yet.
                        authenticatedPacketCount++;
                        authenticatedPayloadBytes += plaintext.LongLength;
                        if (authenticatedPacketCount > MaximumAuthenticatedPacketCount
                            || authenticatedPayloadBytes > MaximumAuthenticatedPayloadBytes)
                        {
                            throw new SecureSessionWireException(
                                SecureSessionWireErrorCode.PayloadTooLarge,
                                "The secure-session authenticated payload budget was exceeded."
                            );
                        }
                        if (!announcedPayloadWarning)
                        {
                            announcedPayloadWarning = true;
                            Console.WriteLine(
                                "Encrypted control payload received; Windows input control "
                                    + "is not enabled in this build."
                            );
                        }
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
}
