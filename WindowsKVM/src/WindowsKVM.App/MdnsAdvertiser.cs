using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using WindowsKVM.Protocol;

namespace WindowsKVM;

/// <summary>
/// Small, dependency-free dual-stack mDNS responder for the MacKVM pairing
/// service. It only answers the service it owns; it does not browse or modify
/// the Windows Firewall. Windows will show its normal Private-network prompt
/// for the TCP listener, which the user can approve explicitly.
/// </summary>
internal sealed class MdnsAdvertiser : IAsyncDisposable
{
    private static readonly IPAddress IPv4MulticastAddress =
        IPAddress.Parse("224.0.0.251");
    private static readonly IPAddress IPv6MulticastAddress =
        IPAddress.Parse("ff02::fb");
    private const int MulticastPort = 5353;
    private readonly PeerIdentity identity;
    private readonly string model;
    private readonly int port;
    private readonly UdpClient? ipv4Client;
    private readonly UdpClient? ipv6Client;
    private readonly string serviceName;
    private readonly string hostName;
    private readonly string serviceType = "_mackvm._tcp.local";
    private readonly CancellationTokenSource cancellation = new();
    private readonly HashSet<IPAddress> joinedIPv4Interfaces = [];
    private readonly HashSet<int> joinedIPv6Interfaces = [];
    private readonly SemaphoreSlim sendLock = new(1, 1);
    private bool defaultIPv4MulticastMembership;
    private bool defaultIPv6MulticastMembership;
    private int disposed;

    private readonly record struct IPv6Interface(IPAddress Address, int Index);

    public MdnsAdvertiser(
        PeerIdentity identity,
        string model,
        int port,
        bool enableIPv6 = true
    )
    {
        this.identity = identity;
        this.model = model;
        this.port = port;
        serviceName = $"{identity.ServiceName}._mackvm._tcp.local";
        hostName = $"mackvm-{identity.Id:D}.local";
        ipv4Client = TryCreateClient(AddressFamily.InterNetwork);
        ipv6Client = enableIPv6 && Socket.OSSupportsIPv6
            ? TryCreateClient(AddressFamily.InterNetworkV6)
            : null;
        if (ipv4Client is null && ipv6Client is null)
        {
            throw new SocketException((int)SocketError.AddressFamilyNotSupported);
        }

        if (ipv4Client is null)
        {
            Console.Error.WriteLine(
                "mDNS IPv4 socket unavailable; continuing with IPv6 only."
            );
        }
        if (ipv6Client is null && Socket.OSSupportsIPv6)
        {
            Console.Error.WriteLine(
                "mDNS IPv6 socket unavailable; continuing with IPv4 only."
            );
        }
    }

    public async Task RunAsync()
    {
        var tasks = new List<Task>();
        if (ipv4Client is not null)
        {
            tasks.Add(ReceiveLoopAsync(ipv4Client, AddressFamily.InterNetwork));
        }
        if (ipv6Client is not null)
        {
            tasks.Add(ReceiveLoopAsync(ipv6Client, AddressFamily.InterNetworkV6));
        }
        tasks.Add(AnnounceLoopAsync());
        var completed = await Task.WhenAny(tasks);
        if (!cancellation.IsCancellationRequested)
        {
            try
            {
                await completed;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"mDNS advertiser stopped: {ex.Message}");
            }

            // A loop should only finish during cancellation. If it does stop
            // unexpectedly, stop its sibling as well so the receiver can
            // observe the failure instead of keeping an undiscoverable TCP
            // listener alive forever.
            cancellation.Cancel();
        }

        try
        {
            await Task.WhenAll(tasks);
        }
        catch (Exception) when (cancellation.IsCancellationRequested)
        {
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        try
        {
            await SendGoodbyeAsync();
        }
        catch (Exception ex) when (IsTransientNetworkException(ex)
            || ex is ObjectDisposedException)
        {
            Console.Error.WriteLine($"mDNS goodbye failed: {ex.Message}");
        }

        cancellation.Cancel();
        DropMulticastMembership(ipv4Client, IPv4MulticastAddress);
        DropMulticastMembership(ipv6Client, IPv6MulticastAddress);
        ipv4Client?.Dispose();
        ipv6Client?.Dispose();
        await Task.CompletedTask;
    }

    private async Task SendGoodbyeAsync()
    {
        // SendAnnouncementAsync owns the shared send lock. Do not take it
        // here as well: DisposeAsync must never deadlock while sending the
        // two family-specific goodbye packets.
        await SendAnnouncementAsync(
            AddressFamily.InterNetwork,
            endpoint: null,
            recordTtl: 0,
            allowDuringShutdown: true
        );
        await SendAnnouncementAsync(
            AddressFamily.InterNetworkV6,
            endpoint: null,
            recordTtl: 0,
            allowDuringShutdown: true
        );
    }

    private async Task ReceiveLoopAsync(UdpClient socket, AddressFamily family)
    {
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                var result = await socket.ReceiveAsync(cancellation.Token);
                if (ContainsPairingQuery(result.Buffer))
                {
                    await SendAnnouncementAsync(family, result.RemoteEndPoint);
                }
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
                return;
            }
            catch (ObjectDisposedException) when (cancellation.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex) when (IsTransientNetworkException(ex))
            {
                await DelayAfterNetworkErrorAsync(
                    family == AddressFamily.InterNetwork ? "IPv4 receive" : "IPv6 receive",
                    ex
                );
            }
        }
    }

    private async Task AnnounceLoopAsync()
    {
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                await SendAnnouncementAsync(AddressFamily.InterNetwork);
                await SendAnnouncementAsync(AddressFamily.InterNetworkV6);
                await Task.Delay(TimeSpan.FromSeconds(30), cancellation.Token);
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
                return;
            }
            catch (ObjectDisposedException) when (cancellation.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex) when (IsTransientNetworkException(ex))
            {
                await DelayAfterNetworkErrorAsync("announcement", ex);
            }
        }
    }

    private async Task SendAnnouncementAsync(
        AddressFamily family,
        IPEndPoint? endpoint = null,
        uint recordTtl = 120,
        bool allowDuringShutdown = false
    )
    {
        var socket = family == AddressFamily.InterNetwork
            ? ipv4Client
            : ipv6Client;
        if (socket is null)
        {
            return;
        }

        await sendLock.WaitAsync(
            allowDuringShutdown ? CancellationToken.None : cancellation.Token
        );
        try
        {
            var ipv4Addresses = family == AddressFamily.InterNetwork
                ? GetIPv4AddressesSafely()
                : [];
            var ipv6Interfaces = family == AddressFamily.InterNetworkV6
                ? GetIPv6InterfacesSafely()
                : [];
            var addresses = family == AddressFamily.InterNetwork
                ? ipv4Addresses
                : ipv6Interfaces.Select(entry => entry.Address).ToArray();
            EnsureMulticastMembership(family, socket, ipv4Addresses, ipv6Interfaces);
            var packet = MdnsPacket.Build(
                serviceType,
                serviceName,
                hostName,
                identity,
                model,
                port,
                addresses,
                recordTtl
            );

            if (endpoint is not null && !IsMulticast(endpoint.Address))
            {
                await socket.SendAsync(packet, packet.Length, endpoint);
                return;
            }

            if (family == AddressFamily.InterNetwork)
            {
                await SendIPv4MulticastAsync(
                    socket,
                    packet,
                    ipv4Addresses,
                    endpoint,
                    recordTtl
                );
                return;
            }

            await SendIPv6MulticastAsync(
                socket,
                packet,
                ipv6Interfaces,
                endpoint,
                recordTtl
            );
        }
        finally
        {
            sendLock.Release();
        }
    }

    private async Task SendIPv4MulticastAsync(
        UdpClient socket,
        byte[] packet,
        IReadOnlyList<IPAddress> addresses,
        IPEndPoint? endpoint,
        uint recordTtl
    )
    {
        var target = endpoint ?? new IPEndPoint(IPv4MulticastAddress, MulticastPort);
        if (addresses.Count == 0)
        {
            await socket.SendAsync(packet, packet.Length, target);
            return;
        }

        // A UdpClient without an explicit interface uses the Windows default
        // route. Send once per active adapter so a Mac on any local LAN can
        // discover this peer.
        foreach (var address in addresses)
        {
            try
            {
                socket.Client.SetSocketOption(
                    SocketOptionLevel.IP,
                    SocketOptionName.MulticastInterface,
                    address.GetAddressBytes()
                );
                await socket.SendAsync(packet, packet.Length, target);
            }
            catch (Exception ex) when (IsTransientNetworkException(ex))
            {
                Console.Error.WriteLine(
                    $"mDNS IPv4 announcement failed on {address}: {ex.Message}"
                );
            }
        }
    }

    private async Task SendIPv6MulticastAsync(
        UdpClient socket,
        byte[] packet,
        IReadOnlyList<IPv6Interface> interfaces,
        IPEndPoint? endpoint,
        uint recordTtl
    )
    {
        if (interfaces.Count == 0)
        {
            var target = endpoint ?? new IPEndPoint(IPv6MulticastAddress, MulticastPort);
            await socket.SendAsync(packet, packet.Length, target);
            return;
        }

        foreach (var networkInterface in interfaces)
        {
            try
            {
                socket.Client.SetSocketOption(
                    SocketOptionLevel.IPv6,
                    SocketOptionName.MulticastInterface,
                    networkInterface.Index
                );
                var target = endpoint ?? new IPEndPoint(
                    WithScope(IPv6MulticastAddress, networkInterface.Index),
                    MulticastPort
                );
                await socket.SendAsync(packet, packet.Length, target);
            }
            catch (Exception ex) when (IsTransientNetworkException(ex))
            {
                Console.Error.WriteLine(
                    $"mDNS IPv6 announcement failed on interface "
                        + $"{networkInterface.Index}: {ex.Message}"
                );
            }
        }
    }

    private void EnsureMulticastMembership(
        AddressFamily family,
        UdpClient socket,
        IReadOnlyList<IPAddress> ipv4Addresses,
        IReadOnlyList<IPv6Interface> ipv6Interfaces
    )
    {
        if (family == AddressFamily.InterNetwork)
        {
            var joinedAny = joinedIPv4Interfaces.Count > 0;
            foreach (var address in ipv4Addresses)
            {
                if (joinedIPv4Interfaces.Contains(address))
                {
                    joinedAny = true;
                    continue;
                }

                try
                {
                    socket.JoinMulticastGroup(IPv4MulticastAddress, address);
                    joinedIPv4Interfaces.Add(address);
                    joinedAny = true;
                }
                catch (Exception ex) when (IsTransientNetworkException(ex))
                {
                    Console.Error.WriteLine(
                        $"mDNS IPv4 multicast join failed on {address}: {ex.Message}"
                    );
                }
            }

            if (!joinedAny && !defaultIPv4MulticastMembership)
            {
                try
                {
                    socket.JoinMulticastGroup(IPv4MulticastAddress);
                    defaultIPv4MulticastMembership = true;
                }
                catch (Exception ex) when (IsTransientNetworkException(ex))
                {
                    Console.Error.WriteLine(
                        $"mDNS IPv4 multicast join failed: {ex.Message}"
                    );
                }
            }
            return;
        }

        var joinedIPv6 = joinedIPv6Interfaces.Count > 0;
        foreach (var networkInterface in ipv6Interfaces)
        {
            if (joinedIPv6Interfaces.Contains(networkInterface.Index))
            {
                joinedIPv6 = true;
                continue;
            }

            try
            {
                socket.JoinMulticastGroup(
                    networkInterface.Index,
                    IPv6MulticastAddress
                );
                joinedIPv6Interfaces.Add(networkInterface.Index);
                joinedIPv6 = true;
            }
            catch (Exception ex) when (IsTransientNetworkException(ex))
            {
                Console.Error.WriteLine(
                    $"mDNS IPv6 multicast join failed on interface "
                        + $"{networkInterface.Index}: {ex.Message}"
                );
            }
        }

        if (!joinedIPv6 && !defaultIPv6MulticastMembership)
        {
            try
            {
                socket.JoinMulticastGroup(IPv6MulticastAddress);
                defaultIPv6MulticastMembership = true;
            }
            catch (Exception ex) when (IsTransientNetworkException(ex))
            {
                Console.Error.WriteLine(
                    $"mDNS IPv6 multicast join failed: {ex.Message}"
                );
            }
        }
    }

    private static UdpClient? TryCreateClient(AddressFamily family)
    {
        try
        {
            var socket = new UdpClient(family);
            socket.Client.ExclusiveAddressUse = false;
            socket.Client.SetSocketOption(
                SocketOptionLevel.Socket,
                SocketOptionName.ReuseAddress,
                true
            );
            if (family == AddressFamily.InterNetwork)
            {
                // mDNS responders use a link-local TTL so receivers can
                // reject announcements that crossed a router.
                socket.Client.SetSocketOption(
                    SocketOptionLevel.IP,
                    SocketOptionName.IpTimeToLive,
                    255
                );
                socket.Client.SetSocketOption(
                    SocketOptionLevel.IP,
                    SocketOptionName.MulticastTimeToLive,
                    255
                );
                socket.Client.Bind(new IPEndPoint(IPAddress.Any, MulticastPort));
            }
            else
            {
                socket.Client.DualMode = false;
                socket.Client.SetSocketOption(
                    SocketOptionLevel.IPv6,
                    SocketOptionName.HopLimit,
                    255
                );
                socket.Client.Bind(
                    new IPEndPoint(IPAddress.IPv6Any, MulticastPort)
                );
            }

            return socket;
        }
        catch (Exception ex) when (IsTransientNetworkException(ex)
            || ex is NotSupportedException)
        {
            Console.Error.WriteLine(
                $"mDNS {family} socket unavailable: {ex.Message}"
            );
            return null;
        }
    }

    private static void DropMulticastMembership(
        UdpClient? socket,
        IPAddress multicastAddress
    )
    {
        if (socket is null)
        {
            return;
        }

        try
        {
            socket.DropMulticastGroup(multicastAddress);
        }
        catch (Exception ex) when (ex is SocketException
            or ObjectDisposedException
            or InvalidOperationException)
        {
            // The membership may already have disappeared with its adapter.
        }
    }

    private static IPAddress WithScope(IPAddress address, int interfaceIndex)
        => new(address.GetAddressBytes(), interfaceIndex);

    private static bool IsMulticast(IPAddress address) =>
        address.AddressFamily == AddressFamily.InterNetwork
            ? address.Equals(IPv4MulticastAddress)
            : address.IsIPv6Multicast;

    private async Task DelayAfterNetworkErrorAsync(string loop, Exception exception)
    {
        Console.Error.WriteLine($"mDNS {loop} network error; retrying: {exception.Message}");
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(5), cancellation.Token);
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
    }

    private static bool IsTransientNetworkException(Exception exception) =>
        exception is SocketException
            or NetworkInformationException
            or IOException
            or InvalidOperationException;

    private static bool ContainsPairingQuery(byte[] buffer)
    {
        // A response contains the same service text as a query. Reply only to
        // a DNS question (QR=0) so two receivers cannot answer one another's
        // announcements forever on a multicast loopback.
        if (buffer.Length < 12
            || (BinaryPrimitives.ReadUInt16BigEndian(buffer.AsSpan(2, 2)) & 0x8000) != 0)
        {
            return false;
        }

        var questionCount = BinaryPrimitives.ReadUInt16BigEndian(buffer.AsSpan(4, 2));
        if (questionCount == 0 || questionCount > 64)
        {
            return false;
        }

        var offset = 12;
        for (var index = 0; index < questionCount; index++)
        {
            if (!TryReadDnsName(buffer, ref offset, out var name)
                || offset + 4 > buffer.Length)
            {
                return false;
            }

            // QTYPE and QCLASS are intentionally accepted broadly: Bonjour
            // browsers use PTR, SRV, TXT, and ANY at different stages.
            offset += 4;
            if (name.Contains("_mackvm", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static bool TryReadDnsName(
        byte[] buffer,
        ref int offset,
        out string name
    )
    {
        var labels = new List<string>();
        var cursor = offset;
        var nextOffset = offset;
        var jumped = false;
        for (var steps = 0; steps < buffer.Length; steps++)
        {
            if (cursor >= buffer.Length)
            {
                name = string.Empty;
                return false;
            }

            var length = buffer[cursor++];
            if (length == 0)
            {
                if (!jumped)
                {
                    nextOffset = cursor;
                }

                offset = nextOffset;
                name = string.Join('.', labels);
                return true;
            }

            if ((length & 0xC0) == 0xC0)
            {
                if (cursor >= buffer.Length)
                {
                    name = string.Empty;
                    return false;
                }

                var pointer = ((length & 0x3F) << 8) | buffer[cursor++];
                if (pointer >= buffer.Length)
                {
                    name = string.Empty;
                    return false;
                }

                if (!jumped)
                {
                    nextOffset = cursor;
                    jumped = true;
                }

                cursor = pointer;
                continue;
            }

            if (length > 63 || cursor + length > buffer.Length)
            {
                name = string.Empty;
                return false;
            }

            labels.Add(Encoding.ASCII.GetString(buffer, cursor, length));
            cursor += length;
            if (!jumped)
            {
                nextOffset = cursor;
            }
        }

        name = string.Empty;
        return false;
    }

    private static IReadOnlyList<IPAddress> GetIPv4Addresses()
    {
        var values = new List<IPAddress>();
        foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (network.OperationalStatus != OperationalStatus.Up
                || network.NetworkInterfaceType == NetworkInterfaceType.Loopback)
            {
                continue;
            }

            foreach (var address in network.GetIPProperties().UnicastAddresses
                         .Select(entry => entry.Address)
                         .Where(address => address.AddressFamily == AddressFamily.InterNetwork
                             && !IPAddress.IsLoopback(address)))
            {
                if (!values.Contains(address))
                {
                    values.Add(address);
                }
            }
        }

        return values;
    }

    private static IReadOnlyList<IPAddress> GetIPv4AddressesSafely()
    {
        try
        {
            return GetIPv4Addresses();
        }
        catch (Exception ex) when (ex is NetworkInformationException or SocketException)
        {
            Console.Error.WriteLine($"mDNS address enumeration failed: {ex.Message}");
            return [];
        }
    }

    private static IReadOnlyList<IPv6Interface> GetIPv6InterfacesSafely()
    {
        try
        {
            var values = new List<IPv6Interface>();
            foreach (var network in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (network.OperationalStatus != OperationalStatus.Up
                    || network.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                {
                    continue;
                }

                var properties = network.GetIPProperties().GetIPv6Properties();
                if (properties is null)
                {
                    continue;
                }

                foreach (var address in network.GetIPProperties().UnicastAddresses
                             .Select(entry => entry.Address)
                             .Where(address => address.AddressFamily == AddressFamily.InterNetworkV6
                                 && !IPAddress.IsLoopback(address)
                                 && !address.IsIPv6Multicast))
                {
                    var value = new IPv6Interface(address, properties.Index);
                    if (!values.Contains(value))
                    {
                        values.Add(value);
                    }
                }
            }

            return values;
        }
        catch (Exception ex) when (ex is NetworkInformationException or SocketException)
        {
            Console.Error.WriteLine($"mDNS IPv6 address enumeration failed: {ex.Message}");
            return [];
        }
    }
}

internal static class MdnsPacket
{
    public static byte[] Build(
        string serviceType,
        string serviceName,
        string hostName,
        PeerIdentity identity,
        string model,
        int port,
        IReadOnlyList<IPAddress> addresses,
        uint recordTtl = 120
    )
    {
        using var stream = new MemoryStream();
        Span<byte> header = stackalloc byte[12];
        BinaryPrimitives.WriteUInt16BigEndian(header[0..2], 0);
        BinaryPrimitives.WriteUInt16BigEndian(header[2..4], 0x8400); // response + authoritative
        BinaryPrimitives.WriteUInt16BigEndian(header[4..6], 0);
        var answerCount = 3 + addresses.Count;
        BinaryPrimitives.WriteUInt16BigEndian(header[6..8], checked((ushort)answerCount));
        BinaryPrimitives.WriteUInt16BigEndian(header[8..10], 0);
        BinaryPrimitives.WriteUInt16BigEndian(header[10..12], 0);
        stream.Write(header);

        // PTR is shared; SRV/TXT/A are unique records and must carry the
        // DNS-SD cache-flush bit so a restarted receiver replaces stale
        // endpoint data immediately.
        WriteRecord(stream, serviceType, 12, 1, recordTtl, writer => WriteName(writer, serviceName));
        WriteRecord(stream, serviceName, 33, 0x8001, recordTtl, writer =>
        {
            Span<byte> srv = stackalloc byte[6];
            BinaryPrimitives.WriteUInt16BigEndian(srv[0..2], 0);
            BinaryPrimitives.WriteUInt16BigEndian(srv[2..4], 0);
            BinaryPrimitives.WriteUInt16BigEndian(srv[4..6], checked((ushort)port));
            writer.Write(srv);
            WriteName(writer, hostName);
        });
        var txtValues = new[]
        {
            $"id={identity.Id:D}",
            $"name={identity.Name}",
            $"model={model}",
            $"key={Convert.ToBase64String(identity.SigningPublicKey)}"
        };
        WriteRecord(stream, serviceName, 16, 0x8001, recordTtl, writer =>
        {
            foreach (var value in txtValues)
            {
                var bytes = Encoding.UTF8.GetBytes(value);
                if (bytes.Length > 255)
                {
                    throw new InvalidOperationException("mDNS TXT value is too large.");
                }

                writer.WriteByte((byte)bytes.Length);
                writer.Write(bytes);
            }
        });
        foreach (var address in addresses)
        {
            var bytes = address.GetAddressBytes();
            var recordType = address.AddressFamily switch
            {
                AddressFamily.InterNetwork => (ushort)1, // A
                AddressFamily.InterNetworkV6 => (ushort)28, // AAAA
                _ => throw new InvalidOperationException("Unsupported mDNS address family.")
            };
            var expectedLength = recordType == 1 ? 4 : 16;
            if (bytes.Length != expectedLength)
            {
                throw new InvalidOperationException("Invalid mDNS address length.");
            }
            WriteRecord(
                stream,
                hostName,
                recordType,
                0x8001,
                recordTtl,
                writer => writer.Write(bytes)
            );
        }

        return stream.ToArray();
    }

    private static void WriteRecord(
        Stream stream,
        string name,
        ushort type,
        ushort recordClass,
        uint ttl,
        Action<MemoryStream> writeData
    )
    {
        using var data = new MemoryStream();
        writeData(data);
        WriteName(stream, name);
        Span<byte> header = stackalloc byte[10];
        BinaryPrimitives.WriteUInt16BigEndian(header[0..2], type);
        BinaryPrimitives.WriteUInt16BigEndian(header[2..4], recordClass);
        BinaryPrimitives.WriteUInt32BigEndian(header[4..8], ttl);
        BinaryPrimitives.WriteUInt16BigEndian(header[8..10], checked((ushort)data.Length));
        stream.Write(header);
        data.Position = 0;
        data.CopyTo(stream);
    }

    private static void WriteName(Stream stream, string name)
    {
        foreach (var label in name.TrimEnd('.').Split('.'))
        {
            var bytes = Encoding.UTF8.GetBytes(label);
            if (bytes.Length is 0 or > 63)
            {
                throw new InvalidOperationException("mDNS label is invalid.");
            }

            stream.WriteByte((byte)bytes.Length);
            stream.Write(bytes);
        }

        stream.WriteByte(0);
    }
}
