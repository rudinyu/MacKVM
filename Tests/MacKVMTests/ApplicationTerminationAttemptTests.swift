import XCTest
@testable import MacKVM

final class ApplicationTerminationAttemptTests: XCTestCase {
    @MainActor
    func testCleanupCompletionRepliesOnceAndCancelsWatchdog() {
        var scheduledInterval: TimeInterval?
        var timeoutAction: (() -> Void)?
        var cancellationCount = 0
        var cleanupCompletion: (() -> Void)?
        var replies: [Bool] = []
        let attempt = ApplicationTerminationAttempt(
            scheduleTimeout: { interval, action in
                scheduledInterval = interval
                timeoutAction = action
                return { cancellationCount += 1 }
            },
            reply: { replies.append($0) }
        )

        attempt.start { cleanupCompletion = $0 }
        cleanupCompletion?()
        cleanupCompletion?()
        timeoutAction?()

        XCTAssertEqual(
            scheduledInterval,
            ApplicationTerminationAttempt.defaultTimeoutInterval
        )
        XCTAssertTrue(attempt.hasReplied)
        XCTAssertEqual(replies, [true])
        XCTAssertEqual(cancellationCount, 1)
    }

    @MainActor
    func testWatchdogRepliesOnceWhenCleanupDoesNotFinish() {
        var timeoutAction: (() -> Void)?
        var cleanupCompletion: (() -> Void)?
        var replies: [Bool] = []
        let attempt = ApplicationTerminationAttempt(
            scheduleTimeout: { _, action in
                timeoutAction = action
                return {}
            },
            reply: { replies.append($0) }
        )

        attempt.start { cleanupCompletion = $0 }
        timeoutAction?()
        cleanupCompletion?()
        timeoutAction?()

        XCTAssertTrue(attempt.hasReplied)
        XCTAssertEqual(replies, [true])
    }
}
