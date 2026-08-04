import Foundation

/// Small, deterministic sliding-window limiter used before allocating work
/// for unauthenticated local-network connections. It is deliberately value
/// typed so callers can keep it on their serial network queue and tests can
/// exercise the policy without Network.framework.
public struct ConnectionAdmissionLimiter: Sendable {
    public let maximumEvents: Int
    public let windowNanoseconds: UInt64

    // eventAt is supplied by a monotonic clock (DispatchTime in production),
    // so expired entries can be retired from the front without scanning the
    // entire history on every connection attempt.
    private var eventTimes: [UInt64] = []
    private var firstLiveEventIndex = 0

    public init(maximumEvents: Int, window: TimeInterval) {
        self.maximumEvents = max(1, maximumEvents)
        self.windowNanoseconds = max(1, UInt64(max(0, window) * 1_000_000_000))
    }

    public static func unauthenticatedConnectionLimiter()
        -> ConnectionAdmissionLimiter {
        ConnectionAdmissionLimiter(
            maximumEvents:
                ConnectionAdmissionPolicy.maximumUnauthenticatedConnectionsPerWindow,
            window: ConnectionAdmissionPolicy.unauthenticatedConnectionWindow
        )
    }

    public mutating func allows(eventAt now: UInt64) -> Bool {
        let cutoff = now > windowNanoseconds
            ? now - windowNanoseconds
            : 0
        while firstLiveEventIndex < eventTimes.count,
              eventTimes[firstLiveEventIndex] <= cutoff {
            firstLiveEventIndex += 1
        }
        compactExpiredPrefixIfNeeded()
        guard eventTimes.count - firstLiveEventIndex < maximumEvents else {
            return false
        }
        eventTimes.append(now)
        return true
    }

    public mutating func reset() {
        eventTimes.removeAll(keepingCapacity: true)
        firstLiveEventIndex = 0
    }

    private mutating func compactExpiredPrefixIfNeeded() {
        guard firstLiveEventIndex > 0,
              firstLiveEventIndex >= 64
                || firstLiveEventIndex * 2 >= eventTimes.count else {
            return
        }
        eventTimes.removeFirst(firstLiveEventIndex)
        firstLiveEventIndex = 0
    }
}
