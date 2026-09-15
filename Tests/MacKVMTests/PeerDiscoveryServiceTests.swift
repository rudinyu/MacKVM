import Combine
import CryptoKit
import Foundation
import XCTest
@testable import MacKVM
@testable import MacKVMCore

final class PeerDiscoveryServiceTests: XCTestCase {
    func testForgetPublishesAStatusWithoutTheForgottenPeerName() throws {
        let privateKey = P256.Signing.PrivateKey()
        let credentials = DeviceCredentials(
            identity: PeerIdentity(
                name: "Local Mac",
                signingPublicKey: privateKey.publicKey.x963Representation
            ),
            privateKey: privateKey,
            wasLoadedFromStorage: false
        )
        let suiteName = "PeerDiscoveryServiceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = PairingRegistry(
            defaults: defaults,
            storageKey: "pairedPeers",
            persistenceApplicationID: suiteName
        )
        let service = PeerDiscoveryService(
            credentials: credentials,
            registry: registry
        )
        let statusPublished = expectation(description: "Forget status")
        let cancellable = service.$status.dropFirst().sink { status in
            if status == "Pairing forgotten" {
                statusPublished.fulfill()
            }
        }

        service.forget(UUID())

        wait(for: [statusPublished], timeout: 1)
        XCTAssertEqual(service.status, "Pairing forgotten")
        cancellable.cancel()
    }

    func testPairingCompletionStatusRequiresCurrentGenerationAndKey() {
        let key = Data([0x01, 0x02, 0x03])

        XCTAssertTrue(
            PairingStatusPublicationPolicy.allows(
                expectedGeneration: 4,
                currentGeneration: 4,
                expectedSigningPublicKey: key,
                currentSigningPublicKey: key
            )
        )
        XCTAssertFalse(
            PairingStatusPublicationPolicy.allows(
                expectedGeneration: 4,
                currentGeneration: 5,
                expectedSigningPublicKey: key,
                currentSigningPublicKey: key
            )
        )
        XCTAssertFalse(
            PairingStatusPublicationPolicy.allows(
                expectedGeneration: 4,
                currentGeneration: 4,
                expectedSigningPublicKey: key,
                currentSigningPublicKey: nil
            )
        )
        XCTAssertFalse(
            PairingStatusPublicationPolicy.allows(
                expectedGeneration: 4,
                currentGeneration: 4,
                expectedSigningPublicKey: key,
                currentSigningPublicKey: Data([0x04, 0x05, 0x06])
            )
        )
    }

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

    func testPairingTimeoutPolicySeparatesUserDecisionFromTransport() {
        XCTAssertEqual(
            PairingTimeoutPolicy.duration(for: .outboundTransport),
            15
        )
        XCTAssertEqual(
            PairingTimeoutPolicy.duration(for: .inboundTransport),
            10
        )
        XCTAssertEqual(
            PairingTimeoutPolicy.duration(for: .protocolNegotiation),
            60
        )
        XCTAssertEqual(
            PairingTimeoutPolicy.duration(for: .userDecision),
            120
        )
        XCTAssertEqual(
            PairingTimeoutPolicy.duration(for: .completion),
            30
        )
        XCTAssertGreaterThan(
            PairingTimeoutPolicy.duration(for: .userDecision),
            PairingTimeoutPolicy.duration(for: .protocolNegotiation)
        )
        XCTAssertLessThan(
            PairingTimeoutPolicy.duration(for: .completion),
            PairingTimeoutPolicy.duration(for: .userDecision)
        )
    }

    func testFirstRevealOrConfirmationIsRecorded() {
        XCTAssertTrue(
            PairingContributionPolicy.shouldRecordContribution(
                existingContribution: nil
            )
        )
    }

    func testDuplicateRevealOrConfirmationIsIgnored() {
        // A resent reveal/confirmation for a request that already has a
        // recorded contribution must not restart the 120s user-decision
        // timeout or let a peer keep re-arming its own request slot by
        // repeating a message.
        XCTAssertFalse(
            PairingContributionPolicy.shouldRecordContribution(
                existingContribution: Data([0x01, 0x02, 0x03])
            )
        )
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
