import CryptoKit
import Foundation
import XCTest
@testable import MacKVMCore

final class PairingProtocolTests: XCTestCase {
    func testWireCodecRoundTripsRequest() throws {
        let privateKey = P256.Signing.PrivateKey()
        let sender = PeerIdentity(
            id: UUID(uuidString: "CE3F1438-EE16-4057-96B7-7655F846A012")!,
            name: "Desk Mac",
            signingPublicKey: privateKey.publicKey.x963Representation
        )
        let requestID = UUID(
            uuidString: "D600677B-F21B-453F-A12D-63EBB6E2DAB5"
        )!
        let contribution = PairingVerificationCode.makeContribution()
        let request = PairingEnvelope.request(
            from: sender,
            requestID: requestID,
            commitment: PairingVerificationCode.commitment(
                requestID: requestID,
                publicKey: sender.signingPublicKey,
                contribution: contribution
            )
        )

        let encoded = try PairingWireCodec.encode(
            request,
            signingWith: privateKey
        )
        var buffer = encoded
        let decoded = try PairingWireCodec.decodeAvailableFrames(
            from: &buffer
        )

        XCTAssertEqual(decoded, [request])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testResponseRetainsRequestIdentifier() {
        let firstMac = makeIdentity(name: "First Mac")
        let secondMac = makeIdentity(name: "Second Mac")
        let request = makeRequest(from: firstMac)

        let response = PairingEnvelope.decision(
            to: request,
            from: secondMac,
            accepted: true
        )

        XCTAssertEqual(response.kind, .decision)
        XCTAssertEqual(response.requestID, request.requestID)
        XCTAssertEqual(response.sender, secondMac)
        XCTAssertEqual(response.accepted, true)
    }

    func testCompletionRetainsRequestAndSenderIdentity() {
        let firstMac = makeIdentity(name: "First Mac")
        let secondMac = makeIdentity(name: "Second Mac")
        let request = makeRequest(from: firstMac)

        let completion = PairingEnvelope.completion(
            to: request,
            from: secondMac
        )

        XCTAssertEqual(completion.kind, .completion)
        XCTAssertEqual(completion.requestID, request.requestID)
        XCTAssertEqual(completion.sender, secondMac)
        XCTAssertNil(completion.accepted)
    }

    func testCompletionAcknowledgementRetainsRequestAndSenderIdentity() {
        let firstMac = makeIdentity(name: "First Mac")
        let secondMac = makeIdentity(name: "Second Mac")
        let request = makeRequest(from: firstMac)

        let acknowledgement = PairingEnvelope.completionAcknowledgement(
            to: request,
            from: secondMac
        )

        XCTAssertEqual(acknowledgement.kind, .completionAcknowledgement)
        XCTAssertEqual(acknowledgement.requestID, request.requestID)
        XCTAssertEqual(acknowledgement.sender, secondMac)
        XCTAssertNil(acknowledgement.accepted)
    }

    func testWireCodecWaitsForACompleteFrame() throws {
        let privateKey = P256.Signing.PrivateKey()
        let request = makeRequest(
            from: PeerIdentity(
                name: "Desk Mac",
                signingPublicKey: privateKey.publicKey.x963Representation
            )
        )
        let encoded = try PairingWireCodec.encode(
            request,
            signingWith: privateKey
        )
        let splitIndex = encoded.count / 2
        var buffer = Data(encoded[..<splitIndex])

        XCTAssertEqual(
            try PairingWireCodec.decodeAvailableFrames(from: &buffer),
            []
        )

        buffer.append(encoded[splitIndex...])
        XCTAssertEqual(
            try PairingWireCodec.decodeAvailableFrames(from: &buffer),
            [request]
        )
        XCTAssertTrue(buffer.isEmpty)
    }

    func testWireCodecDecodesMultipleFrames() throws {
        let firstKey = P256.Signing.PrivateKey()
        let secondKey = P256.Signing.PrivateKey()
        let first = makeRequest(
            from: PeerIdentity(
                name: "First Mac",
                signingPublicKey: firstKey.publicKey.x963Representation
            )
        )
        let second = makeRequest(
            from: PeerIdentity(
                name: "Second Mac",
                signingPublicKey: secondKey.publicKey.x963Representation
            )
        )
        var buffer = try PairingWireCodec.encode(
            first,
            signingWith: firstKey
        )
        buffer.append(
            try PairingWireCodec.encode(second, signingWith: secondKey)
        )

        XCTAssertEqual(
            try PairingWireCodec.decodeAvailableFrames(from: &buffer),
            [first, second]
        )
        XCTAssertTrue(buffer.isEmpty)
    }

    func testWireCodecBatchesCoalescedFramesWithoutDroppingTheRemainder() throws {
        let key = P256.Signing.PrivateKey()
        let request = makeRequest(
            from: PeerIdentity(
                name: "Desk Mac",
                signingPublicKey: key.publicKey.x963Representation
            )
        )
        var buffer = Data()
        for _ in 0..<PairingWireCodec.maximumFramesPerDecode + 1 {
            buffer.append(try PairingWireCodec.encode(request, signingWith: key))
        }

        XCTAssertEqual(
            try PairingWireCodec.decodeAvailableFrames(from: &buffer).count,
            PairingWireCodec.maximumFramesPerDecode
        )
        XCTAssertEqual(
            try PairingWireCodec.decodeAvailableFrames(from: &buffer),
            [request]
        )
        XCTAssertTrue(buffer.isEmpty)
    }

    func testWireCodecRejectsMessageSignedByAnotherKey() throws {
        let claimedKey = P256.Signing.PrivateKey()
        let attackerKey = P256.Signing.PrivateKey()
        let request = makeRequest(
            from: PeerIdentity(
                name: "Desk Mac",
                signingPublicKey: claimedKey.publicKey.x963Representation
            )
        )
        var buffer = try PairingWireCodec.encode(
            request,
            signingWith: attackerKey
        )

        XCTAssertThrowsError(
            try PairingWireCodec.decodeAvailableFrames(from: &buffer)
        ) { error in
            XCTAssertEqual(error as? PairingWireError, .invalidSignature)
        }
    }

    func testWireCodecRejectsUnsafeSenderName() throws {
        let privateKey = P256.Signing.PrivateKey()
        let request = makeRequest(
            from: PeerIdentity(
                name: "Desk\nMac",
                signingPublicKey: privateKey.publicKey.x963Representation
            )
        )
        var buffer = try PairingWireCodec.encode(
            request,
            signingWith: privateKey
        )

        XCTAssertThrowsError(
            try PairingWireCodec.decodeAvailableFrames(from: &buffer)
        ) { error in
            XCTAssertEqual(error as? PairingWireError, .invalidIdentityName)
        }
    }

    func testVerificationCommitmentValidatesContribution() {
        let publicKey = P256.Signing.PrivateKey()
            .publicKey.x963Representation
        let requestID = UUID()
        let contribution = PairingVerificationCode.makeContribution()
        let commitment = PairingVerificationCode.commitment(
            requestID: requestID,
            publicKey: publicKey,
            contribution: contribution
        )

        XCTAssertTrue(
            PairingVerificationCode.verifies(
                commitment: commitment,
                requestID: requestID,
                publicKey: publicKey,
                contribution: contribution
            )
        )
        XCTAssertFalse(
            PairingVerificationCode.verifies(
                commitment: commitment,
                requestID: requestID,
                publicKey: publicKey,
                contribution: PairingVerificationCode.makeContribution()
            )
        )
    }

    func testVerificationCodeRequiresBothContributionsInRoleOrder() {
        let firstKey = P256.Signing.PrivateKey()
            .publicKey.x963Representation
        let secondKey = P256.Signing.PrivateKey()
            .publicKey.x963Representation
        let requestID = UUID()
        let firstContribution = PairingVerificationCode.makeContribution()
        let secondContribution = PairingVerificationCode.makeContribution()

        let firstCode = PairingVerificationCode.make(
            requestID: requestID,
            initiatorPublicKey: firstKey,
            responderPublicKey: secondKey,
            initiatorContribution: firstContribution,
            responderContribution: secondContribution
        )
        let secondCode = PairingVerificationCode.make(
            requestID: requestID,
            initiatorPublicKey: firstKey,
            responderPublicKey: secondKey,
            initiatorContribution: firstContribution,
            responderContribution: PairingVerificationCode.makeContribution()
        )

        XCTAssertNotEqual(firstCode, secondCode)
        XCTAssertEqual(firstCode.count, 6)
    }

    private func makeRequest(from identity: PeerIdentity) -> PairingEnvelope {
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

    private func makeIdentity(name: String) -> PeerIdentity {
        let key = P256.Signing.PrivateKey()
        return PeerIdentity(
            name: name,
            signingPublicKey: key.publicKey.x963Representation
        )
    }
}
