import XCTest
@testable import MacKVMCore

final class PartialFrameTimeoutPolicyTests: XCTestCase {
    func testPartialFrameExpiresAtItsDeadline() {
        let deadline = PartialFrameTimeoutPolicy.deadline(
            now: 100,
            timeoutNanoseconds: 50
        )

        XCTAssertFalse(
            PartialFrameTimeoutPolicy.shouldExpire(
                deadline: deadline,
                hasPartialFrame: true,
                now: 149
            )
        )
        XCTAssertTrue(
            PartialFrameTimeoutPolicy.shouldExpire(
                deadline: deadline,
                hasPartialFrame: true,
                now: 150
            )
        )
    }

    func testEmptyFrameNeverExpiresAndMissingDeadlineIsSafe() {
        XCTAssertFalse(
            PartialFrameTimeoutPolicy.shouldExpire(
                deadline: 10,
                hasPartialFrame: false,
                now: 100
            )
        )
        XCTAssertFalse(
            PartialFrameTimeoutPolicy.shouldExpire(
                deadline: nil,
                hasPartialFrame: true,
                now: 100
            )
        )
    }
}
