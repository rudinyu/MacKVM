using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Security.Cryptography;
using WindowsKVM;
using WindowsKVM.Protocol;

namespace WindowsKVM.Desktop.SelfTest;

internal sealed class SecureHarness : IAsyncDisposable
{
    private readonly DeviceCredentials mac;
    private readonly DeviceCredentials windows;
    private readonly WindowsTrustStore trustStore;
    private readonly WindowsInputSink inputSink;
    private readonly SecureSessionTcpReceiver receiver;
    private readonly TcpListener listener;
    private readonly TcpClient outgoing;
    private readonly TcpClient incoming;
    private readonly NetworkStream stream;
    private readonly SecureSessionChannel channel;
    private readonly CancellationTokenSource cancellation;
    private readonly List<byte> buffer = new();
    private readonly ECDiffieHellman initiatorKey;
    private readonly string trustPath;
    private readonly HotKeySlot hotKeySlot;
    private int disposed;

    private SecureHarness(
        DeviceCredentials mac,
        DeviceCredentials windows,
        WindowsTrustStore trustStore,
        WindowsInputSink inputSink,
        SecureSessionTcpReceiver receiver,
        TcpListener listener,
        TcpClient outgoing,
        TcpClient incoming,
        NetworkStream stream,
        SecureSessionChannel channel,
        CancellationTokenSource cancellation,
        ECDiffieHellman initiatorKey,
        string trustPath,
        Task session,
        List<WindowsInputEvent> events,
        HotKeySlot hotKeySlot
    )
    {
        this.mac = mac;
        this.windows = windows;
        this.trustStore = trustStore;
        this.inputSink = inputSink;
        this.receiver = receiver;
        this.listener = listener;
        this.outgoing = outgoing;
        this.incoming = incoming;
        this.stream = stream;
        this.channel = channel;
        this.cancellation = cancellation;
        this.initiatorKey = initiatorKey;
        this.trustPath = trustPath;
        this.hotKeySlot = hotKeySlot;
        Session = session;
        Events = events;
    }

    public SecureSessionTcpReceiver Receiver => receiver;
    public Task Session { get; }
    public List<WindowsInputEvent> Events { get; }
    public TestReleaseHotKey? HotKey => hotKeySlot.Value;
    public Guid CurrentRequestID { get; private set; }

    public static async Task<SecureHarness> ConnectAsync(
        bool autoAcceptControl = false,
        Func<string, CancellationToken, Task<bool>>? promptConsent = null,
        Action<bool>? onControlStateChanged = null,
        Action? beforeControlGranted = null
    )
    {
        var mac = DeviceCredentials.Create("SyntheticMac");
        var windows = DeviceCredentials.Create("SyntheticWindows");
        var trustPath = Path.Combine(
            Path.GetTempPath(),
            "mackvm-trust-" + Guid.NewGuid().ToString("N") + ".json"
        );
        WindowsTrustStore? trustStore = null;
        WindowsInputSink? inputSink = null;
        SecureSessionTcpReceiver? receiver = null;
        TcpListener? listener = null;
        TcpClient? outgoing = null;
        TcpClient? incoming = null;
        NetworkStream? stream = null;
        ECDiffieHellman? initiatorKey = null;
        CancellationTokenSource? cancellation = null;
        try
        {
            trustStore = CreateTrustStore(trustPath, mac.Identity);
            var events = new List<WindowsInputEvent>();
            var hotKeySlot = new HotKeySlot();
            inputSink = new WindowsInputSink(
                inputs =>
                {
                    events.AddRange(inputs);
                    return (uint)inputs.Count;
                },
                metric => metric == 78 ? 1920 : 1080
            );
            receiver = new SecureSessionTcpReceiver(
                windows,
                trustStore,
                "SyntheticWindows",
                autoAcceptControl: autoAcceptControl,
                promptConsent: promptConsent,
                controlStateChanged: onControlStateChanged,
                inputSink: inputSink,
                createReleaseHotKey: callback =>
                {
                    hotKeySlot.Value = new TestReleaseHotKey(callback);
                    return hotKeySlot.Value;
                },
                beforeControlGranted: beforeControlGranted
            );

            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            outgoing = new TcpClient { NoDelay = true };
            await outgoing.ConnectAsync((IPEndPoint)listener.LocalEndpoint).ConfigureAwait(false);
            incoming = await listener.AcceptTcpClientAsync().ConfigureAwait(false);
            incoming.NoDelay = true;
            ReserveReceiverSlots(receiver);
            cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var session = InvokeHandleConnection(receiver, incoming, cancellation.Token);
            stream = outgoing.GetStream();
            initiatorKey = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
            var hello = SecureSessionHandshake.Create(
                Guid.NewGuid(),
                SecureSessionRole.Initiator,
                mac.Identity,
                "SyntheticMac",
                initiatorKey
            );
            await stream.WriteAsync(
                SecureSessionWireCodec.Encode(hello, mac.PrivateKey),
                cancellation.Token
            ).ConfigureAwait(false);
            var reply = await ReadWireMessageAsync(
                stream,
                new List<byte>(),
                cancellation.Token
            ).ConfigureAwait(false);
            if (reply.Handshake is null)
            {
                throw new InvalidOperationException("secure-session responder sent no handshake");
            }

            var channel = new SecureSessionChannel(
                SecureSessionRole.Initiator,
                initiatorKey,
                hello,
                reply.Handshake
            );
            var confirmation = channel.Seal(SecureSessionChannel.KeyConfirmation);
            await stream.WriteAsync(
                SecureSessionWireCodec.Encode(confirmation),
                cancellation.Token
            ).ConfigureAwait(false);
            return new SecureHarness(
                mac,
                windows,
                trustStore,
                inputSink,
                receiver,
                listener,
                outgoing,
                incoming,
                stream,
                channel,
                cancellation,
                initiatorKey,
                trustPath,
                session,
                events,
                hotKeySlot
            );
        }
        catch
        {
            cancellation?.Cancel();
            outgoing?.Close();
            incoming?.Close();
            if (receiver is not null)
            {
                await receiver.DisposeAsync().ConfigureAwait(false);
            }
            listener?.Stop();
            stream?.Dispose();
            initiatorKey?.Dispose();
            cancellation?.Dispose();
            inputSink?.Dispose();
            windows.Dispose();
            mac.Dispose();
            TryDelete(trustPath);
            throw;
        }
    }

    public static async Task<SecureHarness> CreateAsync(
        Func<string, CancellationToken, Task<bool>>? promptConsent = null,
        Action<bool>? onControlStateChanged = null,
        Action? beforeControlGranted = null
    ) => await ConnectAsync(
        autoAcceptControl: false,
        promptConsent,
        onControlStateChanged,
        beforeControlGranted
    ).ConfigureAwait(false);

    public Guid NextRequestID() => Guid.NewGuid();

    public async Task<ControlMessage> RequestControlAsync()
    {
        CurrentRequestID = NextRequestID();
        await SendControlAsync(ControlMessage.RequestControl(CurrentRequestID)).ConfigureAwait(false);
        return await ReadControlAsync().ConfigureAwait(false);
    }

    public async Task SendControlAsync(ControlMessage message)
    {
        var frame = SecureSessionWireCodec.Encode(
            channel.Seal(ControlMessageCodec.Encode(message))
        );
        await stream.WriteAsync(frame, cancellation.Token).ConfigureAwait(false);
    }

    public async Task<ControlMessage> ReadControlAsync()
    {
        var message = await ReadWireMessageAsync(stream, buffer, cancellation.Token)
            .ConfigureAwait(false);
        if (message.Packet is null)
        {
            throw new InvalidOperationException("secure-session responder sent no packet");
        }

        return ControlMessageCodec.Decode(channel.Open(message.Packet));
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        cancellation.Cancel();
        outgoing.Close();
        incoming.Close();
        try
        {
            await Session.WaitAsync(TimeSpan.FromSeconds(3)).ConfigureAwait(false);
        }
        catch (Exception) when (Session.IsCompleted)
        {
        }
        await receiver.DisposeAsync().ConfigureAwait(false);
        listener.Stop();
        channel.Dispose();
        initiatorKey.Dispose();
        stream.Dispose();
        cancellation.Dispose();
        inputSink.Dispose();
        windows.Dispose();
        mac.Dispose();
        TryDelete(trustPath);
    }

    private static WindowsTrustStore CreateTrustStore(string path, PeerIdentity peer)
    {
        var trustType = typeof(WindowsTrustStore);
        var stamp = trustType.GetNestedType("TrustFileStamp", BindingFlags.NonPublic)
            ?? throw new InvalidOperationException("trust stamp type missing");
        var ctor = trustType.GetConstructors(BindingFlags.NonPublic | BindingFlags.Instance)
            .Single();
        var store = (WindowsTrustStore)ctor.Invoke([
            path,
            new Dictionary<Guid, PeerIdentity>(),
            new HashSet<Guid>(),
            new HashSet<Guid>(),
            Activator.CreateInstance(stamp)!
        ]);
        store.Record(peer, enableDefaultControlApproval: false);
        return store;
    }

    private static Task InvokeHandleConnection(
        SecureSessionTcpReceiver receiver,
        TcpClient client,
        CancellationToken token
    )
    {
        var method = typeof(SecureSessionTcpReceiver).GetMethod(
            "HandleConnectionAsync",
            BindingFlags.Instance | BindingFlags.NonPublic
        ) ?? throw new InvalidOperationException("receiver connection method missing");
        return (Task)(method.Invoke(receiver, [client, token])
            ?? throw new InvalidOperationException("receiver connection task missing"));
    }

    private static void ReserveReceiverSlots(SecureSessionTcpReceiver receiver)
    {
        foreach (var fieldName in new[] { "connectionSlots", "unauthenticatedSlots" })
        {
            var field = typeof(SecureSessionTcpReceiver).GetField(
                fieldName,
                BindingFlags.Instance | BindingFlags.NonPublic
            ) ?? throw new InvalidOperationException($"receiver semaphore {fieldName} missing");
            ((SemaphoreSlim)(field.GetValue(receiver)
                ?? throw new InvalidOperationException("receiver semaphore missing"))).Wait();
        }
    }

    private static async Task<SecureSessionWireMessage> ReadWireMessageAsync(
        NetworkStream stream,
        List<byte> buffer,
        CancellationToken token
    )
    {
        while (true)
        {
            var decoded = SecureSessionWireCodec.DecodeAvailableFrames(buffer);
            if (decoded.Count > 0)
            {
                if (decoded.Count != 1)
                {
                    throw new InvalidOperationException("unexpected multiple secure-session frames");
                }

                return decoded[0];
            }

            var bytes = new byte[16 * 1024];
            var count = await stream.ReadAsync(bytes, token).ConfigureAwait(false);
            if (count == 0)
            {
                throw new EndOfStreamException();
            }

            buffer.AddRange(bytes.AsSpan(0, count).ToArray());
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    internal sealed class TestReleaseHotKey : IDisposable
    {
        private readonly Action callback;
        private int disposed;

        public TestReleaseHotKey(Action callback)
        {
            this.callback = callback;
        }

        public void Trigger()
        {
            if (Volatile.Read(ref disposed) == 0)
            {
                callback();
            }
        }

        public void Dispose()
        {
            Interlocked.Exchange(ref disposed, 1);
        }
    }

    internal sealed class HotKeySlot
    {
        public TestReleaseHotKey? Value;
    }
}
