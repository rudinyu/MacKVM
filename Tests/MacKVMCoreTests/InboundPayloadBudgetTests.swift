import XCTest
@testable import MacKVMCore

final class InboundPayloadBudgetTests: XCTestCase {
    func testEnforcesPacketAndByteBudgetsWithinOneSecond() {
        var budget = InboundPayloadBudget(
            maximumPacketsPerSecond: 2,
            maximumBytesPerSecond: 10
        )

        XCTAssertTrue(budget.allows(bytes: 4, at: 1_000))
        XCTAssertTrue(budget.allows(bytes: 6, at: 2_000))
        XCTAssertFalse(budget.allows(bytes: 1, at: 3_000))
    }

    func testStartsANewWindowAfterOneSecondAndRejectsOversizedPayload() {
        var budget = InboundPayloadBudget(
            maximumPacketsPerSecond: 1,
            maximumBytesPerSecond: 4
        )

        XCTAssertFalse(budget.allows(bytes: 5, at: 1_000))
        XCTAssertTrue(budget.allows(bytes: 4, at: 2_000))
        XCTAssertTrue(budget.allows(bytes: 4, at: 1_000_002_000))
    }
}
