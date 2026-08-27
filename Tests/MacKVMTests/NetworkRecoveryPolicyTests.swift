import XCTest
@testable import MacKVM

final class NetworkRecoveryPolicyTests: XCTestCase {
    func testRecoveryStopsAfterTheFifthScheduledAttempt() {
        XCTAssertTrue(
            NetworkRecoveryPolicy.shouldSchedule(
                attempt: 0,
                hasPendingWork: false
            )
        )
        XCTAssertTrue(
            NetworkRecoveryPolicy.shouldSchedule(
                attempt: NetworkRecoveryPolicy.maximumAttempts - 1,
                hasPendingWork: false
            )
        )
        XCTAssertFalse(
            NetworkRecoveryPolicy.shouldSchedule(
                attempt: NetworkRecoveryPolicy.maximumAttempts,
                hasPendingWork: false
            )
        )
        XCTAssertFalse(
            NetworkRecoveryPolicy.shouldSchedule(
                attempt: NetworkRecoveryPolicy.maximumAttempts + 1,
                hasPendingWork: false
            )
        )
    }

    func testPendingRecoveryNeverSchedulesAnotherWorkItem() {
        XCTAssertFalse(
            NetworkRecoveryPolicy.shouldSchedule(
                attempt: 0,
                hasPendingWork: true
            )
        )
    }

    func testBackoffIsExponentialAndCappedAtThirtySeconds() {
        XCTAssertEqual(NetworkRecoveryPolicy.delay(forAttempt: 0), 1)
        XCTAssertEqual(NetworkRecoveryPolicy.delay(forAttempt: 1), 2)
        XCTAssertEqual(NetworkRecoveryPolicy.delay(forAttempt: 2), 4)
        XCTAssertEqual(NetworkRecoveryPolicy.delay(forAttempt: 4), 16)
        XCTAssertEqual(NetworkRecoveryPolicy.delay(forAttempt: 5), 30)
        XCTAssertEqual(NetworkRecoveryPolicy.delay(forAttempt: 12), 30)
    }
}
