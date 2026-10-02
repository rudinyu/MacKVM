using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Security.Cryptography;
using WindowsKVM;
using WindowsKVM.Protocol;

namespace WindowsKVM.Desktop.SelfTest;

/// <summary>
/// Small loopback-only pairing harness. It invokes the receiver handler the
/// same way the existing secure-session harness does, while reserving the
/// receiver's admission slots directly so stress iterations do not consume
/// the listener's connection-attempt budget.
/// </summary>
internal sealed class PairingHarness : IAsyncDisposable
{
    private readonly DeviceCredentials mac;
    private readonly DeviceCredentials windows;
    private readonly PairingTcpReceiver receiver;
    private readonly Func<int>? pairingCompletionCount;
    private int disposed;

    private PairingHarness(
        DeviceCredentials mac,
        DeviceCredentials windows,
        PairingTcpReceiver receiver,
        Func<int>? pairingCompletionCount
    )
    {
        this.mac = mac;
        this.windows = windows;
        this.receiver = receiver;
        this.pairingCompletionCount = pairingCompletionCount;
    }

    public static async Task RunSlotCleanupTestsAsync()
    {
        await RunFaultScenarioAsync(
            consentFailure: new IOException("synthetic consent I/O failure")
        ).ConfigureAwait(false);
        await RunFaultScenarioAsync(
            consentFailure: new InvalidOperationException("synthetic consent failure")
        ).ConfigureAwait(false);
        await RunFaultScenarioAsync(
            peerKeyChangedFailure: new InvalidOperationException(
                "synthetic peer-key lookup failure"
            )
        ).ConfigureAwait(false);
        await RunInitializationFailureAsync().ConfigureAwait(false);
        await RunThrowingCancellationCallbackAsync().ConfigureAwait(false);

        // Direct handler invocation bypasses TryAdmitConnectionAttempt. Keep
        // this bounded secondary stress at 17 iterations to catch a release
        // race without tripping the production 32-attempt/10-second limiter.
        await RunRepeatedFaultScenarioAsync().ConfigureAwait(false);
        await RunRepeatedCompletionFailureScenarioAsync(
            new InvalidOperationException("synthetic pairing persistence failure")
        ).ConfigureAwait(false);
        await RunRepeatedCompletionFailureScenarioAsync(
            new IOException("synthetic pairing trust-store I/O failure")
        ).ConfigureAwait(false);
        await RunConcurrentDisposeAsync().ConfigureAwait(false);
    }

    private static async Task RunFaultScenarioAsync(
        Exception? consentFailure = null,
        Exception? peerKeyChangedFailure = null
    )
    {
        await using var harness = Create(
            consentFailure: consentFailure,
            peerKeyChangedFailure: peerKeyChangedFailure
        );
        await harness.RunHandshakeUntilPromptFailureAsync().ConfigureAwait(false);
        harness.AssertAdmissionSlotsRestored();

        // A second direct admission proves the first handler did not leave a
        // semaphore at its maximum/zero edge and that cleanup remains usable.
        await harness.RunHandshakeUntilPromptFailureAsync().ConfigureAwait(false);
        harness.AssertAdmissionSlotsRestored();
    }

    private static async Task RunRepeatedFaultScenarioAsync()
    {
        await using var harness = Create(
            consentFailure: new IOException("synthetic repeated consent failure")
        );
        for (var iteration = 0; iteration < 17; iteration++)
        {
            await harness.RunHandshakeUntilPromptFailureAsync().ConfigureAwait(false);
            harness.AssertAdmissionSlotsRestored();
        }
    }

    private static async Task RunRepeatedCompletionFailureScenarioAsync(
        Exception failure
    )
    {
        await using var harness = Create(pairingCompletedFailure: failure);
        for (var iteration = 0; iteration < 17; iteration++)
        {
            await harness.RunPairingUntilCompletionFailureAsync()
                .ConfigureAwait(false);
            harness.AssertAdmissionSlotsRestored();
        }
    }

    private static async Task RunInitializationFailureAsync()
    {
        await using var harness = Create();
        harness.ReserveAdmissionSlots();
        var client = new TcpClient();
        try
        {
            var task = harness.InvokeHandler(client, harness.ServerToken);
            await task.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        }
        finally
        {
            client.Close();
        }

        harness.AssertAdmissionSlotsRestored();
    }

    private static async Task RunThrowingCancellationCallbackAsync()
    {
        await using var harness = Create(
            consentFailure: new IOException("synthetic callback cleanup failure"),
            registerThrowingCancellationCallback: true
        );
        await harness.RunHandshakeUntilPromptFailureAsync().ConfigureAwait(false);
        harness.AssertAdmissionSlotsRestored();
    }

    private static async Task RunConcurrentDisposeAsync()
    {
        await using var harness = Create();
        harness.ReserveAdmissionSlots();

        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var outgoing = new TcpClient { NoDelay = true };
        await outgoing.ConnectAsync((IPEndPoint)listener.LocalEndpoint)
            .ConfigureAwait(false);
        using var incoming = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
        listener.Stop();

        var task = harness.InvokeHandler(incoming, harness.ServerToken);
        harness.RegisterPendingConnection(task);
        var disposals = Enumerable.Range(0, 4)
            .Select(_ => harness.receiver.DisposeAsync().AsTask())
            .ToArray();
        await Task.WhenAll(disposals).ConfigureAwait(false);
        await task.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        harness.AssertAdmissionSlotsRestored();
    }

    private static PairingHarness Create(
        Exception? consentFailure = null,
        Exception? peerKeyChangedFailure = null,
        Exception? pairingCompletedFailure = null,
        bool registerThrowingCancellationCallback = false
    )
    {
        var mac = DeviceCredentials.Create("PairingHarnessMac");
        var windows = DeviceCredentials.Create("PairingHarnessWindows");
        var pairingCompletionCount = 0;
        var receiver = new PairingTcpReceiver(
            windows,
            "PairingHarnessWindows",
            requestedPort: 0,
            autoAccept: false,
            pairingCompleted: pairingCompletedFailure is null
                ? null
                : (_, _, _) =>
                {
                    Interlocked.Increment(ref pairingCompletionCount);
                    throw pairingCompletedFailure;
                },
            pairingConsent: consentFailure is null
                && peerKeyChangedFailure is null
                && pairingCompletedFailure is null
                ? null
                : (peer, _, _, token) =>
                {
                    if (registerThrowingCancellationCallback)
                    {
                        token.Register(
                            static () => throw new InvalidOperationException(
                                "synthetic cancellation callback failure"
                            )
                        );
                    }

                    if (consentFailure is not null)
                    {
                        return Task.FromException<bool>(consentFailure);
                    }

                    return Task.FromResult(pairingCompletedFailure is not null);
                },
            peerKeyChanged: peerKeyChangedFailure is null
                ? null
                : _ => throw peerKeyChangedFailure,
            enableConsoleInput: false
        );

        return new PairingHarness(
            mac,
            windows,
            receiver,
            pairingCompletedFailure is null
                ? null
                : () => Volatile.Read(ref pairingCompletionCount)
        );
    }

    private CancellationToken ServerToken
    {
        get
        {
            var field = typeof(PairingTcpReceiver).GetField(
                "cancellation",
                BindingFlags.Instance | BindingFlags.NonPublic
            ) ?? throw new InvalidOperationException("receiver cancellation source missing");
            return ((CancellationTokenSource)(field.GetValue(receiver)
                ?? throw new InvalidOperationException("receiver cancellation source missing")))
                .Token;
        }
    }

    private async Task RunHandshakeUntilPromptFailureAsync()
    {
        ReserveAdmissionSlots();
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var outgoing = new TcpClient { NoDelay = true };
        TcpClient? incoming = null;
        NetworkStream? stream = null;
        try
        {
            await outgoing.ConnectAsync((IPEndPoint)listener.LocalEndpoint)
                .ConfigureAwait(false);
            incoming = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
            incoming.NoDelay = true;
            var task = InvokeHandler(incoming, ServerToken);
            stream = outgoing.GetStream();
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            var session = new PairingSession(
                PairingSessionRole.Initiator,
                mac.Identity,
                mac.PrivateKey,
                localModel: "PairingHarnessMac"
            );
            var buffer = new List<byte>();
            await SendAsync(stream, session.Start(), mac.PrivateKey, cancellation.Token)
                .ConfigureAwait(false);
            var challenge = await ReadAsync(stream, buffer, cancellation.Token)
                .ConfigureAwait(false);
            var reveal = session.Receive(challenge);
            await SendAsync(
                    stream,
                    reveal,
                    mac.PrivateKey,
                    cancellation.Token
                )
                .ConfigureAwait(false);
            var confirmation = await ReadAsync(stream, buffer, cancellation.Token)
                .ConfigureAwait(false);
            var confirmationResult = session.Receive(confirmation);
            Assert(
                confirmationResult.VerificationCode is not null,
                "pairing harness did not reach the responder consent prompt"
            );

            await task.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
        }
        finally
        {
            stream?.Dispose();
            outgoing.Close();
            incoming?.Close();
            listener.Stop();
        }
    }

    private async Task RunPairingUntilCompletionFailureAsync()
    {
        var completionCountBefore = pairingCompletionCount?.Invoke() ?? 0;
        ReserveAdmissionSlots();
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var outgoing = new TcpClient { NoDelay = true };
        TcpClient? incoming = null;
        NetworkStream? stream = null;
        try
        {
            await outgoing.ConnectAsync((IPEndPoint)listener.LocalEndpoint)
                .ConfigureAwait(false);
            incoming = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
            incoming.NoDelay = true;
            var task = InvokeHandler(incoming, ServerToken);
            stream = outgoing.GetStream();
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            var session = new PairingSession(
                PairingSessionRole.Initiator,
                mac.Identity,
                mac.PrivateKey,
                expectedPeer: windows.Identity,
                localModel: "PairingHarnessMac"
            );
            var buffer = new List<byte>();
            await SendAsync(stream, session.Start(), mac.PrivateKey, timeout.Token)
                .ConfigureAwait(false);
            var challenge = await ReadAsync(stream, buffer, timeout.Token)
                .ConfigureAwait(false);
            await SendAsync(
                    stream,
                    session.Receive(challenge),
                    mac.PrivateKey,
                    timeout.Token
                )
                .ConfigureAwait(false);
            var confirmation = await ReadAsync(stream, buffer, timeout.Token)
                .ConfigureAwait(false);
            var confirmationResult = session.Receive(confirmation);
            Assert(
                confirmationResult.VerificationCode is not null,
                "pairing harness did not receive the code to confirm"
            );

            // The injected consent provider represents the Windows user
            // approving the matching code. The Mac test peer then confirms
            // the same code and drives the signed close-barrier exchange until
            // the receiver attempts to persist trust.
            var decision = await ReadAsync(stream, buffer, timeout.Token)
                .ConfigureAwait(false);
            var decisionResult = session.Receive(decision);
            Assert(
                decisionResult.Outbound.Count == 0,
                "the Mac peer should wait for its local code confirmation"
            );
            await SendAsync(
                    stream,
                    session.Confirm(accepted: true),
                    mac.PrivateKey,
                    timeout.Token
                )
                .ConfigureAwait(false);

            while (true)
            {
                var readTask = ReadNextOrEofAsync(stream, buffer, timeout.Token);
                var completed = await Task.WhenAny(task, readTask)
                    .ConfigureAwait(false);
                if (ReferenceEquals(completed, task))
                {
                    break;
                }

                var message = await readTask.ConfigureAwait(false);
                if (message is null)
                {
                    break;
                }

                await SendAsync(
                        stream,
                        session.Receive(message),
                        mac.PrivateKey,
                        timeout.Token
                    )
                    .ConfigureAwait(false);
            }

            await task.WaitAsync(TimeSpan.FromSeconds(2)).ConfigureAwait(false);
            Assert(
                pairingCompletionCount?.Invoke() == completionCountBefore + 1,
                "pairing completion callback did not fail at the persistence boundary"
            );
        }
        finally
        {
            stream?.Dispose();
            outgoing.Close();
            incoming?.Close();
            listener.Stop();
        }
    }

    private Task InvokeHandler(TcpClient client, CancellationToken token)
    {
        var method = typeof(PairingTcpReceiver).GetMethod(
            "HandleConnectionAsync",
            BindingFlags.Instance | BindingFlags.NonPublic
        ) ?? throw new InvalidOperationException("pairing receiver handler missing");
        return (Task)(method.Invoke(receiver, [client, token])
            ?? throw new InvalidOperationException("pairing receiver handler task missing"));
    }

    private void RegisterPendingConnection(Task task)
    {
        var field = typeof(PairingTcpReceiver).GetField(
            "connections",
            BindingFlags.Instance | BindingFlags.NonPublic
        ) ?? throw new InvalidOperationException("pairing connection set missing");
        var connections = (HashSet<Task>)(field.GetValue(receiver)
            ?? throw new InvalidOperationException("pairing connection set missing"));
        lock (connections)
        {
            connections.Add(task);
        }
    }

    private void ReserveAdmissionSlots()
    {
        foreach (var fieldName in new[] { "connectionSlots", "unpairedConnectionSlots" })
        {
            var field = typeof(PairingTcpReceiver).GetField(
                fieldName,
                BindingFlags.Instance | BindingFlags.NonPublic
            ) ?? throw new InvalidOperationException($"receiver semaphore {fieldName} missing");
            ((SemaphoreSlim)(field.GetValue(receiver)
                ?? throw new InvalidOperationException("receiver semaphore missing"))).Wait();
        }
    }

    private void AssertAdmissionSlotsRestored()
    {
        Assert(
            ReadSlotCount("connectionSlots") == 16,
            "pairing connection slot was not restored to 16"
        );
        Assert(
            ReadSlotCount("unpairedConnectionSlots") == 1,
            "pairing unpaired slot was not restored to 1"
        );
    }

    private int ReadSlotCount(string fieldName)
    {
        var field = typeof(PairingTcpReceiver).GetField(
            fieldName,
            BindingFlags.Instance | BindingFlags.NonPublic
        ) ?? throw new InvalidOperationException($"receiver semaphore {fieldName} missing");
        return ((SemaphoreSlim)(field.GetValue(receiver)
            ?? throw new InvalidOperationException("receiver semaphore missing"))).CurrentCount;
    }

    private static async Task SendAsync(
        NetworkStream stream,
        PairingSessionResult result,
        ECDsa signingKey,
        CancellationToken token
    )
    {
        foreach (var message in result.Outbound)
        {
            await stream.WriteAsync(PairingWireCodec.Encode(message, signingKey), token)
                .ConfigureAwait(false);
        }
    }

    private static async Task<PairingEnvelope> ReadAsync(
        NetworkStream stream,
        List<byte> buffer,
        CancellationToken token
    )
    {
        while (true)
        {
            var decoded = PairingWireCodec.DecodeAvailableFrames(buffer);
            if (decoded.Count > 0)
            {
                Assert(decoded.Count == 1, "pairing harness received multiple frames");
                return decoded[0];
            }

            var bytes = new byte[16 * 1024];
            var count = await stream.ReadAsync(bytes, token).ConfigureAwait(false);
            Assert(count > 0, "pairing harness received an unexpected EOF");
            buffer.AddRange(bytes.AsSpan(0, count).ToArray());
        }
    }

    private static async Task<PairingEnvelope?> ReadNextOrEofAsync(
        NetworkStream stream,
        List<byte> buffer,
        CancellationToken token
    )
    {
        while (true)
        {
            var decoded = PairingWireCodec.DecodeAvailableFrames(buffer);
            if (decoded.Count > 0)
            {
                Assert(decoded.Count == 1, "pairing harness received multiple frames");
                return decoded[0];
            }

            var bytes = new byte[16 * 1024];
            var count = await stream.ReadAsync(bytes, token).ConfigureAwait(false);
            if (count == 0)
            {
                return null;
            }
            buffer.AddRange(bytes.AsSpan(0, count).ToArray());
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        await receiver.DisposeAsync().ConfigureAwait(false);
        mac.Dispose();
        windows.Dispose();
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}
