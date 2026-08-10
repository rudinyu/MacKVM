import XCTest
@testable import MacKVMCore

final class BufferedFrameDrainPolicyTests: XCTestCase {
    func testCompleteFramesMayRemainAboveByteBudgetForTheNextBatch() {
        XCTAssertTrue(
            BufferedFrameDrainPolicy.acceptsBufferedBytes(
                bufferCount: 128,
                maximumBufferLength: 64,
                hasCompleteFrame: true
            )
        )
        XCTAssertFalse(
            BufferedFrameDrainPolicy.acceptsBufferedBytes(
                bufferCount: 128,
                maximumBufferLength: 64,
                hasCompleteFrame: false
            )
        )
    }

    func testOnlyACompletedCappedBatchContinuesDecoding() {
        XCTAssertTrue(
            BufferedFrameDrainPolicy.shouldContinueDecoding(
                decodedFrameCount: 16,
                hasCompleteFrame: true
            )
        )
        XCTAssertFalse(
            BufferedFrameDrainPolicy.shouldContinueDecoding(
                decodedFrameCount: 0,
                hasCompleteFrame: true
            )
        )
        XCTAssertFalse(
            BufferedFrameDrainPolicy.shouldContinueDecoding(
                decodedFrameCount: 16,
                hasCompleteFrame: false
            )
        )
    }
}
