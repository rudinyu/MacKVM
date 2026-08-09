import CryptoKit
import Foundation
import XCTest
@testable import MacKVMCore

final class PairingRequestPolicyTests: XCTestCase {
    func testAllowsNewRequestBelowCapacity() {
        let request = makeRequest()

        XCTAssertEqual(
            evaluate(request),
            .allow
        )
    }

    func testAcceptsUnpairedDiscoveredPeer() {
        let request = makeRequest()

        XCTAssertTrue(
            PairingRequestPolicy.acceptsDiscoveredPeer(
                request.sender,
                pinnedPublicKey: nil
            )
        )
    }

    func testRejectsDiscoveredPeerWithChangedPinnedKey() {
        let request = makeRequest()
        let differentKey = P256.Signing.PrivateKey()
            .publicKey.x963Representation

        XCTAssertFalse(
            PairingRequestPolicy.acceptsDiscoveredPeer(
                request.sender,
                pinnedPublicKey: differentKey
            )
        )
    }

    func testRejectsChangedPinnedKey() {
        let request = makeRequest()
        let differentKey = P256.Signing.PrivateKey()
            .publicKey.x963Representation

        XCTAssertEqual(
            evaluate(request, pinnedPublicKey: differentKey),
            .rejectChangedKey
        )
    }

    func testRejectsDuplicateRequestIdentifier() {
        let request = makeRequest()

        XCTAssertEqual(
            evaluate(
                request,
                activeRequestIDs: [request.requestID]
            ),
            .rejectDuplicateRequest
        )
    }

    func testRejectsSecondRequestFromSameSender() {
        let request = makeRequest()

        XCTAssertEqual(
            evaluate(
                request,
                pendingSenderIDs: [request.sender.id]
            ),
            .rejectDuplicateSender
        )
    }

    func testRejectsRequestAtCapacity() {
        let request = makeRequest()

        XCTAssertEqual(
            evaluate(
                request,
                activeRequestCount: 5
            ),
            .rejectAtCapacity
        )
    }

    func testRejectsSecondUnpairedRequestBeforeGlobalCapacity() {
        let request = makeRequest()

        XCTAssertEqual(
            evaluate(
                request,
                activeRequestCount: 1,
                activeUnpairedRequestCount: 1
            ),
            .rejectAtCapacity
        )
    }

    func testPairedRequestCanUseCapacityReservedFromUnpairedPool() {
        let request = makeRequest()
        let pinnedKey = request.sender.signingPublicKey

        XCTAssertEqual(
            evaluate(
                request,
                pinnedPublicKey: pinnedKey,
                activeRequestCount: 4,
                activeUnpairedRequestCount: 1
            ),
            .allow
        )
    }

    func testUnpairedRequestCannotConsumeTheLastGlobalSlot() {
        let request = makeRequest()

        XCTAssertEqual(
            evaluate(
                request,
                activeRequestCount: 4
            ),
            .rejectAtCapacity
        )
    }

    func testSimultaneousPairingKeepsOnlyLowerUUIDOutbound() {
        let lower = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let higher = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!

        XCTAssertTrue(
            PairingRequestPolicy.keepOutboundDuringCollision(
                localID: lower,
                remoteID: higher
            )
        )
        XCTAssertFalse(
            PairingRequestPolicy.keepOutboundDuringCollision(
                localID: higher,
                remoteID: lower
            )
        )
    }

    private func evaluate(
        _ request: PairingEnvelope,
        pinnedPublicKey: Data? = nil,
        activeRequestIDs: Set<UUID> = [],
        pendingSenderIDs: Set<UUID> = [],
        activeRequestCount: Int = 0,
        activeUnpairedRequestCount: Int = 0
    ) -> PairingRequestDecision {
        PairingRequestPolicy.evaluate(
            request: request,
            pinnedPublicKey: pinnedPublicKey,
            activeRequestIDs: activeRequestIDs,
            pendingSenderIDs: pendingSenderIDs,
            activeRequestCount: activeRequestCount,
            maximumPendingRequests: 5,
            activeUnpairedRequestCount: activeUnpairedRequestCount,
            maximumUnpairedPendingRequests: 1
        )
    }

    private func makeRequest() -> PairingEnvelope {
        let privateKey = P256.Signing.PrivateKey()
        let identity = PeerIdentity(
            name: "Desk Mac",
            signingPublicKey: privateKey.publicKey.x963Representation
        )
        let requestID = UUID()
        let contribution = PairingVerificationCode.makeContribution()
        return PairingEnvelope.request(
            from: identity,
            requestID: requestID,
            commitment: PairingVerificationCode.commitment(
                requestID: requestID,
                publicKey: identity.signingPublicKey,
                contribution: contribution
            )
        )
    }
}
