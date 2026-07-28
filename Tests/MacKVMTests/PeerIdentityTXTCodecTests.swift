import CryptoKit
import Foundation
import MacKVMCore
import Network
import XCTest
@testable import MacKVM

final class PeerIdentityTXTCodecTests: XCTestCase {
    func testDecodesValidIdentity() {
        let id = UUID()
        let key = P256.Signing.PrivateKey().publicKey.x963Representation
        let record = NWTXTRecord([
            "id": id.uuidString,
            "name": "Desk Mac",
            "key": key.base64EncodedString()
        ])

        XCTAssertEqual(
            PeerIdentityTXTCodec.decode(record),
            PeerIdentity(
                id: id,
                name: "Desk Mac",
                signingPublicKey: key
            )
        )
    }

    func testRejectsInvalidPublicKey() {
        let record = NWTXTRecord([
            "id": UUID().uuidString,
            "name": "Desk Mac",
            "key": Data("not a P-256 key".utf8).base64EncodedString()
        ])

        XCTAssertNil(PeerIdentityTXTCodec.decode(record))
    }
}
