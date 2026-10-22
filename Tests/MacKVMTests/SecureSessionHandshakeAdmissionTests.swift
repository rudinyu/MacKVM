import CryptoKit
import Foundation
import MacKVMCore
import XCTest
@testable import MacKVM

final class SecureSessionHandshakeAdmissionTests: XCTestCase {
    func testAuthenticatedHandshakeAdmissionRequiresInitiatorRoleAndPinnedNonSelfPeer() {
        let localID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let remoteID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
        let signingKey = P256.Signing.PrivateKey()
        let peer = PeerIdentity(
            id: remoteID,
            name: "Remote Mac",
            signingPublicKey: signingKey.publicKey.x963Representation
        )
        let initiatorHandshake = SecureSessionHandshake.make(
            role: .initiator,
            sender: peer,
            ephemeralKey: P256.KeyAgreement.PrivateKey()
        )

        XCTAssertTrue(
            SecureSessionHandshakeAdmissionPolicy.acceptsPinnedInitiator(
                localID: localID,
                handshake: initiatorHandshake,
                pinnedPublicKey: peer.signingPublicKey
            )
        )
        XCTAssertFalse(
            SecureSessionHandshakeAdmissionPolicy.acceptsPinnedInitiator(
                localID: localID,
                handshake: initiatorHandshake,
                pinnedPublicKey: P256.Signing.PrivateKey()
                    .publicKey.x963Representation
            )
        )

        let responderHandshake = SecureSessionHandshake.make(
            role: .responder,
            sender: peer,
            ephemeralKey: P256.KeyAgreement.PrivateKey()
        )
        XCTAssertFalse(
            SecureSessionHandshakeAdmissionPolicy.acceptsPinnedInitiator(
                localID: localID,
                handshake: responderHandshake,
                pinnedPublicKey: peer.signingPublicKey
            )
        )
        XCTAssertFalse(
            SecureSessionHandshakeAdmissionPolicy.acceptsPinnedInitiator(
                localID: remoteID,
                handshake: initiatorHandshake,
                pinnedPublicKey: peer.signingPublicKey
            )
        )
    }

    func testInvalidHandshakeSignatureIsRejectedBeforeSessionAdmission() throws {
        let remoteID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
        let peerSigningKey = P256.Signing.PrivateKey()
        let peer = PeerIdentity(
            id: remoteID,
            name: "Remote Mac",
            signingPublicKey: peerSigningKey.publicKey.x963Representation
        )
        let handshake = SecureSessionHandshake.make(
            role: .initiator,
            sender: peer,
            ephemeralKey: P256.KeyAgreement.PrivateKey()
        )
        var buffer = try SecureSessionWireCodec.encode(
            handshake: handshake,
            signingWith: P256.Signing.PrivateKey()
        )

        XCTAssertThrowsError(
            try SecureSessionWireCodec.decodeAvailableFrames(from: &buffer)
        ) { error in
            XCTAssertEqual(error as? SecureSessionError, .invalidSignature)
        }
    }
}
