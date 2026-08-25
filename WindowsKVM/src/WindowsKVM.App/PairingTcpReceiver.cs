using System.Net;
using System.Net.Sockets;
using WindowsKVM.Protocol;

namespace WindowsKVM;

/// <summary>
/// W1 console receiver. It is intentionally limited to pairing and trust
/// establishment; input capture/injection and the encrypted control channel
/// are the next Windows feature step. A MacKVM 1.00.00 peer can discover this
/// listener over mDNS and complete the signed verification flow.
/// </summary>
internal sealed class PairingTcpReceiver : IAsyncDisposable
{
    private sealed class AcceptancePromptBusyException : InvalidOperationException
    {
        public AcceptancePromptBusyException()
            : base("Another pairing confirmation is already waiting for console input.")
        {
        }
    }

    private const int MaximumReadSize = PairingWireCodec.MaximumFramePayloadLength + 4;
    private const int MaximumPendingConnections = 16;
    private const int MaximumPendingUnpairedConnections = 1;
    private const int MaximumConnectionAttemptsPerWindow = 32;
    private const long ConnectionAttemptWindowMilliseconds = 10_000;
    private static readonly TimeSpan PreAuthenticationTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan PairingHandshakeTimeout = TimeSpan.FromSeconds(60);
    private readonly DeviceCredentials credentials;
    private readonly string model;
    private readonly int requestedPort;
    private readonly bool autoAccept;
    private TcpListener listener;
    // ECDsa signing is kept serialized, but a slow network write must never
    // block another connection's challenge or decision.
    private readonly object signingLock = new();
    private readonly CancellationTokenSource cancellation = new();
    private readonly SemaphoreSlim connectionSlots =
        new(MaximumPendingConnections, MaximumPendingConnections);
    private readonly SemaphoreSlim unpairedConnectionSlots =
        new(MaximumPendingUnpairedConnections, MaximumPendingUnpairedConnections);
    private readonly HashSet<Task> connections = [];
    private readonly object connectionLock = new();
    private readonly object consoleInputLock = new();
    private readonly object admissionLock = new();
    private readonly Queue<long> recentConnectionAttempts = [];
    private readonly TaskCompletionSource<bool> stopRequested =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private TaskCompletionSource<string?>? pendingAcceptance;
    private Task? consoleInputTask;
    private MdnsAdvertiser? advertiser;
    private Task? advertiserTask;
    private Task? advertiserMonitorTask;

    public PairingTcpReceiver(
        DeviceCredentials credentials,
        string model,
        int requestedPort,
        bool autoAccept
    )
    {
        this.credentials = credentials;
        this.model = model;
        this.requestedPort = requestedPort;
        this.autoAccept = autoAccept;
        listener = CreateListener(requestedPort);
    }

    public int Port { get; private set; }

    private static TcpListener CreateListener(int requestedPort)
    {
        if (Socket.OSSupportsIPv6)
        {
            try
            {
                var dualStack = new TcpListener(IPAddress.IPv6Any, requestedPort);
                // A dual-mode listener accepts both native IPv6 and IPv4-mapped
                // connections while keeping one stable port for the mDNS SRV
                // record. Fall back to IPv4 below if IPv6 is unavailable.
                dualStack.Server.DualMode = true;
                return dualStack;
            }
            catch (SocketException ex)
            {
                Console.Error.WriteLine(
                    $"IPv6 TCP listener unavailable; falling back to IPv4: {ex.Message}"
                );
            }
            catch (NotSupportedException ex)
            {
                Console.Error.WriteLine(
                    $"Dual-stack TCP listener unavailable; falling back to IPv4: {ex.Message}"
                );
            }
        }

        return new TcpListener(IPAddress.Any, requestedPort);
    }

    public async Task RunAsync()
    {
        StartListenerWithIPv4Fallback();
        Port = ((IPEndPoint)listener.LocalEndpoint).Port;
        advertiser = new MdnsAdvertiser(
            credentials.Identity,
            model,
            Port,
            enableIPv6: listener.Server.AddressFamily == AddressFamily.InterNetworkV6
        );
        advertiserTask = advertiser.RunAsync();
        advertiserMonitorTask = MonitorAdvertiserAsync(advertiserTask);
        Console.WriteLine($"Pairing listener ready on TCP {Port}.");
        Console.WriteLine($"Device: {credentials.Identity.Name} ({credentials.Identity.Id:D})");
        Console.WriteLine("Advertised as _mackvm._tcp; allow the app on Private networks if Windows asks.");
        Console.WriteLine(autoAccept
            ? "Automatic pairing acceptance is enabled for this test run."
            : "When a code appears, compare it with the initiating Mac and type y to accept.");
        Console.WriteLine("Press Ctrl-C or Enter to stop.");

        Console.CancelKeyPress += OnCancelKeyPress;
        consoleInputTask = ConsoleInputLoopAsync(cancellation.Token);
        var acceptTask = AcceptLoopAsync(cancellation.Token);
        await Task.WhenAny(acceptTask, stopRequested.Task, advertiserMonitorTask);
        await StopAsync();
        await acceptTask.ConfigureAwait(false);
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
            // Socket creation and binding are separate operations on
            // TcpListener. A machine may report IPv6 support but still reject
            // the dual-stack bind (for example because only IPv4 is usable on
            // the selected interface). Retry the same requested port with a
            // plain IPv4 listener before giving up.
            listener.Stop();
            listener = new TcpListener(IPAddress.Any, requestedPort);
            try
            {
                listener.Start();
            }
            catch
            {
                listener.Stop();
                throw;
            }

            Console.Error.WriteLine(
                $"Dual-stack TCP listener unavailable; using IPv4: {ex.Message}"
            );
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync();
        connectionSlots.Dispose();
        unpairedConnectionSlots.Dispose();
        cancellation.Dispose();
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
                        "Pairing connection rejected: too many attempts in the last 10 seconds."
                    );
                    client.Close();
                    continue;
                }

                if (!connectionSlots.Wait(0))
                {
                    Console.Error.WriteLine("Pairing connection rejected: listener is busy.");
                    client.Close();
                    continue;
                }

                // A signed request proves possession of a key, not that a
                // human approved the peer. Keep the pre-consent pool small so
                // unauthenticated LAN clients cannot consume every connection
                // slot while waiting for the console decision.
                if (!unpairedConnectionSlots.Wait(0))
                {
                    Console.Error.WriteLine(
                        "Pairing connection rejected: another unconfirmed request is pending."
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

    private async Task HandleConnectionAsync(TcpClient client, CancellationToken serverToken)
    {
        using var ownedClient = client;
        await using var stream = client.GetStream();
        using var handshakeCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            serverToken
        );
        handshakeCancellation.CancelAfter(PreAuthenticationTimeout);
        var token = handshakeCancellation.Token;
        var session = new PairingSession(
            PairingSessionRole.Responder,
            credentials.Identity,
            credentials.PrivateKey,
            localModel: model
        );
        var gate = new object();
        var promptStarted = 0;
        var unpairedSlotReleased = 0;
        Task? promptTask = null;
        using var outputLock = new SemaphoreSlim(1, 1);
        var buffer = new List<byte>();
        var readBuffer = new byte[16 * 1024];

        void ResolveConsent(bool accepted)
        {
            if (Interlocked.Exchange(ref unpairedSlotReleased, 1) != 0)
            {
                return;
            }

            if (accepted)
            {
                // The user has now approved the code. Give the completion
                // exchange its longer window; before this point the short
                // admission timeout remains in force.
                handshakeCancellation.CancelAfter(PairingHandshakeTimeout);
            }
            else
            {
                // A rejection is terminal for this connection. Cancel only
                // this linked handshake token after the decision is queued.
                handshakeCancellation.Cancel();
            }

            unpairedConnectionSlots.Release();
        }

        try
        {
            while (!token.IsCancellationRequested && client.Connected)
            {
                var count = await stream.ReadAsync(readBuffer, token);
                if (count == 0)
                {
                    break;
                }

                buffer.AddRange(readBuffer.AsSpan(0, count).ToArray());
                var messages = PairingWireCodec.DecodeAvailableFrames(buffer);
                // Decode first so a maximum-size complete frame followed by
                // bytes from the next TCP frame is accepted. Only an
                // incomplete remainder is subject to the bounded-buffer cap.
                if (buffer.Count > MaximumReadSize)
                {
                    throw new PairingSessionException("The pairing receive buffer is too large.");
                }
                foreach (var message in messages)
                {
                    // The responder's decision must be serialized before a
                    // concurrently arriving initiator decision can generate a
                    // completion. The prompt task owns the local decision;
                    // wait for it before consuming the next inbound message.
                    if (promptTask is not null)
                    {
                        await promptTask.ConfigureAwait(false);
                        promptTask = null;
                        if (token.IsCancellationRequested)
                        {
                            break;
                        }
                    }

                    PairingSessionResult result;
                    lock (gate)
                    {
                        result = session.Receive(message);
                    }

                    await SendResultAsync(stream, result, outputLock, token);
                    if (result.Terminal)
                    {
                        return;
                    }
                    if (result.VerificationCode is not null
                        && Interlocked.Exchange(ref promptStarted, 1) == 0)
                    {
                        // The pre-authentication deadline protects the
                        // network admission step, but a human needs time to
                        // compare the six-digit code and type a decision.
                        // Move this connection to the longer consent window
                        // before waiting for console input.
                        handshakeCancellation.CancelAfter(PairingHandshakeTimeout);
                        promptTask = PromptForAcceptanceAsync(
                            stream,
                            session,
                            gate,
                            token,
                            result.VerificationCode,
                            outputLock,
                            ResolveConsent
                        );
                    }

                    if (result.Completed)
                    {
                        Console.WriteLine($"Paired with {session.Peer?.Name ?? "peer"}.");
                        return;
                    }
                }
            }
        }
        catch (OperationCanceledException) when (serverToken.IsCancellationRequested)
        {
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("Pairing connection timed out before completion.");
        }
        catch (PairingWireException ex)
        {
            Console.Error.WriteLine($"Pairing connection rejected: {ex.Code}.");
        }
        catch (PairingSessionException ex)
        {
            Console.Error.WriteLine($"Pairing session rejected: {ex.Message}");
        }
        catch (IOException ex)
        {
            Console.Error.WriteLine($"Pairing connection closed: {ex.Message}");
        }
        finally
        {
            // A peer can disconnect while the responder is waiting for local
            // console input. Cancel that prompt before returning so its waiter
            // cannot reserve the console for all later pairing attempts.
            handshakeCancellation.Cancel();
            ResolveConsent(false);
            if (promptTask is not null)
            {
                try
                {
                    await promptTask.ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested)
                {
                }
            }

            client.Close();
            connectionSlots.Release();
        }
    }

    private async Task PromptForAcceptanceAsync(
        NetworkStream stream,
        PairingSession session,
        object gate,
        CancellationToken token,
        string code,
        SemaphoreSlim outputLock,
        Action<bool> resolveConsent
    )
    {
        var accepted = autoAccept;
        if (!autoAccept)
        {
            Console.WriteLine($"Pairing code: {code}");
            Console.Write("Does the initiating Mac show the same code? [y/N] ");
            string? answer;
            try
            {
                answer = await ReadAcceptanceLineAsync(token);
            }
            catch (AcceptancePromptBusyException)
            {
                // There is only one interactive console. Reject a second
                // request immediately instead of leaving its peer waiting for
                // the handshake timeout while the first prompt is active.
                PairingSessionResult rejection;
                lock (gate)
                {
                    rejection = session.Respond(false);
                }

                await SendResultAsync(stream, rejection, outputLock, token);
                resolveConsent(false);
                Console.Error.WriteLine(
                    "Pairing rejected: another confirmation is already waiting for input."
                );
                return;
            }

            accepted = string.Equals(answer?.Trim(), "y", StringComparison.OrdinalIgnoreCase)
                || string.Equals(answer?.Trim(), "yes", StringComparison.OrdinalIgnoreCase);
        }
        else
        {
            Console.WriteLine($"Pairing code: {code} (auto-accepting)");
        }

        PairingSessionResult result;
        try
        {
            lock (gate)
            {
                result = session.Respond(accepted);
            }

            await SendResultAsync(stream, result, outputLock, token);
            resolveConsent(accepted);
            if (result.Completed)
            {
                Console.WriteLine($"Paired with {session.Peer?.Name ?? "peer"}.");
            }
        }
        catch (Exception ex) when (ex is InvalidOperationException
            or PairingSessionException or IOException)
        {
            Console.Error.WriteLine($"Pairing decision failed: {ex.Message}");
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
    }

    /// <summary>
    /// Owns the only Console.ReadLine call in the receiver. A stop request and
    /// a pairing confirmation must never race to consume the same line.
    /// </summary>
    private async Task ConsoleInputLoopAsync(CancellationToken token)
    {
        try
        {
            while (!token.IsCancellationRequested)
            {
                var line = await Task.Run(() => Console.ReadLine(), token);
                TaskCompletionSource<string?>? acceptance;
                lock (consoleInputLock)
                {
                    acceptance = pendingAcceptance;
                    pendingAcceptance = null;
                    if (acceptance is null)
                    {
                        stopRequested.TrySetResult(true);
                    }
                }

                if (acceptance is null)
                {
                    return;
                }

                acceptance.TrySetResult(line);
                if (line is null)
                {
                    stopRequested.TrySetResult(true);
                    return;
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
        }
    }

    private async Task<string?> ReadAcceptanceLineAsync(CancellationToken token)
    {
        var waiter = new TaskCompletionSource<string?>(
            TaskCreationOptions.RunContinuationsAsynchronously
        );
        lock (consoleInputLock)
        {
            if (pendingAcceptance is not null)
            {
                throw new AcceptancePromptBusyException();
            }

            pendingAcceptance = waiter;
        }

        using var cancellationRegistration = token.Register(
            static state => ((TaskCompletionSource<string?>)state!).TrySetCanceled(),
            waiter
        );
        try
        {
            return await waiter.Task.ConfigureAwait(false);
        }
        finally
        {
            lock (consoleInputLock)
            {
                if (ReferenceEquals(pendingAcceptance, waiter))
                {
                    pendingAcceptance = null;
                }
            }
        }
    }

    private async Task SendResultAsync(
        NetworkStream stream,
        PairingSessionResult result,
        SemaphoreSlim outputLock,
        CancellationToken token
    )
    {
        await outputLock.WaitAsync(token);
        try
        {
            foreach (var message in result.Outbound)
            {
                byte[] frame;
                lock (signingLock)
                {
                    frame = PairingWireCodec.Encode(message, credentials.PrivateKey);
                }
                await stream.WriteAsync(frame, token);
                await stream.FlushAsync(token);
            }
        }
        finally
        {
            outputLock.Release();
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

    private async Task MonitorAdvertiserAsync(Task task)
    {
        try
        {
            await task.ConfigureAwait(false);
            if (!cancellation.IsCancellationRequested)
            {
                Console.Error.WriteLine(
                    "mDNS advertiser stopped; stopping the pairing listener."
                );
                stopRequested.TrySetResult(true);
            }
        }
        catch (Exception ex) when (!cancellation.IsCancellationRequested)
        {
            Console.Error.WriteLine($"mDNS advertiser failed: {ex.Message}");
            stopRequested.TrySetResult(true);
        }
    }

    private async Task StopAsync()
    {
        if (cancellation.IsCancellationRequested)
        {
            return;
        }

        cancellation.Cancel();
        Console.CancelKeyPress -= OnCancelKeyPress;
        listener.Stop();
        if (advertiser is not null)
        {
            var advertisingTask = advertiserTask;
            await advertiser.DisposeAsync();
            if (advertisingTask is not null)
            {
                try
                {
                    await advertisingTask;
                }
                catch (Exception) when (cancellation.IsCancellationRequested)
                {
                }
            }
            if (advertiserMonitorTask is not null)
            {
                try
                {
                    await advertiserMonitorTask;
                }
                catch (Exception) when (cancellation.IsCancellationRequested)
                {
                }
            }
        }

        Task[] pending;
        lock (connectionLock)
        {
            pending = connections.ToArray();
        }

        try
        {
            await Task.WhenAll(pending);
        }
        catch (Exception) when (cancellation.IsCancellationRequested)
        {
        }
    }

    private void OnCancelKeyPress(object? sender, ConsoleCancelEventArgs args)
    {
        args.Cancel = true;
        // Let RunAsync observe the normal stop signal and run StopAsync. If we
        // cancel the source here, StopAsync's idempotence guard would skip the
        // listener, mDNS, and connection cleanup.
        stopRequested.TrySetResult(true);
    }
}
