import Foundation
import XCTest
@testable import MacKVM

@MainActor
final class InputTargetRouterTests: XCTestCase {
    func testCycleSkipsOfflineTargetsAndConnectsSelectedPeer() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fixture = makeFixture(
            orderedPeerIDs: [first, second, third],
            availablePeerIDs: Set([first, third]),
            connectedPeerID: first
        )

        fixture.router.cycleToNextOnlineTarget()

        XCTAssertEqual(fixture.router.selectedPeerID, third)
        XCTAssertEqual(fixture.actions.disconnectedCount, 1)
        XCTAssertEqual(fixture.actions.connectedTargets, [third])
        XCTAssertEqual(
            fixture.actions.targetSwitchStopReasons,
            ["Switching input to the selected client"]
        )
        XCTAssertTrue(fixture.actions.localStopReasons.isEmpty)
        XCTAssertEqual(fixture.actions.requestControlCount, 0)

        fixture.actions.currentConnectedPeerID = third
        fixture.router.connectionChanged(to: third)

        XCTAssertEqual(fixture.actions.requestControlCount, 1)
    }

    func testDirectSelectionOfOfflineTargetDoesNotChangeDestination() {
        let first = UUID()
        let second = UUID()
        let fixture = makeFixture(
            orderedPeerIDs: [first, second],
            availablePeerIDs: Set([first]),
            connectedPeerID: first
        )

        fixture.router.selectTarget(atOneBasedSlot: 2)

        XCTAssertEqual(fixture.router.selectedPeerID, first)
        XCTAssertTrue(fixture.actions.connectedTargets.isEmpty)
        XCTAssertEqual(fixture.actions.disconnectedCount, 0)
        XCTAssertTrue(fixture.actions.targetSwitchStopReasons.isEmpty)
        XCTAssertTrue(fixture.actions.localStopReasons.isEmpty)
    }

    func testLateConnectionForPreviousTargetCannotActivateControl() {
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let fixture = makeFixture(
            orderedPeerIDs: [first, second, third],
            availablePeerIDs: Set([first, second, third]),
            connectedPeerID: first
        )

        fixture.router.selectTarget(atOneBasedSlot: 2)
        fixture.router.selectTarget(atOneBasedSlot: 3)
        fixture.actions.currentConnectedPeerID = second
        fixture.router.connectionChanged(to: second)

        XCTAssertEqual(fixture.router.selectedPeerID, third)
        XCTAssertEqual(fixture.actions.requestControlCount, 0)

        fixture.actions.currentConnectedPeerID = third
        fixture.router.connectionChanged(to: third)

        XCTAssertEqual(fixture.actions.requestControlCount, 1)
    }

    func testReturnLocallyFencesPendingConnectionCallback() {
        let first = UUID()
        let second = UUID()
        let fixture = makeFixture(
            orderedPeerIDs: [first, second],
            availablePeerIDs: Set([first, second]),
            connectedPeerID: first
        )

        fixture.router.selectTarget(atOneBasedSlot: 2)
        fixture.router.returnInputLocally()
        fixture.actions.currentConnectedPeerID = second
        fixture.router.connectionChanged(to: second)

        XCTAssertEqual(fixture.actions.requestControlCount, 0)
        XCTAssertEqual(
            fixture.actions.localStopReasons.last,
            "Input returned to this Mac"
        )
    }

    func testTargetHandoffAndLocalReturnUseDifferentStopActions() {
        let first = UUID()
        let second = UUID()
        let fixture = makeFixture(
            orderedPeerIDs: [first, second],
            availablePeerIDs: Set([first, second]),
            connectedPeerID: first
        )

        fixture.router.selectTarget(atOneBasedSlot: 2)

        XCTAssertEqual(
            fixture.actions.targetSwitchStopReasons,
            ["Switching input to the selected client"]
        )
        XCTAssertTrue(fixture.actions.localStopReasons.isEmpty)

        fixture.router.returnInputLocally()

        XCTAssertEqual(
            fixture.actions.localStopReasons,
            ["Input returned to this Mac"]
        )
        XCTAssertEqual(fixture.actions.targetSwitchStopReasons.count, 1)
    }

    func testSelectingConnectedTargetRequestsControlWithoutReconnect() {
        let first = UUID()
        let second = UUID()
        let fixture = makeFixture(
            orderedPeerIDs: [first, second],
            availablePeerIDs: Set([first, second]),
            connectedPeerID: first
        )
        fixture.actions.controlIsActive = false

        fixture.router.selectTarget(atOneBasedSlot: 1)

        XCTAssertEqual(fixture.actions.requestControlCount, 1)
        XCTAssertEqual(fixture.actions.disconnectedCount, 0)
        XCTAssertTrue(fixture.actions.connectedTargets.isEmpty)
    }

    private func makeFixture(
        orderedPeerIDs: [UUID],
        availablePeerIDs: Set<UUID>,
        connectedPeerID: UUID?
    ) -> Fixture {
        let actions = FakeTargetActions(connectedPeerID: connectedPeerID)
        let router = InputTargetRouter(
            actions: .init(
                connectedPeerID: { [weak actions] in
                    actions?.currentConnectedPeerID
                },
                connectingPeerID: { [weak actions] in
                    actions?.currentConnectingPeerID
                },
                disconnect: { [weak actions] in
                    actions?.disconnectedCount += 1
                    actions?.currentConnectedPeerID = nil
                },
                connect: { [weak actions] peerID in
                    actions?.connectedTargets.append(peerID)
                },
                stopControl: { [weak actions] reason in
                    actions?.localStopReasons.append(reason)
                    actions?.controlIsActive = false
                },
                stopControlForTargetSwitch: { [weak actions] reason in
                    actions?.targetSwitchStopReasons.append(reason)
                    actions?.controlIsActive = false
                },
                isControlActive: { [weak actions] in
                    actions?.controlIsActive ?? false
                },
                requestControl: { [weak actions] in
                    actions?.requestControlCount += 1
                    actions?.controlIsActive = true
                    return true
                }
            )
        )
        router.updateTargets(
            orderedPeerIDs: orderedPeerIDs,
            availablePeerIDs: availablePeerIDs
        )
        return Fixture(router: router, actions: actions)
    }
}

@MainActor
private final class FakeTargetActions {
    var currentConnectedPeerID: UUID?
    var currentConnectingPeerID: UUID?
    var connectedTargets: [UUID] = []
    var disconnectedCount = 0
    var localStopReasons: [String] = []
    var targetSwitchStopReasons: [String] = []
    var requestControlCount = 0
    var controlIsActive = true

    init(connectedPeerID: UUID?) {
        currentConnectedPeerID = connectedPeerID
    }
}

@MainActor
private struct Fixture {
    let router: InputTargetRouter
    let actions: FakeTargetActions
}
