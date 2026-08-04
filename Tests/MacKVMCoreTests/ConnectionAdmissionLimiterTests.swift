import XCTest
@testable import MacKVMCore

final class ConnectionAdmissionLimiterTests: XCTestCase {
    func testLimitsEventsWithinTheSlidingWindow() {
        var limiter = ConnectionAdmissionLimiter(
            maximumEvents: 2,
            window: 10
        )

        XCTAssertTrue(limiter.allows(eventAt: 100))
        XCTAssertTrue(limiter.allows(eventAt: 101))
        XCTAssertFalse(limiter.allows(eventAt: 102))
        XCTAssertTrue(limiter.allows(eventAt: 10_000_000_101))
    }

    func testResetClearsAdmissionHistory() {
        var limiter = ConnectionAdmissionLimiter(maximumEvents: 1, window: 1)
        XCTAssertTrue(limiter.allows(eventAt: 1))
        limiter.reset()
        XCTAssertTrue(limiter.allows(eventAt: 2))
    }
}
