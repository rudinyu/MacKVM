import XCTest
@testable import MacKVM

final class PeerDiscoveryServiceTests: XCTestCase {
    func testPairingActivityExposesActivePeerForRetry() {
        let peerID = UUID()

        let connecting = PairingActivity.connecting(
            peerID: peerID,
            peerName: "Intel Mac"
        )
        XCTAssertTrue(connecting.isActive)
        XCTAssertTrue(connecting.canCancel)
        XCTAssertEqual(connecting.peerID, peerID)
        XCTAssertEqual(connecting.peerName, "Intel Mac")

        let awaitingConfirmation = PairingActivity.awaitingConfirmation(
            peerID: peerID,
            peerName: "Intel Mac"
        )
        XCTAssertTrue(awaitingConfirmation.isActive)
        XCTAssertTrue(awaitingConfirmation.canCancel)
        XCTAssertEqual(awaitingConfirmation.peerID, peerID)
        XCTAssertEqual(awaitingConfirmation.peerName, "Intel Mac")

        let retryAvailable = PairingActivity.retryAvailable(
            peerID: peerID,
            peerName: "Intel Mac"
        )
        XCTAssertTrue(retryAvailable.isActive)
        XCTAssertFalse(retryAvailable.canCancel)
        XCTAssertEqual(retryAvailable.peerID, peerID)
        XCTAssertEqual(retryAvailable.peerName, "Intel Mac")
    }

    func testIdlePairingActivityHasNoRetryTarget() {
        XCTAssertFalse(PairingActivity.idle.isActive)
        XCTAssertFalse(PairingActivity.idle.canCancel)
        XCTAssertNil(PairingActivity.idle.peerID)
        XCTAssertNil(PairingActivity.idle.peerName)
    }

    func testNetworkRecoveryRequiresBothServicesToBeReady() {
        XCTAssertFalse(
            PeerDiscoveryService.areNetworkServicesReady(
                listenerPresent: true,
                browserPresent: true,
                listenerReady: true,
                browserReady: false
            )
        )
        XCTAssertTrue(
            PeerDiscoveryService.areNetworkServicesReady(
                listenerPresent: true,
                browserPresent: true,
                listenerReady: true,
                browserReady: true
            )
        )
        XCTAssertFalse(
            PeerDiscoveryService.areNetworkServicesReady(
                listenerPresent: false,
                browserPresent: true,
                listenerReady: true,
                browserReady: true
            )
        )
    }

    func testEOFWithoutAnActivePairingCancelsImmediately() {
        XCTAssertTrue(
            PairingConnectionEOFPolicy.shouldCancelAfterEOF(
                activePairingCount: 0
            )
        )
    }

    func testEOFWithAnActivePairingRemainsAvailableForCompletion() {
        XCTAssertFalse(
            PairingConnectionEOFPolicy.shouldCancelAfterEOF(
                activePairingCount: 1
            )
        )
    }

    func testPairingCompletionRequiresSignedTransportAcknowledgement() {
        XCTAssertTrue(
            PairingCompletionPolicy.allowsPersistence(
                localAccepted: true,
                remoteAccepted: true,
                localCompletionSent: true,
                remoteCompletionReceived: true,
                acknowledgementReceived: true,
                acknowledgementDelivered: true,
                closeBarrierConfirmedByPeer: true
            )
        )
        XCTAssertFalse(
            PairingCompletionPolicy.allowsPersistence(
                localAccepted: true,
                remoteAccepted: true,
                localCompletionSent: true,
                remoteCompletionReceived: true,
                acknowledgementReceived: false,
                acknowledgementDelivered: true,
                closeBarrierConfirmedByPeer: true
            )
        )
        XCTAssertFalse(
            PairingCompletionPolicy.allowsPersistence(
                localAccepted: true,
                remoteAccepted: true,
                localCompletionSent: true,
                remoteCompletionReceived: true,
                acknowledgementReceived: true,
                acknowledgementDelivered: false,
                closeBarrierConfirmedByPeer: true
            )
        )
        XCTAssertFalse(
            PairingCompletionPolicy.allowsPersistence(
                localAccepted: true,
                remoteAccepted: true,
                localCompletionSent: true,
                remoteCompletionReceived: true,
                acknowledgementReceived: true,
                acknowledgementDelivered: true,
                closeBarrierConfirmedByPeer: false
            )
        )
    }
}
