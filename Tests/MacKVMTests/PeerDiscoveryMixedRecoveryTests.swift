import CryptoKit
import Foundation
import Network
import XCTest
@testable import MacKVM
@testable import MacKVMCore

final class PeerDiscoveryMixedRecoveryTests: XCTestCase {
    func testOrdinaryListenerFailureSurvivesBrowserPolicyDenial() throws {
        try assertMixedRecovery(
            ordinaryFailure: .listener,
            policyDeniedFailure: .browser,
            ordinaryFailsFirst: true
        )
    }

    func testOrdinaryBrowserFailureSurvivesListenerPolicyDenial() throws {
        try assertMixedRecovery(
            ordinaryFailure: .browser,
            policyDeniedFailure: .listener,
            ordinaryFailsFirst: true
        )
    }

    func testPolicyDenialFirstStillSchedulesTheOtherMissingService() throws {
        try assertMixedRecovery(
            ordinaryFailure: .listener,
            policyDeniedFailure: .browser,
            ordinaryFailsFirst: false
        )
    }

    func testListenerPolicyDenialFirstStillSchedulesMissingBrowser() throws {
        try assertMixedRecovery(
            ordinaryFailure: .browser,
            policyDeniedFailure: .listener,
            ordinaryFailsFirst: false
        )
    }

    func testGeneralRecoveryDefersDuringPairingWithoutCreatingTimerLoops() throws {
        let service = try makeService()
        service.prepareNetworkRecoveryForTesting(
            missingComponents: [],
            pairingIsInFlight: true
        )
        service.failNetworkServiceForTesting(.listener, policyDenied: false)

        let firstSchedule = service.networkRecoverySnapshotForTesting()
        XCTAssertTrue(firstSchedule.generalRetryScheduled)
        XCTAssertEqual(firstSchedule.attempt, 1)

        service.fireNetworkRecoveryForTesting(
            generation: firstSchedule.generation
        )
        let deferred = service.networkRecoverySnapshotForTesting()
        XCTAssertTrue(deferred.generalRetryScheduled)
        XCTAssertFalse(deferred.blockedRetryScheduled)
        XCTAssertTrue(deferred.restartedComponents.isEmpty)
        XCTAssertEqual(deferred.attempt, 2)

        service.failNetworkServiceForTesting(.listener, policyDenied: false)
        let duplicateFailure = service.networkRecoverySnapshotForTesting()
        XCTAssertTrue(duplicateFailure.generalRetryScheduled)
        XCTAssertEqual(duplicateFailure.attempt, 2)

        service.prepareNetworkRecoveryForTesting(
            missingComponents: [.listener],
            pairingIsInFlight: false
        )
        service.fireNetworkRecoveryForTesting(
            generation: duplicateFailure.generation
        )
        let recovered = service.networkRecoverySnapshotForTesting()
        XCTAssertFalse(recovered.generalRetryScheduled)
        XCTAssertEqual(recovered.restartedComponents, [.listener])
        stop(service)
    }

    func testStopFencesAnAlreadyScheduledGeneralRecovery() throws {
        let service = try makeService()
        service.prepareNetworkRecoveryForTesting(missingComponents: [])
        service.failNetworkServiceForTesting(.browser, policyDenied: false)
        let scheduled = service.networkRecoverySnapshotForTesting()
        XCTAssertTrue(scheduled.generalRetryScheduled)

        stop(service)
        service.fireNetworkRecoveryForTesting(generation: scheduled.generation)

        let stopped = service.networkRecoverySnapshotForTesting()
        XCTAssertFalse(stopped.generalRetryScheduled)
        XCTAssertFalse(stopped.blockedRetryScheduled)
        XCTAssertTrue(stopped.restartedComponents.isEmpty)
    }

    func testSuccessfulProbePublishesItsPeerIDBeforeClearingProbeState() throws {
        let service = try makeService()
        let expectedPeerID = UUID()
        let recovered = expectation(description: "Recovered peer identity")
        service.onLocalNetworkAccessRecovered = { peerID in
            XCTAssertEqual(peerID, expectedPeerID)
            recovered.fulfill()
        }

        let remainingProbePeerID = service.finishLocalNetworkProbeForTesting(
            peerID: expectedPeerID,
            result: .reachable
        )

        XCTAssertNil(remainingProbePeerID)
        wait(for: [recovered], timeout: 1)
        stop(service)
    }

    private func assertMixedRecovery(
        ordinaryFailure: NetworkServiceComponent,
        policyDeniedFailure: NetworkServiceComponent,
        ordinaryFailsFirst: Bool
    ) throws {
        let service = try makeService()
        service.prepareNetworkRecoveryForTesting(missingComponents: [])

        if ordinaryFailsFirst {
            service.failNetworkServiceForTesting(
                ordinaryFailure,
                policyDenied: false
            )
            service.failNetworkServiceForTesting(
                policyDeniedFailure,
                policyDenied: true
            )
        } else {
            service.failNetworkServiceForTesting(
                policyDeniedFailure,
                policyDenied: true
            )
            service.failNetworkServiceForTesting(
                ordinaryFailure,
                policyDenied: false
            )
        }

        let mixedFailure = service.networkRecoverySnapshotForTesting()
        XCTAssertTrue(mixedFailure.generalRetryScheduled)
        XCTAssertTrue(mixedFailure.blockedRetryScheduled)
        XCTAssertEqual(mixedFailure.attempt, 1)
        XCTAssertEqual(
            mixedFailure.missingComponents,
            [ordinaryFailure, policyDeniedFailure]
        )

        service.recoverBlockedNetworkServiceForTesting(policyDeniedFailure)
        let blockedComponentReady = service.networkRecoverySnapshotForTesting()
        XCTAssertTrue(blockedComponentReady.generalRetryScheduled)
        XCTAssertFalse(blockedComponentReady.blockedRetryScheduled)
        XCTAssertEqual(blockedComponentReady.attempt, 1)

        service.fireNetworkRecoveryForTesting(
            generation: blockedComponentReady.generation
        )
        let ordinaryComponentRestarted = service.networkRecoverySnapshotForTesting()
        XCTAssertFalse(ordinaryComponentRestarted.generalRetryScheduled)
        XCTAssertEqual(
            ordinaryComponentRestarted.restartedComponents,
            [ordinaryFailure]
        )
        XCTAssertEqual(
            ordinaryComponentRestarted.missingComponents,
            []
        )
        stop(service)
    }

    private func makeService() throws -> PeerDiscoveryService {
        let privateKey = P256.Signing.PrivateKey()
        let credentials = DeviceCredentials(
            identity: PeerIdentity(
                name: "Recovery Test Mac",
                signingPublicKey: privateKey.publicKey.x963Representation
            ),
            privateKey: privateKey,
            wasLoadedFromStorage: false
        )
        let suiteName = "PeerDiscoveryMixedRecoveryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let registry = PairingRegistry(
            testDefaults: defaults,
            storageKey: "pairedPeers",
            persistenceApplicationID: suiteName
        )
        return PeerDiscoveryService(credentials: credentials, registry: registry)
    }

    private func stop(_ service: PeerDiscoveryService) {
        service.stop()
        service.waitForQueuedWorkForTesting()
    }
}
