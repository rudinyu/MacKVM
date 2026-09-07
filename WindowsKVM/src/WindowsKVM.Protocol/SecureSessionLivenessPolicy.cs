using System.Buffers.Binary;

namespace WindowsKVM.Protocol;

/// <summary>
/// Cross-platform secure-session transport liveness policy. The values are
/// shared with the macOS Network.framework implementation so both receivers
/// detect a sleeping, force-quit, or unreachable peer on a bounded timeline.
/// </summary>
public static class SecureSessionLivenessPolicy
{
    public const int KeepAliveIdleSeconds = 5;
    public const int KeepAliveIntervalSeconds = 2;
    public const int KeepAliveProbeCount = 3;
    public const int TransportUnavailabilityGraceSeconds = 5;
    public const int SocketPollIntervalMilliseconds = 1_000;

    /// <summary>
    /// Encodes the Windows Winsock <c>SIO_KEEPALIVE_VALS</c> structure:
    /// enabled (DWORD), idle timeout in milliseconds (DWORD), and probe
    /// interval in milliseconds (DWORD). Newer Windows/.NET builds use the
    /// explicit TCP socket options; this payload is the compatibility fallback
    /// for Windows builds that do not expose those options.
    /// </summary>
    public static byte[] CreateWindowsKeepAliveValues()
    {
        var values = new byte[12];
        BinaryPrimitives.WriteUInt32LittleEndian(values.AsSpan(0, 4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(
            values.AsSpan(4, 4),
            checked((uint)(KeepAliveIdleSeconds * 1_000))
        );
        BinaryPrimitives.WriteUInt32LittleEndian(
            values.AsSpan(8, 4),
            checked((uint)(KeepAliveIntervalSeconds * 1_000))
        );
        return values;
    }
}
