import CryptoKit
import Foundation
import XCTest
@testable import MacKVMCore

final class SecureSessionProtocolTests: XCTestCase {
    func testSignedHandshakeRoundTrip() throws {
        let fixture = makeFixture()
        var buffer = try SecureSessionWireCodec.encode(
            handshake: fixture.initiatorHandshake,
            signingWith: fixture.initiatorSigningKey
        )

        XCTAssertEqual(
            try SecureSessionWireCodec.decodeAvailableFrames(from: &buffer),
            [.handshake(fixture.initiatorHandshake)]
        )
        XCTAssertTrue(buffer.isEmpty)
    }

    func testHandshakeRejectsWrongSigningKey() throws {
        let fixture = makeFixture()
        var buffer = try SecureSessionWireCodec.encode(
            handshake: fixture.initiatorHandshake,
            signingWith: P256.Signing.PrivateKey()
        )

        XCTAssertThrowsError(
            try SecureSessionWireCodec.decodeAvailableFrames(from: &buffer)
        ) { error in
            XCTAssertEqual(error as? SecureSessionError, .invalidSignature)
        }
    }

    func testChannelsEncryptBothDirectionsAndRejectReplay() throws {
        let fixture = makeFixture()
        let initiator = try SecureSessionChannel(
            localRole: .initiator,
            localEphemeralKey: fixture.initiatorEphemeralKey,
            initiator: fixture.initiatorHandshake,
            responder: fixture.responderHandshake
        )
        let responder = try SecureSessionChannel(
            localRole: .responder,
            localEphemeralKey: fixture.responderEphemeralKey,
            initiator: fixture.initiatorHandshake,
            responder: fixture.responderHandshake
        )

        let firstPacket = try initiator.seal(Data("keyboard".utf8))
        XCTAssertNotEqual(firstPacket.sealedData, Data("keyboard".utf8))
        XCTAssertEqual(
            try responder.open(firstPacket),
            Data("keyboard".utf8)
        )
        XCTAssertThrowsError(try responder.open(firstPacket)) { error in
            XCTAssertEqual(
                error as? SecureSessionError,
                .unexpectedSequence
            )
        }

        let reply = try responder.seal(Data("ack".utf8))
        XCTAssertEqual(try initiator.open(reply), Data("ack".utf8))
    }

    func testPacketWireCodecWaitsForCompleteFrame() throws {
        let packet = SecurePacket(
            sessionID: UUID(),
            sequence: 4,
            sealedData: Data(repeating: 7, count: 48)
        )
        let encoded = try SecureSessionWireCodec.encode(packet: packet)
        let midpoint = encoded.count / 2
        var buffer = Data(encoded[..<midpoint])

        XCTAssertEqual(
            try SecureSessionWireCodec.decodeAvailableFrames(from: &buffer),
            []
        )
        buffer.append(encoded[midpoint...])
        XCTAssertEqual(
            try SecureSessionWireCodec.decodeAvailableFrames(from: &buffer),
            [.packet(packet)]
        )
    }

    func testSimultaneousConnectionPolicyChoosesOppositeRoles() {
        let firstID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let secondID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!

        XCTAssertEqual(
            SecureSessionCollisionPolicy.preferredRole(
                localID: firstID,
                remoteID: secondID
            ),
            .initiator
        )
        XCTAssertEqual(
            SecureSessionCollisionPolicy.preferredRole(
                localID: secondID,
                remoteID: firstID
            ),
            .responder
        )
    }

    private func makeFixture() -> Fixture {
        let sessionID = UUID()
        let initiatorSigningKey = P256.Signing.PrivateKey()
        let responderSigningKey = P256.Signing.PrivateKey()
        let initiatorEphemeralKey = P256.KeyAgreement.PrivateKey()
        let responderEphemeralKey = P256.KeyAgreement.PrivateKey()
        let initiator = PeerIdentity(
            name: "Initiator",
            signingPublicKey: initiatorSigningKey.publicKey.x963Representation
        )
        let responder = PeerIdentity(
            name: "Responder",
            signingPublicKey: responderSigningKey.publicKey.x963Representation
        )
        return Fixture(
            initiatorSigningKey: initiatorSigningKey,
            initiatorEphemeralKey: initiatorEphemeralKey,
            responderEphemeralKey: responderEphemeralKey,
            initiatorHandshake: .make(
                sessionID: sessionID,
                role: .initiator,
                sender: initiator,
                ephemeralKey: initiatorEphemeralKey
            ),
            responderHandshake: .make(
                sessionID: sessionID,
                role: .responder,
                sender: responder,
                ephemeralKey: responderEphemeralKey
            )
        )
    }
}

private struct Fixture {
    let initiatorSigningKey: P256.Signing.PrivateKey
    let initiatorEphemeralKey: P256.KeyAgreement.PrivateKey
    let responderEphemeralKey: P256.KeyAgreement.PrivateKey
    let initiatorHandshake: SecureSessionHandshake
    let responderHandshake: SecureSessionHandshake
}
