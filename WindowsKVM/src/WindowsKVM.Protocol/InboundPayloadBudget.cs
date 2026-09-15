namespace WindowsKVM.Protocol;

/// <summary>
/// Bounds authenticated input traffic per one-second window. The budget is
/// deliberately a rolling window rather than a lifetime packet count: a
/// normal mouse or trackpad stream must remain connected while an abusive
/// peer still cannot consume unbounded CPU or memory.
/// </summary>
public sealed class InboundPayloadBudget
{
    private long windowStartMilliseconds = -1;
    private int windowPackets;
    private long windowBytes;

    public InboundPayloadBudget(int maximumPacketsPerSecond, long maximumBytesPerSecond)
    {
        if (maximumPacketsPerSecond <= 0 || maximumBytesPerSecond <= 0)
        {
            throw new ArgumentOutOfRangeException();
        }

        MaximumPacketsPerSecond = maximumPacketsPerSecond;
        MaximumBytesPerSecond = maximumBytesPerSecond;
    }

    public int MaximumPacketsPerSecond { get; }

    public long MaximumBytesPerSecond { get; }

    public bool Allows(int bytes, long nowMilliseconds)
    {
        if (bytes < 0 || bytes > MaximumBytesPerSecond || nowMilliseconds < 0)
        {
            return false;
        }

        if (windowStartMilliseconds < 0
            || nowMilliseconds < windowStartMilliseconds
            || nowMilliseconds - windowStartMilliseconds >= 1_000)
        {
            windowStartMilliseconds = nowMilliseconds;
            windowPackets = 0;
            windowBytes = 0;
        }

        if (windowPackets >= MaximumPacketsPerSecond
            || windowBytes > MaximumBytesPerSecond - bytes)
        {
            return false;
        }

        windowPackets++;
        windowBytes += bytes;
        return true;
    }

    public void Reset()
    {
        windowStartMilliseconds = -1;
        windowPackets = 0;
        windowBytes = 0;
    }
}
