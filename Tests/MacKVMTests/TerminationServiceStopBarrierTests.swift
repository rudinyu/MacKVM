import XCTest
@testable import MacKVM

final class TerminationServiceStopBarrierTests: XCTestCase {
    func testWaitsForEveryServiceCompletionBeforeContinuing() {
        var stopCompletions: [() -> Void] = []
        var timedOutResult: Bool?
        let finished = expectation(description: "All services stopped")

        let stops: [TerminationServiceStopBarrier.Stop] = [
            { stopCompletions.append($0) },
            { stopCompletions.append($0) }
        ]
        TerminationServiceStopBarrier.wait(for: stops, timeout: 1) {
            timedOutResult = $0
            finished.fulfill()
        }

        XCTAssertEqual(stopCompletions.count, 2)
        stopCompletions[0]()
        XCTAssertNil(timedOutResult)
        stopCompletions[1]()

        wait(for: [finished], timeout: 1)
        XCTAssertEqual(timedOutResult, false)
    }

    func testTimeoutContinuesOnceAndIgnoresLateStopCompletions() {
        var stopCompletions: [() -> Void] = []
        var continuationCount = 0
        var timedOutResult: Bool?
        let timedOut = expectation(description: "Stop timeout")
        let notificationDrained = expectation(
            description: "Late group notification drained"
        )

        let stops: [TerminationServiceStopBarrier.Stop] = [
            { stopCompletions.append($0) },
            { stopCompletions.append($0) }
        ]
        TerminationServiceStopBarrier.wait(for: stops, timeout: 0.01) {
            continuationCount += 1
            timedOutResult = $0
            timedOut.fulfill()
        }

        XCTAssertEqual(stopCompletions.count, 2)
        stopCompletions[0]()
        wait(for: [timedOut], timeout: 1)
        XCTAssertEqual(timedOutResult, true)
        stopCompletions[1]()
        stopCompletions[1]()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            notificationDrained.fulfill()
        }
        wait(for: [notificationDrained], timeout: 1)
        XCTAssertEqual(continuationCount, 1)
    }
}
