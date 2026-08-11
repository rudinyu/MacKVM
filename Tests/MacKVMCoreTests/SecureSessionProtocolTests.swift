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
        XCTAssertEqual(
            fixture.initiatorHandshake.senderModel,
            "MacBookPro18,3"
        )
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

    func testHandshakeRejectsUnsafeSenderName() throws {
        let fixture = makeFixture()
        let unsafeHandshake = SecureSessionHandshake(
            sessionID: fixture.initiatorHandshake.sessionID,
            role: .initiator,
            sender: PeerIdentity(
                id: fixture.initiatorHandshake.sender.id,
                name: "Initiator\nInjected",
                signingPublicKey: fixture.initiatorHandshake.sender.signingPublicKey
            ),
            ephemeralPublicKey: fixture.initiatorHandshake.ephemeralPublicKey,
            nonce: fixture.initiatorHandshake.nonce
        )
        var buffer = try SecureSessionWireCodec.encode(
            handshake: unsafeHandshake,
            signingWith: fixture.initiatorSigningKey
        )

        XCTAssertThrowsError(
            try SecureSessionWireCodec.decodeAvailableFrames(from: &buffer)
        ) { error in
            XCTAssertEqual(error as? SecureSessionError, .invalidIdentityName)
        }
    }

    func testChannelRejectsOversizedPlaintext() throws {
        let fixture = makeFixture()
        let channel = try SecureSessionChannel(
            localRole: .initiator,
            localEphemeralKey: fixture.initiatorEphemeralKey,
            initiator: fixture.initiatorHandshake,
            responder: fixture.responderHandshake
        )

        XCTAssertThrowsError(
            try channel.seal(
                Data(repeating: 1, count: SecureSessionChannel.maximumPlaintextLength + 1)
            )
        ) { error in
            XCTAssertEqual(error as? SecureSessionError, .invalidFrame)
        }
    }

    func testChannelRejectsOversizedSealedPacketWithDistinctError() throws {
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
        let packet = try initiator.seal(Data("bounded".utf8))
        let oversized = SecurePacket(
            sessionID: packet.sessionID,
            sequence: packet.sequence,
            sealedData: Data(
                repeating: 0,
                count: SecureSessionChannel.maximumSealedDataLength + 1
            )
        )

        XCTAssertThrowsError(try responder.open(oversized)) { error in
            XCTAssertEqual(error as? SecureSessionError, .oversizedPacket)
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

    func testPacketWireCodecBatchesCoalescedFramesWithoutDisconnecting() throws {
        let packet = SecurePacket(
            sessionID: UUID(),
            sequence: 4,
            sealedData: Data(repeating: 7, count: 48)
        )
        var buffer = Data()
        for _ in 0..<SecureSessionWireCodec.maximumFramesPerDecode + 1 {
            buffer.append(try SecureSessionWireCodec.encode(packet: packet))
        }

        XCTAssertEqual(
            try SecureSessionWireCodec.decodeAvailableFrames(from: &buffer).count,
            SecureSessionWireCodec.maximumFramesPerDecode
        )
        XCTAssertEqual(
            try SecureSessionWireCodec.decodeAvailableFrames(from: &buffer),
            [.packet(packet)]
        )
        XCTAssertTrue(buffer.isEmpty)
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
                senderModel: "MacBookPro18,3",
                ephemeralKey: initiatorEphemeralKey
            ),
            responderHandshake: .make(
                sessionID: sessionID,
                role: .responder,
                sender: responder,
                senderModel: "MacBookPro18,4",
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
