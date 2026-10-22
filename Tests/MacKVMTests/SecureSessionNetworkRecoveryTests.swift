import CryptoKit
import Foundation
import Network
import XCTest
@testable import MacKVM
@testable import MacKVMCore

final class SecureSessionNetworkRecoveryTests: XCTestCase {
    private struct Fixture {
        let service: SecureSessionService
        let registry: PairingRegistry
        let defaults: UserDefaults
        let suiteName: String

        func cleanUp() {
            service.stop()
            _ = service.sleepLifecycleSnapshot
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testWaitingDNSPolicyDenialRecordsAndRestartsOnlyThatService() throws {
        let lock = NSLock()
        var started: [NetworkServiceComponent] = []
        var cancelled: [NetworkServiceComponent] = []
        let fixture = try makeFixture(
            start: { component in
                lock.lock()
                started.append(component)
                lock.unlock()
            },
            cancel: { component in
                lock.lock()
                cancelled.append(component)
                lock.unlock()
            },
            recoveryDelay: { _ in 30 }
        )
        defer { fixture.cleanUp() }

        fixture.service.startNetworkServicesForTesting()
        XCTAssertEqual(
            fixture.service.currentNetworkServiceGenerationForTesting(.listener) != nil,
            true
        )
        XCTAssertEqual(
            fixture.service.currentNetworkServiceGenerationForTesting(.browser) != nil,
            true
        )

        let listenerGeneration = try XCTUnwrap(
            fixture.service.currentNetworkServiceGenerationForTesting(.listener)
        )
        let browserGeneration = try XCTUnwrap(
            fixture.service.currentNetworkServiceGenerationForTesting(.browser)
        )
        let denied = NWError.dns(
            DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
        )
        fixture.service.reportNetworkServiceStateForTesting(
            .waiting(denied),
            for: .listener
        )

        waitUntil { fixture.service.lastListenerError != nil }
        XCTAssertEqual(fixture.service.lastListenerError?.state, "waiting")
        XCTAssertEqual(
            fixture.service.lastListenerError?.code,
            Int(kDNSServiceErr_PolicyDenied)
        )
        XCTAssertTrue(fixture.service.localNetworkAccessBlocked)
        XCTAssertNil(
            fixture.service.currentNetworkServiceGenerationForTesting(.listener)
        )
        XCTAssertEqual(
            fixture.service.currentNetworkServiceGenerationForTesting(.browser),
            browserGeneration
        )
        XCTAssertGreaterThan(listenerGeneration, 0)

        // A successful probe must refresh the missing listener even when no
        // outbound SecureSession context exists. The healthy browser remains
        // running and the service-denial source remains visible until ready.
        fixture.service.retryPendingConnectionAfterSuccessfulLocalNetworkCheck(
            for: UUID()
        )
        let refreshedListenerGeneration = try XCTUnwrap(
            fixture.service.currentNetworkServiceGenerationForTesting(.listener)
        )
        XCTAssertGreaterThan(refreshedListenerGeneration, listenerGeneration)
        XCTAssertEqual(
            fixture.service.currentNetworkServiceGenerationForTesting(.browser),
            browserGeneration
        )
        XCTAssertTrue(fixture.service.localNetworkAccessBlocked)

        // A callback from the retired service instance must not affect the
        // replacement, even if it reports a later failure.
        fixture.service.reportNetworkServiceStateForTesting(
            .failed(.posix(.ECONNREFUSED)),
            for: .listener,
            generation: listenerGeneration
        )
        XCTAssertEqual(
            fixture.service.currentNetworkServiceGenerationForTesting(.listener),
            refreshedListenerGeneration
        )

        fixture.service.reportNetworkServiceStateForTesting(.ready, for: .listener)
        fixture.service.reportNetworkServiceStateForTesting(.ready, for: .browser)
        waitUntil { !fixture.service.localNetworkAccessBlocked }
        lock.lock()
        let startedSnapshot = started
        let cancelledSnapshot = cancelled
        lock.unlock()
        XCTAssertEqual(startedSnapshot.filter { $0 == .listener }.count, 2)
        XCTAssertEqual(startedSnapshot.filter { $0 == .browser }.count, 1)
        XCTAssertEqual(cancelledSnapshot, [.listener])
    }

    func testMismatchedProbeRefreshesServicesWithoutRetryingSelectedOutbound() throws {
        let fixture = try makeFixture(recoveryDelay: { _ in 30 })
        defer { fixture.cleanUp() }
        fixture.service.startNetworkServicesForTesting()
        let originalListener = try XCTUnwrap(
            fixture.service.currentNetworkServiceGenerationForTesting(.listener)
        )
        let denied = NWError.dns(
            DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
        )
        fixture.service.reportNetworkServiceStateForTesting(
            .waiting(denied),
            for: .listener,
            generation: originalListener
        )
        waitUntil {
            fixture.service.currentNetworkServiceGenerationForTesting(.listener)
                == nil
        }

        let selectedPeer = makePeer(name: "Selected Mac")
        fixture.registry.add(selectedPeer)
        let trustedKeysBefore = fixture.registry.pairedPeers
        fixture.service.connect(to: selectedPeer.id)
        waitUntil { fixture.service.connectingPeerID == selectedPeer.id }
        fixture.service.installUnauthenticatedContextForTesting(to: selectedPeer)

        fixture.service.retryPendingConnectionAfterSuccessfulLocalNetworkCheck(
            for: UUID()
        )
        let refreshedListener = try XCTUnwrap(
            fixture.service.currentNetworkServiceGenerationForTesting(.listener)
        )

        XCTAssertGreaterThan(refreshedListener, originalListener)
        XCTAssertTrue(
            fixture.service.hasUnauthenticatedContextForTesting(
                to: selectedPeer.id
            )
        )
        XCTAssertEqual(
            fixture.service.sleepLifecycleSnapshot.desiredPeerID,
            selectedPeer.id
        )
        XCTAssertTrue(fixture.service.localNetworkAccessBlocked)
        XCTAssertEqual(fixture.registry.pairedPeers, trustedKeysBefore)
        fixture.service.cancelConnectionAttempt(to: selectedPeer.id)
    }

    func testGenericWaitingErrorIsRecordedWithoutPolicyRecovery() throws {
        let fixture = try makeFixture(
            recoveryDelay: { _ in 30 }
        )
        defer { fixture.cleanUp() }
        fixture.service.startNetworkServicesForTesting()
        let generation = try XCTUnwrap(
            fixture.service.currentNetworkServiceGenerationForTesting(.browser)
        )

        fixture.service.reportNetworkServiceStateForTesting(
            .waiting(.posix(.ENETUNREACH)),
            for: .browser
        )

        waitUntil { fixture.service.lastBrowserError != nil }
        XCTAssertEqual(fixture.service.lastBrowserError?.state, "waiting")
        XCTAssertEqual(
            fixture.service.currentNetworkServiceGenerationForTesting(.browser),
            generation
        )
        XCTAssertFalse(fixture.service.localNetworkAccessBlocked)
    }

    func testWaitingComponentMustReturnToReadyBeforeRecoveryIsReported() throws {
        let fixture = try makeFixture(recoveryDelay: { _ in 30 })
        defer { fixture.cleanUp() }
        fixture.service.startNetworkServicesForTesting()
        let originalListener = try XCTUnwrap(
            fixture.service.currentNetworkServiceGenerationForTesting(.listener)
        )
        let browser = try XCTUnwrap(
            fixture.service.currentNetworkServiceGenerationForTesting(.browser)
        )
        fixture.service.reportNetworkServiceStateForTesting(
            .ready,
            for: .listener,
            generation: originalListener
        )
        fixture.service.reportNetworkServiceStateForTesting(
            .ready,
            for: .browser,
            generation: browser
        )

        fixture.service.reportNetworkServiceStateForTesting(
            .failed(.posix(.ECONNREFUSED)),
            for: .listener,
            generation: originalListener
        )
        fixture.service.reportNetworkServiceStateForTesting(
            .waiting(.posix(.ENETUNREACH)),
            for: .browser,
            generation: browser
        )
        fixture.service.startNetworkServicesForTesting()
        let recoveredListener = try XCTUnwrap(
            fixture.service.currentNetworkServiceGenerationForTesting(.listener)
        )
        fixture.service.reportNetworkServiceStateForTesting(
            .ready,
            for: .listener,
            generation: recoveredListener
        )
        drainMainQueue()
        XCTAssertNotEqual(fixture.service.status, "Secure discovery recovered")

        fixture.service.reportNetworkServiceStateForTesting(
            .ready,
            for: .browser,
            generation: browser
        )
        waitUntil { fixture.service.status == "Secure discovery recovered" }
    }

    func testAuthenticatedPublicationClearsOnlyTransportDenialSource() throws {
        let fixture = try makeFixture(recoveryDelay: { _ in 30 })
        defer { fixture.cleanUp() }
        fixture.service.startNetworkServicesForTesting()

        fixture.service.setTransportLocalNetworkAccessBlockedForTesting(true)
        waitUntil { fixture.service.localNetworkAccessBlocked }
        fixture.service.publishAuthenticatedPeerForTesting(UUID())
        waitUntil { !fixture.service.localNetworkAccessBlocked }

        let denied = NWError.dns(
            DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
        )
        fixture.service.reportNetworkServiceStateForTesting(
            .waiting(denied),
            for: .browser
        )
        waitUntil { fixture.service.localNetworkAccessBlocked }

        // Publishing an authenticated session clears stale transport-only
        // evidence, while the browser's policy denial remains until that
        // component reports ready.
        fixture.service.setTransportLocalNetworkAccessBlockedForTesting(false)
        fixture.service.publishAuthenticatedPeerForTesting(UUID())
        drainMainQueue()
        XCTAssertTrue(fixture.service.localNetworkAccessBlocked)

        fixture.service.retryPendingConnectionAfterSuccessfulLocalNetworkCheck()
        let recoveredBrowser = try XCTUnwrap(
            fixture.service.currentNetworkServiceGenerationForTesting(.browser)
        )
        fixture.service.reportNetworkServiceStateForTesting(
            .ready,
            for: .browser,
            generation: recoveredBrowser
        )
        waitUntil { !fixture.service.localNetworkAccessBlocked }
    }

    func testConnectTracksDiscoveryWaitAndRepeatedConnectRetriesSamePeer() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let peer = makePeer(name: "Paired Mac")
        fixture.registry.add(peer)
        let trustedKeysBefore = fixture.registry.pairedPeers

        fixture.service.connect(to: peer.id)
        XCTAssertEqual(fixture.service.sleepLifecycleSnapshot.desiredPeerID, peer.id)
        waitUntil { fixture.service.connectingPeerID == peer.id }

        // Model a stalled outbound Network.framework connection in `.setup`
        // without starting a socket. A repeated Connect must retire this
        // context instead of taking the old generic existing-session path.
        fixture.service.installUnauthenticatedContextForTesting(to: peer)
        XCTAssertTrue(
            fixture.service.hasUnauthenticatedContextForTesting(to: peer.id)
        )

        fixture.service.connect(to: peer.id)
        XCTAssertEqual(fixture.service.sleepLifecycleSnapshot.desiredPeerID, peer.id)
        waitUntil { fixture.service.connectingPeerID == peer.id }
        drainMainQueue()
        XCTAssertNotEqual(
            fixture.service.status,
            "Disconnect the current secure session first"
        )
        XCTAssertFalse(
            fixture.service.hasUnauthenticatedContextForTesting(to: peer.id)
        )
        XCTAssertEqual(fixture.registry.pairedPeers, trustedKeysBefore)
        fixture.service.cancelConnectionAttempt(to: peer.id)
    }

    func testCancelDuringDiscoveryWaitClearsIntentAndPreservesTrust() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let peer = makePeer(name: "Paired Mac")
        fixture.registry.add(peer)
        let trustedKeysBefore = fixture.registry.pairedPeers

        fixture.service.connect(to: peer.id)
        XCTAssertEqual(fixture.service.sleepLifecycleSnapshot.desiredPeerID, peer.id)
        waitUntil { fixture.service.connectingPeerID == peer.id }

        fixture.service.cancelConnectionAttempt(to: peer.id)
        let cancelledSnapshot = fixture.service.sleepLifecycleSnapshot
        XCTAssertNil(cancelledSnapshot.desiredPeerID)
        XCTAssertFalse(cancelledSnapshot.hasScheduledReconnect)
        XCTAssertEqual(fixture.registry.pairedPeers, trustedKeysBefore)
        waitUntil { fixture.service.connectingPeerID == nil }
        XCTAssertTrue(fixture.service.isConnectionAttemptCancelledForTesting(to: peer.id))

        // A pairing callback already queued before cancellation cannot restore
        // the old connection intent. A newer pairing generation can still
        // create a fresh attempt.
        fixture.service.connectAutomaticallyAfterPairing(to: peer.id)
        XCTAssertNil(fixture.service.sleepLifecycleSnapshot.desiredPeerID)
        fixture.service.connectAutomaticallyAfterPairing(
            to: peer.id,
            pairingGeneration: fixture.registry.generation(for: peer.id) + 1
        )
        XCTAssertEqual(fixture.service.sleepLifecycleSnapshot.desiredPeerID, peer.id)
        XCTAssertEqual(fixture.registry.pairedPeers, trustedKeysBefore)
    }

    func testCancelWrongPeerAndAuthenticatedPeerAreNoOps() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let selectedPeer = makePeer(name: "Selected Mac")
        fixture.registry.add(selectedPeer)
        let trustedKeysBefore = fixture.registry.pairedPeers
        let unrelatedPeerID = UUID()

        fixture.service.connect(to: selectedPeer.id)
        XCTAssertEqual(
            fixture.service.sleepLifecycleSnapshot.desiredPeerID,
            selectedPeer.id
        )
        XCTAssertEqual(fixture.registry.pairedPeers, trustedKeysBefore)
        fixture.service.cancelConnectionAttempt(to: unrelatedPeerID)
        XCTAssertEqual(
            fixture.service.sleepLifecycleSnapshot.desiredPeerID,
            selectedPeer.id
        )
        XCTAssertEqual(fixture.registry.pairedPeers, trustedKeysBefore)

        fixture.service.installAuthenticatedContextForTesting(to: selectedPeer)
        fixture.service.cancelConnectionAttempt(to: selectedPeer.id)
        waitUntil { fixture.service.connectedPeerID == selectedPeer.id }
        XCTAssertEqual(
            fixture.service.sleepLifecycleSnapshot.desiredPeerID,
            selectedPeer.id
        )
        XCTAssertEqual(fixture.registry.pairedPeers, trustedKeysBefore)
        XCTAssertFalse(
            SecureSessionAttemptCancellationPolicy.shouldCancel(
                selectedPeerID: selectedPeer.id,
                desiredPeerID: selectedPeer.id,
                pendingPeerID: nil,
                activePeerID: selectedPeer.id,
                hasUnauthenticatedContext: true
            )
        )
    }

    func testCancelRemovesSamePeerResponderAndFencesLateCallbacks() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let selectedPeer = makePeer(name: "Selected Mac")
        let unrelatedPeer = makePeer(name: "Other Mac")
        fixture.registry.add(selectedPeer)
        fixture.registry.add(unrelatedPeer)
        let trustedKeysBefore = fixture.registry.pairedPeers

        fixture.service.connect(to: selectedPeer.id)
        XCTAssertEqual(
            fixture.service.sleepLifecycleSnapshot.desiredPeerID,
            selectedPeer.id
        )
        fixture.service.installUnauthenticatedContextForTesting(to: selectedPeer)
        fixture.service.installUnauthenticatedContextForTesting(
            to: selectedPeer,
            localRole: .responder
        )
        fixture.service.installUnauthenticatedContextForTesting(
            to: unrelatedPeer,
            localRole: .responder
        )
        fixture.service.cancelConnectionAttempt(to: selectedPeer.id)

        XCTAssertFalse(
            fixture.service.hasUnauthenticatedContextForTesting(
                to: selectedPeer.id
            )
        )
        XCTAssertTrue(
            fixture.service.hasUnauthenticatedContextForTesting(
                to: unrelatedPeer.id
            )
        )
        XCTAssertTrue(
            fixture.service.isConnectionAttemptCancelledForTesting(
                to: selectedPeer.id
            )
        )
        // A late callback that raced cancellation cannot reopen this same-peer
        // attempt; the production handshake path checks this fence after the
        // pinned identity and again immediately before authentication.
        XCTAssertTrue(
            fixture.service.isConnectionAttemptCancelledForTesting(
                to: selectedPeer.id
            )
        )
        XCTAssertFalse(
            fixture.service.isConnectionAttemptCancelledForTesting(
                to: unrelatedPeer.id
            )
        )
        XCTAssertEqual(
            fixture.service.sleepLifecycleSnapshot.desiredPeerID,
            nil
        )
        XCTAssertEqual(fixture.registry.pairedPeers, trustedKeysBefore)
        XCTAssertFalse(
            SecureSessionAttemptCancellationPolicy.shouldCancel(
                selectedPeerID: unrelatedPeer.id,
                desiredPeerID: nil,
                pendingPeerID: nil,
                activePeerID: nil,
                hasUnauthenticatedContext: false
            )
        )
    }

    private func makeFixture(
        start: ((NetworkServiceComponent) -> Void)? = nil,
        cancel: ((NetworkServiceComponent) -> Void)? = nil,
        recoveryDelay: ((Int) -> TimeInterval)? = nil
    ) throws -> Fixture {
        let suiteName = "SecureSessionNetworkRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let key = P256.Signing.PrivateKey()
        let credentials = DeviceCredentials(
            identity: PeerIdentity(
                name: "Local Mac",
                signingPublicKey: key.publicKey.x963Representation
            ),
            privateKey: key,
            wasLoadedFromStorage: false
        )
        let registry = PairingRegistry(
            testDefaults: defaults,
            storageKey: "pairedPeers",
            persistenceApplicationID: suiteName
        )
        let service = SecureSessionService(
            credentials: credentials,
            registry: registry,
            localModel: "Mac16,1",
            networkServicesEnabled: false,
            networkServiceStartHandlerForTesting: start ?? { _ in },
            networkServiceCancelHandlerForTesting: cancel ?? { _ in },
            networkRecoveryDelayForTesting: recoveryDelay
        )
        return Fixture(
            service: service,
            registry: registry,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func makePeer(name: String) -> PeerIdentity {
        let key = P256.Signing.PrivateKey()
        return PeerIdentity(
            name: name,
            signingPublicKey: key.publicKey.x963Representation
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition())
    }

    private func drainMainQueue() {
        let drained = expectation(description: "Main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }
}
