import XCTest
@testable import MacKVM

final class PeerDiscoveryServiceTests: XCTestCase {
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
