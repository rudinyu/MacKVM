import XCTest
@testable import MacKVMCore

final class ReconnectBackoffPolicyTests: XCTestCase {
    func testBackoffStartsImmediatelyThenDoublesAndCaps() {
        let policy = ReconnectBackoffPolicy(
            initialDelay: 1,
            maximumDelay: 8
        )

        XCTAssertEqual(policy.delay(forAttempt: 0), 0)
        XCTAssertEqual(policy.delay(forAttempt: 1), 1)
        XCTAssertEqual(policy.delay(forAttempt: 2), 2)
        XCTAssertEqual(policy.delay(forAttempt: 3), 4)
        XCTAssertEqual(policy.delay(forAttempt: 4), 8)
        XCTAssertEqual(policy.delay(forAttempt: 8), 8)
    }

    func testNegativeAttemptIsImmediate() {
        XCTAssertEqual(
            ReconnectBackoffPolicy(initialDelay: 2).delay(forAttempt: -1),
            0
        )
    }
}
