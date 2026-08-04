import Foundation

/// A deterministic per-second packet and byte budget for authenticated input.
/// It is intentionally independent of the network stack so boundary behavior
/// can be tested without opening a socket.
public struct InboundPayloadBudget: Equatable, Sendable {
    public let maximumPacketsPerSecond: Int
    public let maximumBytesPerSecond: Int

    private var windowStart: UInt64 = 0
    private var windowBytes = 0
    private var windowPackets = 0

    public init(
        maximumPacketsPerSecond: Int,
        maximumBytesPerSecond: Int
    ) {
        self.maximumPacketsPerSecond = maximumPacketsPerSecond
        self.maximumBytesPerSecond = maximumBytesPerSecond
    }

    public mutating func allows(bytes: Int, at now: UInt64) -> Bool {
        guard maximumPacketsPerSecond > 0,
              maximumBytesPerSecond > 0,
              bytes >= 0,
              bytes <= maximumBytesPerSecond else {
            return false
        }

        if windowStart == 0
            || now < windowStart
            || now - windowStart >= 1_000_000_000 {
            windowStart = now
            windowBytes = 0
            windowPackets = 0
        }

        guard windowPackets < maximumPacketsPerSecond,
              windowBytes <= maximumBytesPerSecond - bytes else {
            return false
        }
        windowPackets += 1
        windowBytes += bytes
        return true
    }

    public mutating func reset() {
        windowStart = 0
        windowBytes = 0
        windowPackets = 0
    }
}
