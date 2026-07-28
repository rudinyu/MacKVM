import CryptoKit
import Foundation
import XCTest
@testable import MacKVMCore

final class SecureControlIntegrationTests: XCTestCase {
    func testControlInputTraversesAuthenticatedEncryptedChannel() throws {
        let fixture = try makeFixture()
        let requestID = UUID()
        let original = ControlMessage.input(
            RemoteInputEvent(
                kind: .leftMouseDown,
                location: NormalizedPoint(x: 0.4, y: 0.6),
                buttonNumber: 0,
                clickCount: 1
            ),
            requestID: requestID
        )
        let plaintext = try ControlMessageCodec.encode(original)
        let packet = try fixture.initiatorChannel.seal(plaintext)
        let wireData = try SecureSessionWireCodec.encode(packet: packet)
        var buffer = wireData

        guard case .packet(let decodedPacket) = try XCTUnwrap(
            SecureSessionWireCodec.decodeAvailableFrames(from: &buffer).first
        ) else {
            return XCTFail("Expected one encrypted packet")
        }
        let opened = try fixture.responderChannel.open(decodedPacket)
        let received = try ControlMessageCodec.decode(opened)

        XCTAssertEqual(received, original)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testEncryptedControlPacketCannotBeReplayed() throws {
        let fixture = try makeFixture()
        let request = ControlMessage(
            kind: .requestControl,
            requestID: UUID()
        )
        let packet = try fixture.initiatorChannel.seal(
            ControlMessageCodec.encode(request)
        )

        _ = try fixture.responderChannel.open(packet)
        XCTAssertThrowsError(try fixture.responderChannel.open(packet)) {
            XCTAssertEqual(
                $0 as? SecureSessionError,
                .unexpectedSequence
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let sessionID = UUID()
        let initiatorSigningKey = P256.Signing.PrivateKey()
        let responderSigningKey = P256.Signing.PrivateKey()
        let initiatorEphemeralKey = P256.KeyAgreement.PrivateKey()
        let responderEphemeralKey = P256.KeyAgreement.PrivateKey()
        let initiator = PeerIdentity(
            name: "Controller",
            signingPublicKey: initiatorSigningKey.publicKey.x963Representation
        )
        let responder = PeerIdentity(
            name: "Receiver",
            signingPublicKey: responderSigningKey.publicKey.x963Representation
        )
        let initiatorHandshake = SecureSessionHandshake.make(
            sessionID: sessionID,
            role: .initiator,
            sender: initiator,
            ephemeralKey: initiatorEphemeralKey
        )
        let responderHandshake = SecureSessionHandshake.make(
            sessionID: sessionID,
            role: .responder,
            sender: responder,
            ephemeralKey: responderEphemeralKey
        )
        return Fixture(
            initiatorChannel: try SecureSessionChannel(
                localRole: .initiator,
                localEphemeralKey: initiatorEphemeralKey,
                initiator: initiatorHandshake,
                responder: responderHandshake
            ),
            responderChannel: try SecureSessionChannel(
                localRole: .responder,
                localEphemeralKey: responderEphemeralKey,
                initiator: initiatorHandshake,
                responder: responderHandshake
            )
        )
    }
}

private struct Fixture {
    let initiatorChannel: SecureSessionChannel
    let responderChannel: SecureSessionChannel
}
