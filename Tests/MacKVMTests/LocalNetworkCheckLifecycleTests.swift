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
        let peerKey = P256.Signing.PrivateKey()
        let peerID = UUID()
        registry.add(PeerIdentity(
            id: peerID,
            name: "Paired Remote Mac",
            signingPublicKey: peerKey.publicKey.x963Representation
        ))
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

        recordProbeResult(.reachable, on: service, peerID: peerID)
        XCTAssertFalse(service.localNetworkAccessBlocked)
    }

    func testManualReachabilityFromUnpairedPeerDoesNotClearRecoveryState() throws {
        let localKey = P256.Signing.PrivateKey()
        let credentials = DeviceCredentials(
            identity: PeerIdentity(
                name: "Local Mac",
                signingPublicKey: localKey.publicKey.x963Representation
            ),
            privateKey: localKey,
            wasLoadedFromStorage: false
        )
        let suiteName = "UnpairedLocalNetworkProbeTests.\(UUID().uuidString)"
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
        let unpairedPeerID = UUID()
        var recoveredPeerID: UUID?
        service.onLocalNetworkAccessRecovered = { peerID in
            recoveredPeerID = peerID
        }

        recordProbeResult(.blocked, on: service)
        XCTAssertTrue(service.localNetworkAccessBlocked)
        let finished = expectation(description: "Manual probe completed")
        service.recordLocalNetworkProbeResultForTesting(
            .reachable,
            peerID: unpairedPeerID
        ) {
            finished.fulfill()
        }

        wait(for: [finished], timeout: 1)
        XCTAssertTrue(service.localNetworkAccessBlocked)
        XCTAssertNil(recoveredPeerID)
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

    func testInboundConnectionCountsOnlyAfterVerifiedPairingFrame() throws {
        let localKey = P256.Signing.PrivateKey()
        let credentials = DeviceCredentials(
            identity: PeerIdentity(
                name: "Local Mac",
                signingPublicKey: localKey.publicKey.x963Representation
            ),
            privateKey: localKey,
            wasLoadedFromStorage: false
        )
        let suiteName = "VerifiedInboundPairingTests.\(UUID().uuidString)"
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
        _ = service.installEmptyInboundConnectionForTesting()
        XCTAssertEqual(service.verifiedInboundConnectionCountForTesting(), 0)
        XCTAssertFalse(service.pairingIsInFlightForNetworkCheckForTesting())

        let peerKey = P256.Signing.PrivateKey()
        let peer = PeerIdentity(
            name: "Remote Mac",
            signingPublicKey: peerKey.publicKey.x963Representation
        )
        let request = PairingEnvelope.request(
            from: peer,
            commitment: Data(repeating: 1, count: SHA256.Digest.byteCount)
        )
        let attackerKey = P256.Signing.PrivateKey()
        let invalidSignature = try PairingWireCodec.encode(
            request,
            signingWith: attackerKey
        )
        _ = service.handleIncomingPairingFramesForTesting(
            invalidSignature,
            connectionEnded: true
        )
        XCTAssertEqual(service.verifiedInboundConnectionCountForTesting(), 0)

        let verifiedFrame = try PairingWireCodec.encode(
            request,
            signingWith: peerKey
        )
        let verifiedState = service.handleIncomingPairingFramesForTesting(
            verifiedFrame
        )
        XCTAssertEqual(verifiedState.verifiedInboundConnectionCount, 1)
        XCTAssertTrue(verifiedState.pairingIsInFlight)
        let verifiedRequestID = try XCTUnwrap(
            verifiedState.trackedRequestIDs.first
        )
        service.expirePairingRequestForTesting(requestID: verifiedRequestID)
        XCTAssertEqual(service.verifiedInboundConnectionCountForTesting(), 0)
        XCTAssertFalse(service.pairingIsInFlightForNetworkCheckForTesting())

        let nextRequest = PairingEnvelope.request(
            from: peer,
            requestID: UUID(),
            commitment: Data(repeating: 2, count: SHA256.Digest.byteCount)
        )
        let nextRequestState = service.handleIncomingPairingFramesForTesting(
            try PairingWireCodec.encode(nextRequest, signingWith: peerKey)
        )
        XCTAssertEqual(nextRequestState.verifiedInboundConnectionCount, 1)

        let stopped = expectation(description: "Verified connection state cleared")
        service.stop {
            XCTAssertEqual(service.verifiedInboundConnectionCountForTesting(), 0)
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 1)
    }

    func testInboundTransportTimeoutIsScheduledBeforeStartAndRemovesUnreadySocket() throws {
        let localKey = P256.Signing.PrivateKey()
        let credentials = DeviceCredentials(
            identity: PeerIdentity(
                name: "Local Mac",
                signingPublicKey: localKey.publicKey.x963Representation
            ),
            privateKey: localKey,
            wasLoadedFromStorage: false
        )
        let suiteName = "InboundTimeoutTests.\(UUID().uuidString)"
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
        let expired = expectation(description: "Unready inbound timeout expired")

        service.verifyInboundTimeoutForTesting(after: 0.02) {
            scheduledBeforeStart, removedAfterTimeout in
            XCTAssertTrue(scheduledBeforeStart)
            XCTAssertTrue(removedAfterTimeout)
            expired.fulfill()
        }

        wait(for: [expired], timeout: 1)
        service.stop()
        service.waitForQueuedWorkForTesting()
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
        XCTAssertEqual(
            LocalNetworkCheckPolicy.preferredPeerID(
                requestedPeerID: preferred,
                pairedPeerIDs: [pairedFallback],
                availablePeerIDs: available,
                allowUnpairedFallback: false
            ),
            pairedFallback
        )
        XCTAssertNil(
            LocalNetworkCheckPolicy.preferredPeerID(
                requestedPeerID: preferred,
                pairedPeerIDs: [],
                availablePeerIDs: available,
                allowUnpairedFallback: false
            )
        )
        XCTAssertEqual(
            LocalNetworkCheckPolicy.preferredPeerID(
                requestedPeerID: UUID(),
                pairedPeerIDs: [pairedFallback],
                availablePeerIDs: available,
                allowUnpairedFallback: false
            ),
            pairedFallback
        )
        XCTAssertNil(
            LocalNetworkCheckPolicy.preferredPeerID(
                requestedPeerID: nil,
                pairedPeerIDs: [],
                availablePeerIDs: available,
                allowUnpairedFallback: false
            )
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
        // A live session for a different peer does not block retrying this
        // selected peer's stalled outbound connection.
        XCTAssertTrue(
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
        XCTAssertTrue(
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
        hasActiveContext _: Bool = false,
        contextCount _: Int = 1,
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
            contextMatchesDesiredPeer: contextMatchesDesiredPeer,
            contextIsInitiator: contextIsInitiator,
            contextIsAuthenticated: contextIsAuthenticated,
            contextIsClosing: contextIsClosing,
            connectionState: state
        )
    }

    private func recordProbeResult(
        _ result: LocalNetworkCheckResult,
        on service: PeerDiscoveryService,
        peerID: UUID? = nil
    ) {
        let published = expectation(description: "Probe result published")
        service.recordLocalNetworkProbeResultForTesting(
            result,
            peerID: peerID
        ) {
            published.fulfill()
        }
        wait(for: [published], timeout: 1)
    }
}
