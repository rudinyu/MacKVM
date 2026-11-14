import Foundation
import MacKVMCore
import XCTest

final class InputTargetSelectionPolicyTests: XCTestCase {
    func testSeededOrderDoesNotDependOnSetIterationOrder() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let third = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        XCTAssertEqual(
            InputTargetSelectionPolicy.seededOrder(
                peerIDs: Set([first, second, third])
            ),
            [second, third, first]
        )
    }

    func testOrderUpdatePreservesSlotsAndAppendsNewPeersStably() {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let third = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let fourth = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

        XCTAssertEqual(
            InputTargetSelectionPolicy.updatingOrder(
                [third, first, third],
                pairedPeerIDs: Set([first, second, third, fourth])
            ),
            [third, first, second, fourth]
        )
        XCTAssertEqual(
            InputTargetSelectionPolicy.updatingOrder(
                [third, first, second],
                pairedPeerIDs: Set([first, second])
            ),
            [first, second]
        )
    }

    func testMakingPrimaryMovesOnlyTheSelectedPeer() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let order = [first, second, third]

        XCTAssertEqual(
            InputTargetSelectionPolicy.makingPrimary(second, in: order),
            [second, first, third]
        )
        XCTAssertEqual(
            InputTargetSelectionPolicy.makingPrimary(UUID(), in: order),
            order
        )
    }

    func testNextTargetCyclesAndSkipsOfflineClients() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let order = [first, second, third]
        let allOnline = Set(order)

        XCTAssertEqual(
            InputTargetSelectionPolicy.nextTarget(
                orderedPeerIDs: order,
                currentPeerID: first,
                availablePeerIDs: allOnline
            ),
            second
        )
        XCTAssertEqual(
            InputTargetSelectionPolicy.nextTarget(
                orderedPeerIDs: order,
                currentPeerID: third,
                availablePeerIDs: allOnline
            ),
            first
        )
        XCTAssertEqual(
            InputTargetSelectionPolicy.nextTarget(
                orderedPeerIDs: order,
                currentPeerID: first,
                availablePeerIDs: Set([first, third])
            ),
            third
        )
        XCTAssertEqual(
            InputTargetSelectionPolicy.nextTarget(
                orderedPeerIDs: order,
                currentPeerID: second,
                availablePeerIDs: Set([second])
            ),
            second
        )
        XCTAssertNil(
            InputTargetSelectionPolicy.nextTarget(
                orderedPeerIDs: order,
                currentPeerID: first,
                availablePeerIDs: []
            )
        )
    }

    func testDirectSelectionRejectsOfflineAndInvalidSlots() {
        let first = UUID()
        let second = UUID()

        XCTAssertEqual(
            InputTargetSelectionPolicy.target(
                atOneBasedSlot: 1,
                orderedPeerIDs: [first, second],
                availablePeerIDs: Set([first])
            ),
            first
        )
        XCTAssertNil(
            InputTargetSelectionPolicy.target(
                atOneBasedSlot: 2,
                orderedPeerIDs: [first, second],
                availablePeerIDs: Set([first])
            )
        )
        XCTAssertNil(
            InputTargetSelectionPolicy.target(
                atOneBasedSlot: 0,
                orderedPeerIDs: [first, second],
                availablePeerIDs: Set([first, second])
            )
        )
    }
}
