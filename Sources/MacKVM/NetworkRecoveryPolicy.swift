import Foundation

/// Shared policy for recovering Bonjour services after a transient network
/// failure. A recovery cycle may schedule at most five attempts; a later
/// `.ready` callback resets the counter so a subsequent outage starts again at
/// the shortest delay.
enum NetworkRecoveryPolicy {
    static let maximumAttempts = 5

    static func shouldSchedule(
        attempt: Int,
        hasPendingWork: Bool
    ) -> Bool {
        !hasPendingWork && attempt < maximumAttempts
    }

    static func delay(forAttempt attempt: Int) -> TimeInterval {
        let normalizedAttempt = max(0, attempt)
        return min(pow(2.0, Double(normalizedAttempt)), 30.0)
    }
}
