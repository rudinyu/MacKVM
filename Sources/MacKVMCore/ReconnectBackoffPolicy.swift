import Foundation

/// Deterministic exponential backoff used by the secure-session reconnect
/// loop. Keeping this calculation in the core target makes the retry policy
/// testable without opening real Network.framework connections.
public struct ReconnectBackoffPolicy: Equatable, Sendable {
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval

    public init(
        initialDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 30
    ) {
        self.initialDelay = max(0, initialDelay)
        self.maximumDelay = max(self.initialDelay, maximumDelay)
    }

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        let exponent = min(attempt - 1, 30)
        let multiplier = pow(2, Double(exponent))
        return min(maximumDelay, initialDelay * multiplier)
    }
}
