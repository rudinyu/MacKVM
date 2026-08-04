import Foundation

/// Pure timeout decisions used by the socket frame assembler.
public enum PartialFrameTimeoutPolicy {
    public static func deadline(
        now: UInt64,
        timeoutNanoseconds: UInt64
    ) -> UInt64 {
        now &+ timeoutNanoseconds
    }

    public static func shouldExpire(
        deadline: UInt64?,
        hasPartialFrame: Bool,
        now: UInt64
    ) -> Bool {
        guard hasPartialFrame, let deadline else { return false }
        return now >= deadline
    }
}
