import XCTest
@testable import MacKVMCore

private final class AdmissionToken {}

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

    func testPerSourceLimitsConcurrentConnectionsAndReleasesSlots() {
        var limiter = PerSourceConnectionAdmissionLimiter()
        let tokens = (0..<3).map { _ in AdmissionToken() }
        let first = ObjectIdentifier(tokens[0])
        let second = ObjectIdentifier(tokens[1])
        let third = ObjectIdentifier(tokens[2])

        XCTAssertTrue(limiter.allows(
            connectionID: first,
            sourceKey: "192.0.2.10",
            eventAt: 1
        ))
        XCTAssertTrue(limiter.allows(
            connectionID: second,
            sourceKey: "192.0.2.10",
            eventAt: 2
        ))
        XCTAssertFalse(limiter.allows(
            connectionID: third,
            sourceKey: "192.0.2.10",
            eventAt: 3
        ))

        limiter.remove(connectionID: first)
        XCTAssertTrue(limiter.allows(
            connectionID: third,
            sourceKey: "192.0.2.10",
            eventAt: 4
        ))
    }

    func testPerSourceAcceptWindowIsIndependentAndExpires() {
        var limiter = PerSourceConnectionAdmissionLimiter()
        let sourceTokens = (0..<5).map { _ in AdmissionToken() }
        let sourceIDs = sourceTokens.map { ObjectIdentifier($0) }
        for index in 0..<4 {
            XCTAssertTrue(limiter.allows(
                connectionID: sourceIDs[index],
                sourceKey: "192.0.2.10",
                eventAt: UInt64(index + 1)
            ))
            limiter.remove(connectionID: sourceIDs[index])
        }
        XCTAssertFalse(limiter.allows(
            connectionID: sourceIDs[4],
            sourceKey: "192.0.2.10",
            eventAt: 5
        ))

        let otherSourceToken = AdmissionToken()
        let otherSourceID = ObjectIdentifier(otherSourceToken)
        XCTAssertTrue(limiter.allows(
            connectionID: otherSourceID,
            sourceKey: "192.0.2.11",
            eventAt: 5
        ))

        let afterWindowToken = AdmissionToken()
        let afterWindowID = ObjectIdentifier(afterWindowToken)
        XCTAssertTrue(limiter.allows(
            connectionID: afterWindowID,
            sourceKey: "192.0.2.10",
            eventAt: 10_000_000_001
        ))
    }

    func testPerSourceResetClearsConnectionsAndWindowHistory() {
        var limiter = PerSourceConnectionAdmissionLimiter(
            maximumConcurrentConnections: 1,
            maximumAccepts: 1,
            window: 10
        )
        let tokens = (0..<2).map { _ in AdmissionToken() }
        let first = ObjectIdentifier(tokens[0])
        let second = ObjectIdentifier(tokens[1])
        XCTAssertTrue(limiter.allows(
            connectionID: first,
            sourceKey: "192.0.2.10",
            eventAt: 1
        ))

        limiter.reset()

        XCTAssertTrue(limiter.allows(
            connectionID: second,
            sourceKey: "192.0.2.10",
            eventAt: 2
        ))
    }
}
