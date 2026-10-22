import CryptoKit
import Foundation
import Network
import XCTest
@testable import MacKVM
@testable import MacKVMCore

final class LocalNetworkCheckLifecycleTests: XCTestCase {
    func testProbeRequiresTCPReadyAndOnlyExactDenialReportsBlocked() {
        let refused = NWError.posix(.ECONNREFUSED)
        XCTAssertEqual(
            LocalNetworkCheckPolicy.decision(
                for: .ready,
                unsatisfiedReason: nil
            ),
            .finish(.reachable)
        )
        XCTAssertEqual(
            LocalNetworkCheckPolicy.decision(
                for: .waiting(refused),
                unsatisfiedReason: .localNetworkDenied
            ),
            .finish(.blocked)
        )
        XCTAssertEqual(
            LocalNetworkCheckPolicy.decision(
                for: .failed(refused),
                unsatisfiedReason: .localNetworkDenied
            ),
            .finish(.blocked)
        )
        XCTAssertEqual(
            LocalNetworkCheckPolicy.decision(
                for: .waiting(refused),
                unsatisfiedReason: .notAvailable
            ),
            .wait
        )
        // A satisfied path or a connection that is still preparing cannot
        // establish that a fresh peer TCP connection works.
        XCTAssertEqual(
            LocalNetworkCheckPolicy.decision(
                for: .preparing,
                unsatisfiedReason: nil
            ),
            .wait
        )
        XCTAssertEqual(
            LocalNetworkCheckPolicy.decision(
                for: .failed(refused),
                unsatisfiedReason: .notAvailable
            ),
            .finish(.unconfirmed)
        )
        XCTAssertEqual(LocalNetworkCheckPolicy.timeoutResult(), .unconfirmed)
    }

    func testStaleProbeCallbackCannotCompleteANewerCheck() {
        XCTAssertTrue(
            LocalNetworkCheckPolicy.acceptsProbeCallback(
                callbackGeneration: 8,
                currentGeneration: 8
            )
        )
        XCTAssertFalse(
            LocalNetworkCheckPolicy.acceptsProbeCallback(
                callbackGeneration: 7,
                currentGeneration: 8
            )
        )
    }

    func testProbeDenialPublishesAndInconclusiveResultsRetainBlockedState() throws {
        let localKey = P256.Signing.PrivateKey()
        let credentials = DeviceCredentials(
            identity: PeerIdentity(
                name: "Local Mac",
                signingPublicKey: localKey.publicKey.x963Representation
            ),
            privateKey: localKey,
            wasLoadedFromStorage: false
        )
        let suiteName = "LocalNetworkProbeStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = PairingRegistry(
            testDefaults: defaults,
            storageKey: "pairedPeers",
            persistenceApplicationID: suiteName
        )
        let service = PeerDiscoveryService(
            credentials: credentials,
            registry: registry
        )

        recordProbeResult(.blocked, on: service)
        XCTAssertTrue(service.localNetworkAccessBlocked)

        recordProbeResult(.noPeer, on: service)
        XCTAssertTrue(service.localNetworkAccessBlocked)
        recordProbeResult(.unconfirmed, on: service)
        XCTAssertTrue(service.localNetworkAccessBlocked)

        recordProbeResult(.reachable, on: service)
        XCTAssertFalse(service.localNetworkAccessBlocked)
    }

    func testRecoveryTimerPausesForPairingAndResumesWithADiscoveredPeer() {
        var recovery = LocalNetworkProbeRecoveryState()
        XCTAssertEqual(LocalNetworkProbeRecoveryState.retryInterval, 4)
        XCTAssertEqual(
            recovery.reconcile(
                isBlocked: false,
                networkServicesStarted: true,
                hasDiscoveredPeer: true
            ),
            .none
        )
        XCTAssertEqual(
            recovery.reconcile(
                isBlocked: true,
                networkServicesStarted: false,
                hasDiscoveredPeer: true
            ),
            .none
        )
        XCTAssertEqual(
            recovery.reconcile(
                isBlocked: true,
                networkServicesStarted: true,
                hasDiscoveredPeer: false
            ),
            .none
        )

        guard case let .schedule(firstGeneration) = recovery.reconcile(
            isBlocked: true,
            networkServicesStarted: true,
            hasDiscoveredPeer: true
        ) else {
            return XCTFail("A blocked source with a peer should schedule recovery")
        }
        XCTAssertTrue(
            LocalNetworkProbeRecoveryState.shouldStartProbe(
                isBlocked: true,
                networkServicesStarted: true,
                pairingIsInFlight: false,
                hasDiscoveredPeer: true,
                probeIsInFlight: false
            )
        )
        XCTAssertTrue(recovery.beginRetry(generation: firstGeneration))
        XCTAssertFalse(
            LocalNetworkProbeRecoveryState.shouldStartProbe(
                isBlocked: true,
                networkServicesStarted: true,
                pairingIsInFlight: true,
                hasDiscoveredPeer: true,
                probeIsInFlight: false
            )
        )
        XCTAssertFalse(
            LocalNetworkProbeRecoveryState.shouldStartProbe(
                isBlocked: true,
                networkServicesStarted: true,
                pairingIsInFlight: false,
                hasDiscoveredPeer: true,
                probeIsInFlight: true
            )
        )

        guard case let .schedule(pausedGeneration) = recovery.reconcile(
            isBlocked: true,
            networkServicesStarted: true,
            hasDiscoveredPeer: true
        ) else {
            return XCTFail("Recovery should remain scheduled while pairing pauses it")
        }
        XCTAssertEqual(
            recovery.reconcile(
                isBlocked: true,
                networkServicesStarted: true,
                hasDiscoveredPeer: false
            ),
            .cancel
        )
        XCTAssertFalse(recovery.beginRetry(generation: pausedGeneration))

        guard case let .schedule(resumedGeneration) = recovery.reconcile(
            isBlocked: true,
            networkServicesStarted: true,
            hasDiscoveredPeer: true
        ) else {
            return XCTFail("Discovery of a peer should resume recovery")
        }
        XCTAssertEqual(recovery.stop(), .cancel)
        XCTAssertFalse(recovery.beginRetry(generation: resumedGeneration))
        XCTAssertEqual(
            recovery.reconcile(
                isBlocked: true,
                networkServicesStarted: false,
                hasDiscoveredPeer: true
            ),
            .none
        )
    }

    func testProbeRecoveryBackoffCapsAndResetsWhenRecoveryBecomesIneligible() {
        var recovery = LocalNetworkProbeRecoveryState()
        let expectedIntervals: [TimeInterval] = [4, 8, 16, 32, 60, 60]

        for interval in expectedIntervals {
            guard case let .schedule(generation) = recovery.reconcile(
                isBlocked: true,
                networkServicesStarted: true,
                hasDiscoveredPeer: true
            ) else {
                return XCTFail("Eligible recovery should schedule a probe")
            }
            XCTAssertEqual(recovery.nextRetryInterval(), interval)
            XCTAssertTrue(recovery.beginRetry(generation: generation))
            XCTAssertFalse(
                LocalNetworkProbeRecoveryState.shouldStartProbe(
                    isBlocked: true,
                    networkServicesStarted: true,
                    pairingIsInFlight: true,
                    hasDiscoveredPeer: true,
                    probeIsInFlight: false
                )
            )
            // A timer deferred by pairing is not an attempted probe.
            XCTAssertEqual(recovery.nextRetryInterval(), interval)
            XCTAssertTrue(
                LocalNetworkProbeRecoveryState.shouldStartProbe(
                    isBlocked: true,
                    networkServicesStarted: true,
                    pairingIsInFlight: false,
                    hasDiscoveredPeer: true,
                    probeIsInFlight: false
                )
            )
            recovery.recordRetryAttempt()
        }

        guard case let .schedule(lastGeneration) = recovery.reconcile(
            isBlocked: true,
            networkServicesStarted: true,
            hasDiscoveredPeer: true
        ) else {
            return XCTFail("Capped recovery should schedule another probe")
        }
        XCTAssertEqual(recovery.nextRetryInterval(), 60)
        XCTAssertEqual(
            recovery.reconcile(
                isBlocked: true,
                networkServicesStarted: true,
                hasDiscoveredPeer: false
            ),
            .cancel
        )
        XCTAssertFalse(recovery.beginRetry(generation: lastGeneration))
        XCTAssertEqual(recovery.nextRetryInterval(), 4)

        recovery.recordRetryAttempt()
        XCTAssertEqual(recovery.nextRetryInterval(), 8)
        recovery.stop()
        XCTAssertEqual(recovery.nextRetryInterval(), 4)
    }

    func testPendingInboundConnectionMakesNetworkCheckBusy() {
        XCTAssertTrue(
            LocalNetworkCheckPolicy.hasPairingInFlight(
                activeOutboundRequest: false,
                trackedRequestCount: 0,
                incomingConnectionCount: 1,
                pendingConfirmation: false,
                persistenceJobCount: 0,
                hasScheduledRetry: false
            )
        )
    }

    func testPreferredPeerIsUsedOnlyWhenItsEndpointIsKnown() {
        let preferred = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let pairedFallback = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
        let other = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let available = [other, pairedFallback, preferred]

        XCTAssertEqual(
            LocalNetworkCheckPolicy.preferredPeerID(
                requestedPeerID: preferred,
                pairedPeerIDs: [pairedFallback],
                availablePeerIDs: available
            ),
            preferred
        )
        XCTAssertNil(
            LocalNetworkCheckPolicy.preferredPeerID(
                requestedPeerID: UUID(),
                pairedPeerIDs: [pairedFallback],
                availablePeerIDs: available
            )
        )
        XCTAssertEqual(
            LocalNetworkCheckPolicy.preferredPeerID(
                requestedPeerID: nil,
                pairedPeerIDs: [pairedFallback],
                availablePeerIDs: available
            ),
            pairedFallback
        )
    }

    func testAutomaticDiscoveryWaitPreservesReadyBrowser() {
        XCTAssertFalse(
            LocalNetworkCheckPolicy.shouldRefreshBrowserForDiscoveryWait(
                isAutomatic: true,
                browserExists: true,
                browserIsReady: true
            )
        )
    }

    func testAutomaticDiscoveryWaitRefreshesMissingOrNotReadyBrowser() {
        XCTAssertTrue(
            LocalNetworkCheckPolicy.shouldRefreshBrowserForDiscoveryWait(
                isAutomatic: true,
                browserExists: false,
                browserIsReady: false
            )
        )
        XCTAssertTrue(
            LocalNetworkCheckPolicy.shouldRefreshBrowserForDiscoveryWait(
                isAutomatic: true,
                browserExists: true,
                browserIsReady: false
            )
        )
        XCTAssertTrue(
            LocalNetworkCheckPolicy.shouldRefreshBrowserForDiscoveryWait(
                isAutomatic: true,
                browserExists: true,
                browserIsReady: false,
                listenerExists: false
            )
        )
    }

    func testManualDiscoveryWaitRefreshesEvenWhenBrowserIsReady() {
        XCTAssertTrue(
            LocalNetworkCheckPolicy.shouldRefreshBrowserForDiscoveryWait(
                isAutomatic: false,
                browserExists: true,
                browserIsReady: true
            )
        )
    }

    func testManualDiscoveryWaitKeepsMissingServiceRecoveryBehavior() {
        XCTAssertFalse(
            LocalNetworkCheckPolicy.shouldRefreshBrowserForDiscoveryWait(
                isAutomatic: false,
                browserExists: true,
                browserIsReady: true,
                listenerExists: false
            )
        )
    }

    func testNetworkCheckDoesNotInterruptPendingPairing() throws {
        let localKey = P256.Signing.PrivateKey()
        let credentials = DeviceCredentials(
            identity: PeerIdentity(
                name: "Local Mac",
                signingPublicKey: localKey.publicKey.x963Representation
            ),
            privateKey: localKey,
            wasLoadedFromStorage: false
        )
        let suiteName = "LocalNetworkCheckLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = PairingRegistry(
            testDefaults: defaults,
            storageKey: "pairedPeers",
            persistenceApplicationID: suiteName
        )
        let service = PeerDiscoveryService(
            credentials: credentials,
            registry: registry
        )
        let peerKey = P256.Signing.PrivateKey()
        let peer = PeerIdentity(
            name: "Remote Mac",
            signingPublicKey: peerKey.publicKey.x963Representation
        )
        let requestID = UUID()
        service.prepareOutboundPairingForTesting(
            with: peer,
            requestID: requestID
        )
        let stateBefore = service.pairingRequestStateForTesting()
        let checkFinished = expectation(description: "Check reports pairing busy")

        service.checkLocalNetworkAccess { result in
            XCTAssertEqual(result, .busy)
            checkFinished.fulfill()
        }

        wait(for: [checkFinished], timeout: 1)
        let stateAfter = service.pairingRequestStateForTesting()
        XCTAssertEqual(stateAfter.outboundRequestID, stateBefore.outboundRequestID)
        XCTAssertEqual(stateAfter.trackedRequestIDs, stateBefore.trackedRequestIDs)
        XCTAssertEqual(service.pendingPairingConfirmation?.id, requestID)

        service.stop()
        service.waitForQueuedWorkForTesting()
    }

    func testSuccessfulProbeRetriesOnlyASelectedStuckOutboundAttempt() {
        let waiting = NWConnection.State.waiting(.posix(.ECONNREFUSED))
        XCTAssertTrue(shouldRestartPendingOutbound(state: waiting))
        XCTAssertTrue(shouldRestartPendingOutbound(state: .preparing))
        XCTAssertFalse(shouldRestartPendingOutbound(state: .ready))
        XCTAssertFalse(
            shouldRestartPendingOutbound(state: waiting, hasActiveContext: true)
        )
        XCTAssertFalse(
            shouldRestartPendingOutbound(
                state: waiting,
                hasDesiredPeer: false
            )
        )
        XCTAssertFalse(
            shouldRestartPendingOutbound(
                state: waiting,
                desiredPeerIsLocallyDisconnected: true
            )
        )
        XCTAssertFalse(
            shouldRestartPendingOutbound(state: waiting, contextCount: 2)
        )
        XCTAssertFalse(
            shouldRestartPendingOutbound(
                state: waiting,
                contextMatchesDesiredPeer: false
            )
        )
    }

    private func shouldRestartPendingOutbound(
        state: NWConnection.State,
        isSystemSleeping: Bool = false,
        hasDesiredPeer: Bool = true,
        desiredPeerIsLocallyDisconnected: Bool = false,
        hasPendingConnect: Bool = false,
        hasActiveContext: Bool = false,
        contextCount: Int = 1,
        contextMatchesDesiredPeer: Bool = true,
        contextIsInitiator: Bool = true,
        contextIsAuthenticated: Bool = false,
        contextIsClosing: Bool = false
    ) -> Bool {
        SecureSessionNetworkCheckRetryPolicy.shouldRestartPendingOutbound(
            isSystemSleeping: isSystemSleeping,
            hasDesiredPeer: hasDesiredPeer,
            desiredPeerIsLocallyDisconnected:
                desiredPeerIsLocallyDisconnected,
            hasPendingConnect: hasPendingConnect,
            hasActiveContext: hasActiveContext,
            contextCount: contextCount,
            contextMatchesDesiredPeer: contextMatchesDesiredPeer,
            contextIsInitiator: contextIsInitiator,
            contextIsAuthenticated: contextIsAuthenticated,
            contextIsClosing: contextIsClosing,
            connectionState: state
        )
    }

    private func recordProbeResult(
        _ result: LocalNetworkCheckResult,
        on service: PeerDiscoveryService
    ) {
        let published = expectation(description: "Probe result published")
        service.recordLocalNetworkProbeResultForTesting(result) {
            published.fulfill()
        }
        wait(for: [published], timeout: 1)
    }
}
