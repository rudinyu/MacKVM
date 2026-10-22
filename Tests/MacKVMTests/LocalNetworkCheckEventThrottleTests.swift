import Foundation
import XCTest
@testable import MacKVM

final class LocalNetworkCheckEventThrottleTests: XCTestCase {
    func testEventDrivenCheckIsBlockedBeforeOneAndAHalfSeconds() {
        let startedAt = Date(timeIntervalSince1970: 10_000)

        XCTAssertFalse(shouldStartEventDrivenCheck(
            lastStartedAt: startedAt,
            elapsed: 1.0
        ))
    }

    func testEventDrivenCheckIsAllowedAtOneAndAHalfSeconds() {
        let startedAt = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(shouldStartEventDrivenCheck(
            lastStartedAt: startedAt,
            elapsed: 1.5
        ))
    }

    func testTimerChecksKeepFiveSecondMinimumInterval() {
        let startedAt = Date(timeIntervalSince1970: 10_000)

        XCTAssertFalse(
            LocalNetworkCheckLifecyclePolicy.shouldStartAutomaticCheck(
                isPolling: true,
                networkServicesStarted: true,
                checkInProgress: false,
                lastStartedAt: startedAt,
                now: startedAt.addingTimeInterval(1.5)
            )
        )
        XCTAssertTrue(
            LocalNetworkCheckLifecyclePolicy.shouldStartAutomaticCheck(
                isPolling: true,
                networkServicesStarted: true,
                checkInProgress: false,
                lastStartedAt: startedAt,
                now: startedAt.addingTimeInterval(5)
            )
        )
    }

    private func shouldStartEventDrivenCheck(
        lastStartedAt: Date,
        elapsed: TimeInterval
    ) -> Bool {
        LocalNetworkCheckLifecyclePolicy.shouldStartAutomaticCheck(
            isPolling: true,
            networkServicesStarted: true,
            checkInProgress: false,
            lastStartedAt: lastStartedAt,
            now: lastStartedAt.addingTimeInterval(elapsed),
            eventDriven: true
        )
    }
}
