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
}
