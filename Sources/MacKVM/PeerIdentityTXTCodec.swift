import CryptoKit
import Foundation
import MacKVMCore
import Network

struct PeerAdvertisement: Equatable, Sendable {
    let identity: PeerIdentity
    let model: String
}

enum PeerIdentityTXTCodec {
    static func decode(_ txtRecord: NWTXTRecord) -> PeerIdentity? {
        decodeAdvertisement(txtRecord)?.identity
    }

    static func decodeAdvertisement(
        _ txtRecord: NWTXTRecord
    ) -> PeerAdvertisement? {
        let values = txtRecord.dictionary
        guard let idValue = values["id"],
              let id = UUID(uuidString: idValue),
              let name = values["name"],
              PeerIdentity.isValidDisplayName(name),
              let keyValue = values["key"],
              let publicKey = Data(base64Encoded: keyValue),
              (try? P256.Signing.PublicKey(
                  x963Representation: publicKey
              )) != nil else {
            return nil
        }
        return PeerAdvertisement(
            identity: PeerIdentity(
                id: id,
                name: name,
                signingPublicKey: publicKey
            ),
            model: PeerMetadataValidation.validatedModel(values["model"])
        )
    }
}
