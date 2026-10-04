import Combine
import CryptoKit
import Foundation
import XCTest
@testable import MacKVM
@testable import MacKVMCore

final class PairingSecurityBoundaryTests: XCTestCase {
    private let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private final class FailureSwitch {
        private let lock = NSLock()
        private var value = false
        var fails: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private final class Fixture {
        let suiteName = "PairingSecurityBoundaryTests." + UUID().uuidString
        let defaults: UserDefaults
        let registry: PairingRegistry
        let service: PeerDiscoveryService
        let credentials: DeviceCredentials

        init(localID: UUID, failure: FailureSwitch? = nil) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            registry = PairingRegistry(
                testDefaults: defaults,
                storageKey: "peers",
                persistenceApplicationID: suiteName,
                shouldFailPersistence: { failure?.fails ?? false }
            )
            let key = P256.Signing.PrivateKey()
            credentials = DeviceCredentials(
                identity: PeerIdentity(
                    id: localID, name: "Local Mac",
                    signingPublicKey: key.publicKey.x963Representation
                ),
                privateKey: key, wasLoadedFromStorage: false
            )
            service = PeerDiscoveryService(credentials: credentials, registry: registry)
        }

        deinit { defaults.removePersistentDomain(forName: suiteName) }
    }

    func testSameUUIDWithDifferentSelectedKeyCannotCancelOutgoingPairing() throws {
        for (localID, targetID) in [(higherID, lowerID), (lowerID, higherID)] {
            let fixture = try Fixture(localID: localID)
            let target = makePeer(id: targetID)
            let attacker = makePeer(id: targetID)
            let requestID = UUID()
            fixture.service.prepareOutboundPairingForTesting(with: target.peer, requestID: requestID)

            let incoming = try signedRequest(from: attacker)
            let state = fixture.service.handleIncomingPairingRequestForTesting(incoming)

            assertOutgoingPreserved(fixture.service, requestID: requestID, target: target.peer,
                                    state: state, incomingRequestID: incoming.requestID)
        }
    }

    func testSameSelectedKeyWithDifferentPinnedKeyCannotCancelOutgoingPairing() throws {
        let fixture = try Fixture(localID: higherID)
        let target = makePeer(id: lowerID)
        fixture.registry.add(makePeer(id: lowerID).peer)
        let requestID = UUID()
        fixture.service.prepareOutboundPairingForTesting(with: target.peer, requestID: requestID)

        let incoming = try signedRequest(from: target)
        let state = fixture.service.handleIncomingPairingRequestForTesting(incoming)

        assertOutgoingPreserved(fixture.service, requestID: requestID, target: target.peer,
                                state: state, incomingRequestID: incoming.requestID)
    }

    func testMissingOrShortCommitmentCannotCancelOutgoingPairing() throws {
        for commitment in [nil, Data(), Data(repeating: 1, count: 31),
                           Data(repeating: 1, count: 33)] as [Data?] {
            let fixture = try Fixture(localID: higherID)
            let target = makePeer(id: lowerID)
            let requestID = UUID()
            fixture.service.prepareOutboundPairingForTesting(with: target.peer, requestID: requestID)
            let incoming = try signedRequest(from: target, commitment: commitment)

            let state = fixture.service.handleIncomingPairingRequestForTesting(incoming)

            assertOutgoingPreserved(fixture.service, requestID: requestID, target: target.peer,
                                    state: state, incomingRequestID: incoming.requestID)
        }
    }

    func testReusedOutboundRequestIDCannotReplaceOutgoingPairing() throws {
        let fixture = try Fixture(localID: higherID)
        let target = makePeer(id: lowerID)
        let requestID = UUID()
        fixture.service.prepareOutboundPairingForTesting(with: target.peer, requestID: requestID)
        let incoming = try signedRequest(from: target, requestID: requestID)

        let state = fixture.service.handleIncomingPairingRequestForTesting(incoming)

        assertOutgoingPreserved(fixture.service, requestID: requestID, target: target.peer,
                                state: state, incomingRequestID: nil)
        XCTAssertEqual(state.trackedRequestIDs, [requestID])
    }

    func testCapacityRejectionCannotCancelOutgoingPairing() throws {
        let fixture = try Fixture(localID: higherID)
        let target = makePeer(id: lowerID)
        let requestID = UUID()
        let pending = try pairedPendingRequests(count: 4, fixture: fixture)
        fixture.service.prepareOutboundPairingForTesting(
            with: target.peer, requestID: requestID, pendingRequests: pending
        )
        let incoming = try signedRequest(from: target)

        let state = fixture.service.handleIncomingPairingRequestForTesting(incoming)

        assertOutgoingPreserved(fixture.service, requestID: requestID, target: target.peer,
                                state: state, incomingRequestID: incoming.requestID)
        XCTAssertEqual(state.trackedRequestIDs.count, 5)
    }

    func testDuplicateSenderCannotCancelOutgoingPairing() throws {
        let fixture = try Fixture(localID: higherID)
        let target = makePeer(id: lowerID)
        let requestID = UUID()
        let priorIncoming = try signedRequest(from: target)
        fixture.service.prepareOutboundPairingForTesting(
            with: target.peer, requestID: requestID, pendingRequests: [priorIncoming]
        )
        let incoming = try signedRequest(from: target)

        let state = fixture.service.handleIncomingPairingRequestForTesting(incoming)

        assertOutgoingPreserved(fixture.service, requestID: requestID, target: target.peer,
                                state: state, incomingRequestID: incoming.requestID)
    }

    func testValidSimultaneousPairingKeepsLowerUUIDOutgoing() throws {
        let fixture = try Fixture(localID: lowerID)
        let target = makePeer(id: higherID)
        let requestID = UUID()
        fixture.service.prepareOutboundPairingForTesting(with: target.peer, requestID: requestID)
        let incoming = try signedRequest(from: target)

        let state = fixture.service.handleIncomingPairingRequestForTesting(incoming)
        drainMainQueue()

        XCTAssertEqual(state.outboundRequestID, requestID)
        XCTAssertEqual(state.trackedRequestIDs, [requestID])
        XCTAssertEqual(fixture.service.pendingPairingConfirmation?.id, requestID)
        XCTAssertEqual(fixture.service.activeVerificationCode, "123456")
    }

    func testNewUnpairedIncomingRequestStillEntersPairingNegotiation() throws {
        let fixture = try Fixture(localID: higherID)
        let target = makePeer(id: lowerID)
        let incoming = try signedRequest(from: target)

        let state = fixture.service.handleIncomingPairingRequestForTesting(incoming)

        XCTAssertNil(state.outboundRequestID)
        XCTAssertEqual(state.trackedRequestIDs, [incoming.requestID])
        XCTAssertFalse(fixture.registry.contains(target.peer.id))
    }

    func testValidSimultaneousPairingReplacesHigherUUIDOutgoingOnlyAfterLocalAcceptNearCapacity() throws {
        let fixture = try Fixture(localID: higherID)
        let target = makePeer(id: lowerID)
        let requestID = UUID()
        let pending = try pairedPendingRequests(count: 3, fixture: fixture)
        fixture.service.prepareOutboundPairingForTesting(
            with: target.peer, requestID: requestID, pendingRequests: pending
        )
        let transcript = try requestAndReveal(from: target)
        let incoming = transcript.request

        _ = fixture.service.handleIncomingPairingRequestForTesting(incoming)
        let provisional = fixture.service.handleIncomingPairingRequestForTesting(transcript.reveal)
        drainMainQueue()

        XCTAssertEqual(provisional.outboundRequestID, requestID)
        XCTAssertTrue(provisional.trackedRequestIDs.contains(requestID))
        XCTAssertTrue(provisional.trackedRequestIDs.contains(incoming.requestID))
        XCTAssertEqual(provisional.trackedRequestIDs.count, 5)
        XCTAssertEqual(fixture.service.pendingPairingConfirmation?.id, requestID)
        let pendingRequest = try XCTUnwrap(fixture.service.pendingRequests.first {
            $0.id == incoming.requestID
        })
        fixture.service.respond(to: pendingRequest, accepted: true)
        fixture.service.waitForQueuedWorkForTesting()
        let state = fixture.service.pairingRequestStateForTesting()
        drainMainQueue()

        XCTAssertNil(state.outboundRequestID)
        XCTAssertFalse(state.trackedRequestIDs.contains(requestID))
        XCTAssertTrue(state.trackedRequestIDs.contains(incoming.requestID))
        XCTAssertEqual(state.trackedRequestIDs.count, 4)
        XCTAssertNil(fixture.service.pendingPairingConfirmation)
        XCTAssertNil(fixture.service.activeVerificationCode)
    }

    func testCapturedSignedPairingTranscriptCannotCancelOutgoingWithoutLocalConsent() throws {
        let fixture = try Fixture(localID: higherID)
        let target = makePeer(id: lowerID)
        let outboundID = UUID()
        fixture.service.prepareOutboundPairingForTesting(with: target.peer, requestID: outboundID)
        let captured = try requestAndReveal(from: target)
        let request = captured.request
        let replayedMessages = [
            request, captured.reveal,
            try authenticated(.decision(to: request, from: target.peer, accepted: true), with: target.key),
            try authenticated(.completion(to: request, from: target.peer), with: target.key),
            try authenticated(.completionAcknowledgement(to: request, from: target.peer), with: target.key),
            try authenticated(.completionClose(to: request, from: target.peer), with: target.key),
            try authenticated(.completionCloseAcknowledgement(to: request, from: target.peer), with: target.key)
        ]

        var capturedWire = Data()
        for replayed in replayedMessages {
            capturedWire.append(try PairingWireCodec.encode(replayed, signingWith: target.key))
        }
        // Replay the captured bytes through the production frame decoder and
        // handler on ONE tracked incoming connection, including coalesced
        // packets after the premature completion retires that connection.
        let state = fixture.service.handleIncomingPairingFramesForTesting(capturedWire)
        assertOutgoingPreserved(fixture.service, requestID: outboundID, target: target.peer,
                                state: state, incomingRequestID: nil)
        XCTAssertFalse(fixture.registry.contains(target.peer.id))
    }

    func testOnlyOneProvisionalCollisionCanOccupyReservedReplacementSlot() throws {
        let fixture = try Fixture(localID: higherID)
        let target = makePeer(id: lowerID)
        let outboundID = UUID()
        fixture.service.prepareOutboundPairingForTesting(with: target.peer, requestID: outboundID)
        let first = try requestAndReveal(from: target)
        let second = try requestAndReveal(from: target)
        _ = fixture.service.handleIncomingPairingRequestForTesting(first.request)

        let state = fixture.service.handleIncomingPairingRequestForTesting(second.request)

        XCTAssertEqual(state.outboundRequestID, outboundID)
        XCTAssertEqual(state.trackedRequestIDs, [outboundID, first.request.requestID])
        XCTAssertFalse(state.trackedRequestIDs.contains(second.request.requestID))
    }

    func testProvisionalGlobalCapacityReservationCannotGrowByAnotherCandidateOrOrdinaryRequest() throws {
        let fixture = try Fixture(localID: higherID)
        let target = makePeer(id: lowerID)
        fixture.registry.add(target.peer)
        let outboundID = UUID()
        let pending = try pairedPendingRequests(count: 4, fixture: fixture)
        fixture.service.prepareOutboundPairingForTesting(
            with: target.peer, requestID: outboundID, pendingRequests: pending
        )
        let first = try requestAndReveal(from: target)
        let reserved = fixture.service.handleIncomingPairingRequestForTesting(first.request)
        XCTAssertEqual(reserved.trackedRequestIDs.count, 6)
        let second = try requestAndReveal(from: target)
        let unrelated = makePeer()
        fixture.registry.add(unrelated.peer)
        _ = fixture.service.handleIncomingPairingRequestForTesting(second.request)

        let state = fixture.service.handleIncomingPairingRequestForTesting(
            try signedRequest(from: unrelated)
        )

        XCTAssertEqual(state.outboundRequestID, outboundID)
        XCTAssertEqual(state.trackedRequestIDs, reserved.trackedRequestIDs)
        XCTAssertEqual(state.trackedRequestIDs.count, 6)
    }

    func testOutgoingEOFPreservesProvisionalIncomingForLocalAcceptance() throws {
        let fixture = try Fixture(localID: higherID)
        let target = makePeer(id: lowerID)
        let outboundID = UUID()
        fixture.service.prepareOutboundPairingForTesting(with: target.peer, requestID: outboundID)
        let incoming = try requestAndReveal(from: target)
        _ = fixture.service.handleIncomingPairingRequestForTesting(incoming.request)
        _ = fixture.service.handleIncomingPairingRequestForTesting(incoming.reveal)
        fixture.service.finishPairingTransportForTesting(requestID: outboundID)
        drainMainQueue()

        let pending = try XCTUnwrap(fixture.service.pendingRequests.first {
            $0.id == incoming.request.requestID
        })
        XCTAssertTrue(fixture.service.pairingRequestStateForTesting().trackedRequestIDs.contains(pending.id))
        fixture.service.respond(to: pending, accepted: true)
        fixture.service.waitForQueuedWorkForTesting()
        drainMainQueue()

        let state = fixture.service.pairingRequestStateForTesting()
        XCTAssertNil(state.outboundRequestID)
        XCTAssertEqual(state.trackedRequestIDs, [pending.id])
        XCTAssertTrue(fixture.service.pendingRequests.isEmpty)
    }

    func testProvisionalDeclineTimeoutAndRemoteDeclineDoNotCancelOutgoing() throws {
        for outcome in ["local-decline", "timeout", "remote-decline"] {
            let fixture = try Fixture(localID: higherID)
            let target = makePeer(id: lowerID)
            let outboundID = UUID()
            fixture.service.prepareOutboundPairingForTesting(with: target.peer, requestID: outboundID)
            let incoming = try requestAndReveal(from: target)
            _ = fixture.service.handleIncomingPairingRequestForTesting(incoming.request)
            _ = fixture.service.handleIncomingPairingRequestForTesting(incoming.reveal)
            drainMainQueue()
            let pending = try XCTUnwrap(fixture.service.pendingRequests.first)

            if outcome == "local-decline" {
                fixture.service.respond(to: pending, accepted: false)
                fixture.service.waitForQueuedWorkForTesting()
                // Sending over an unstarted test transport has no delivery
                // callback; retire it as the real decline callback would.
                fixture.service.expirePairingRequestForTesting(requestID: pending.id)
            } else if outcome == "timeout" {
                fixture.service.expirePairingRequestForTesting(requestID: pending.id)
            } else {
                let decline = try authenticated(
                    .decision(to: incoming.request, from: target.peer, accepted: false),
                    with: target.key
                )
                _ = fixture.service.handleIncomingPairingRequestForTesting(decline)
            }

            let state = fixture.service.pairingRequestStateForTesting()
            assertOutgoingPreserved(fixture.service, requestID: outboundID, target: target.peer,
                                    state: state, incomingRequestID: pending.id)
            XCTAssertTrue(fixture.service.pendingRequests.isEmpty)
        }
    }

    func testStaleProvisionalAcceptCannotCancelNewOutgoingRequest() throws {
        let fixture = try Fixture(localID: higherID)
        let target = makePeer(id: lowerID)
        let oldOutboundID = UUID()
        fixture.service.prepareOutboundPairingForTesting(with: target.peer, requestID: oldOutboundID)
        let incoming = try requestAndReveal(from: target)
        _ = fixture.service.handleIncomingPairingRequestForTesting(incoming.request)
        _ = fixture.service.handleIncomingPairingRequestForTesting(incoming.reveal)
        fixture.service.finishPairingTransportForTesting(requestID: oldOutboundID)
        drainMainQueue()
        let oldPending = try XCTUnwrap(fixture.service.pendingRequests.first)
        let newOutboundID = UUID()
        fixture.service.prepareOutboundPairingForTesting(with: target.peer, requestID: newOutboundID)

        fixture.service.respond(to: oldPending, accepted: true)
        fixture.service.waitForQueuedWorkForTesting()
        drainMainQueue()

        let state = fixture.service.pairingRequestStateForTesting()
        XCTAssertEqual(state.outboundRequestID, newOutboundID)
        XCTAssertTrue(state.trackedRequestIDs.contains(newOutboundID))
        XCTAssertEqual(fixture.service.pendingPairingConfirmation?.id, newOutboundID)
        XCTAssertEqual(fixture.service.activeVerificationCode, "123456")
    }

    func testExplicitOutgoingCancelAlsoRemovesLinkedProvisionalRequest() throws {
        let fixture = try Fixture(localID: higherID)
        let target = makePeer(id: lowerID)
        let outboundID = UUID()
        fixture.service.prepareOutboundPairingForTesting(with: target.peer, requestID: outboundID)
        let incoming = try requestAndReveal(from: target)
        _ = fixture.service.handleIncomingPairingRequestForTesting(incoming.request)
        _ = fixture.service.handleIncomingPairingRequestForTesting(incoming.reveal)

        fixture.service.cancelPairing()
        fixture.service.waitForQueuedWorkForTesting()
        drainMainQueue()

        let state = fixture.service.pairingRequestStateForTesting()
        XCTAssertNil(state.outboundRequestID)
        XCTAssertTrue(state.trackedRequestIDs.isEmpty)
        XCTAssertTrue(fixture.service.pendingRequests.isEmpty)
    }

    func testFailedForgetKeepsRetryAvailableForMissingPeerAndRetryIsDurable() throws {
        let failure = FailureSwitch()
        let fixture = try Fixture(localID: higherID, failure: failure)
        let target = makePeer(id: lowerID).peer
        fixture.registry.add(target)
        let oldData = fixture.defaults.data(forKey: "peers")
        let oldGeneration = fixture.registry.generation(for: target.id)
        failure.fails = true

        XCTAssertFalse(fixture.service.forget(target.id))
        fixture.service.waitForQueuedWorkForTesting()
        drainMainQueue()

        XCTAssertFalse(fixture.registry.contains(target.id))
        XCTAssertNil(fixture.registry.profile(for: target.id))
        XCTAssertEqual(fixture.registry.generation(for: target.id), oldGeneration + 1)
        XCTAssertFalse(fixture.registry.add(target, ifGeneration: oldGeneration))
        XCTAssertEqual(fixture.defaults.data(forKey: "peers"), oldData)
        XCTAssertTrue(fixture.service.peers.isEmpty)
        XCTAssertFalse(fixture.service.pairedPeerIDs.contains(target.id))
        XCTAssertTrue(fixture.service.failedForgetPeerIDs.contains(target.id))
        XCTAssertNotEqual(fixture.service.status, "Pairing forgotten")
        let secureSession = SecureSessionService(
            credentials: fixture.credentials, registry: fixture.registry,
            networkServicesEnabled: false
        )
        secureSession.revoke(target.id, trustAlreadyRevoked: true)
        XCTAssertEqual(fixture.registry.generation(for: target.id), oldGeneration + 1)

        failure.fails = false
        XCTAssertTrue(fixture.service.forget(target.id))
        fixture.service.waitForQueuedWorkForTesting()
        drainMainQueue()

        XCTAssertTrue(fixture.service.failedForgetPeerIDs.isEmpty)
        XCTAssertEqual(fixture.service.status, "Pairing forgotten")
        let reloaded = PairingRegistry(
            testDefaults: fixture.defaults, storageKey: "peers",
            persistenceApplicationID: fixture.suiteName
        )
        XCTAssertFalse(reloaded.contains(target.id))
        XCTAssertNil(reloaded.profile(for: target.id))
    }

    func testStandaloneSecureRevokeDoesNotReportDurableSuccessOnFailure() throws {
        let failure = FailureSwitch()
        let fixture = try Fixture(localID: higherID, failure: failure)
        let target = makePeer(id: lowerID).peer
        fixture.registry.add(target)
        failure.fails = true
        let secureSession = SecureSessionService(
            credentials: fixture.credentials, registry: fixture.registry,
            networkServicesEnabled: false
        )
        let failurePublished = expectation(description: "Secure revoke failure")
        let subscription = secureSession.$status.dropFirst().sink { status in
            if status.contains("storage removal failed") { failurePublished.fulfill() }
        }

        secureSession.revoke(target.id)
        wait(for: [failurePublished], timeout: 2)

        XCTAssertFalse(fixture.registry.contains(target.id))
        XCTAssertEqual(fixture.registry.generation(for: target.id), 1)
        subscription.cancel()
    }

    func testCancelledPairingRollbackFailureRemainsRevokedAndOffersRetry() throws {
        for deferredRetryFailure in [false, true] {
            let failure = FailureSwitch()
            let fixture = try Fixture(localID: higherID, failure: failure)
            let target = makePeer(id: lowerID).peer
            fixture.registry.add(target)
            let oldData = fixture.defaults.data(forKey: "peers")
            failure.fails = true

            fixture.service.rollbackCancelledPairingPersistenceForTesting(
                peer: target, deferredRetryFailure: deferredRetryFailure
            )
            drainMainQueue()

            XCTAssertFalse(fixture.registry.contains(target.id))
            XCTAssertEqual(fixture.registry.generation(for: target.id), 1)
            XCTAssertEqual(fixture.defaults.data(forKey: "peers"), oldData)
            XCTAssertTrue(fixture.service.failedForgetPeerIDs.contains(target.id))
            XCTAssertNotEqual(fixture.service.status, "Pairing forgotten")
            XCTAssertFalse(fixture.registry.add(target, ifGeneration: 0))
        }
    }

    func testFailedForgetRacingCancelledRollbackKeepsLatestGenerationRetryNotice() throws {
        for deferredRetryFailure in [false, true] {
            let failure = FailureSwitch()
            let fixture = try Fixture(localID: higherID, failure: failure)
            let target = makePeer(id: lowerID).peer
            fixture.registry.add(target)
            let oldData = fixture.defaults.data(forKey: "peers")
            failure.fails = true

            fixture.service.rollbackCancelledPairingPersistenceForTesting(
                peer: target, deferredRetryFailure: deferredRetryFailure,
                forgetBeforeRollback: true
            )
            fixture.service.waitForQueuedWorkForTesting()
            drainMainQueue()

            XCTAssertEqual(fixture.registry.generation(for: target.id), 1)
            XCTAssertFalse(fixture.registry.contains(target.id))
            XCTAssertEqual(fixture.defaults.data(forKey: "peers"), oldData)
            XCTAssertTrue(fixture.service.failedForgetPeerIDs.contains(target.id))
            XCTAssertNotEqual(fixture.service.status, "Pairing forgotten")
        }
    }

    private func assertOutgoingPreserved(
        _ service: PeerDiscoveryService, requestID: UUID, target: PeerIdentity,
        state: (outboundRequestID: UUID?, trackedRequestIDs: Set<UUID>),
        incomingRequestID: UUID?, file: StaticString = #filePath, line: UInt = #line
    ) {
        drainMainQueue()
        XCTAssertEqual(state.outboundRequestID, requestID, file: file, line: line)
        XCTAssertTrue(state.trackedRequestIDs.contains(requestID), file: file, line: line)
        if let incomingRequestID {
            XCTAssertFalse(state.trackedRequestIDs.contains(incomingRequestID), file: file, line: line)
        }
        XCTAssertEqual(service.pendingPairingConfirmation?.id, requestID, file: file, line: line)
        XCTAssertEqual(service.activeVerificationCode, "123456", file: file, line: line)
        XCTAssertEqual(service.pairingActivity,
                       .awaitingConfirmation(peerID: target.id, peerName: target.name),
                       file: file, line: line)
        XCTAssertEqual(service.status, "Waiting for code confirmation", file: file, line: line)
    }

    private func pairedPendingRequests(count: Int, fixture: Fixture) throws -> [PairingEnvelope] {
        try (0..<count).map { _ in
            let peer = makePeer()
            fixture.registry.add(peer.peer)
            return try signedRequest(from: peer)
        }
    }

    private func makePeer(id: UUID = UUID()) -> (peer: PeerIdentity, key: P256.Signing.PrivateKey) {
        let key = P256.Signing.PrivateKey()
        return (PeerIdentity(id: id, name: "Target Mac",
                             signingPublicKey: key.publicKey.x963Representation), key)
    }

    private func signedRequest(
        from peer: (peer: PeerIdentity, key: P256.Signing.PrivateKey),
        requestID: UUID = UUID(),
        commitment: Data? = Data(repeating: 1, count: SHA256.Digest.byteCount)
    ) throws -> PairingEnvelope {
        let request = PairingEnvelope(kind: .request, requestID: requestID,
                                      sender: peer.peer, verificationCommitment: commitment)
        return try authenticated(request, with: peer.key)
    }

    private func requestAndReveal(
        from peer: (peer: PeerIdentity, key: P256.Signing.PrivateKey)
    ) throws -> (request: PairingEnvelope, reveal: PairingEnvelope) {
        let requestID = UUID()
        let contribution = PairingVerificationCode.makeContribution()
        let request = PairingEnvelope.request(
            from: peer.peer, requestID: requestID,
            commitment: PairingVerificationCode.commitment(
                requestID: requestID, publicKey: peer.peer.signingPublicKey,
                contribution: contribution
            )
        )
        return (
            try authenticated(request, with: peer.key),
            try authenticated(.reveal(to: request, from: peer.peer, contribution: contribution),
                              with: peer.key)
        )
    }

    private func authenticated(
        _ message: PairingEnvelope, with key: P256.Signing.PrivateKey
    ) throws -> PairingEnvelope {
        var bytes = try PairingWireCodec.encode(message, signingWith: key)
        return try XCTUnwrap(PairingWireCodec.decodeAvailableFrames(from: &bytes).first)
    }

    private func drainMainQueue() {
        let drained = expectation(description: "Published pairing state")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }
}
