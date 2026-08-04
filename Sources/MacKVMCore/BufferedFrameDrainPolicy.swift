import Foundation

/// Shared decisions for capped length-prefixed frame drains.
///
/// Pairing and secure sessions keep their Network.framework lifecycle branches
/// local because their terminal and partial-frame semantics differ, while
/// these common budget decisions stay in one place.
public enum BufferedFrameDrainPolicy {
    public static func acceptsBufferedBytes(
        bufferCount: Int,
        maximumBufferLength: Int,
        hasCompleteFrame: Bool
    ) -> Bool {
        bufferCount <= maximumBufferLength || hasCompleteFrame
    }

    public static func shouldContinueDecoding(
        decodedFrameCount: Int,
        hasCompleteFrame: Bool
    ) -> Bool {
        decodedFrameCount > 0 && hasCompleteFrame
    }
}
