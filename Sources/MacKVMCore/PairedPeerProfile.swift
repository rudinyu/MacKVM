import CryptoKit
import Foundation

public enum PeerMetadataValidation {
    public static let maximumModelBytes = 64
    public static let unknownModel = "Unknown Mac"

    public static func validatedModel(_ model: String?) -> String {
        guard let model else { return unknownModel }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= maximumModelBytes,
              PeerIdentity.isValidDisplayName(trimmed) else {
            return unknownModel
        }
        return trimmed
    }
}

public enum PeerKeyFingerprint {
    /// Returns the SHA-256 fingerprint of a public-key representation.
    /// The fingerprint is safe to show in support diagnostics; it is not a
    /// substitute for the pinned key used to authenticate a session.
    public static func string(for publicKey: Data) -> String {
        SHA256.hash(data: publicKey)
            .map { String(format: "%02X", $0) }
            .joined(separator: ":")
    }
}

public struct PairedPeerProfile: Codable, Equatable, Sendable, Identifiable {
    public let peerID: UUID
    public var friendlyName: String
    public var model: String
    public var lastConnectedAt: Date?
    /// A local, receiver-side one-time consent for this pinned peer. This is
    /// deliberately stored beside (and validated against) the pinned public
    /// key; it is never sent over the control protocol.
    public var seamlessControlAuthorized: Bool
    public let signingPublicKey: Data

    public var id: UUID { peerID }

    public var keyFingerprint: String {
        PeerKeyFingerprint.string(for: signingPublicKey)
    }

    public init(
        peerID: UUID,
        friendlyName: String,
        model: String? = nil,
        lastConnectedAt: Date? = nil,
        seamlessControlAuthorized: Bool = false,
        signingPublicKey: Data
    ) {
        self.peerID = peerID
        self.friendlyName = PeerIdentity.validatedDisplayName(friendlyName)
            ?? "Mac \(peerID.uuidString.prefix(8))"
        self.model = PeerMetadataValidation.validatedModel(model)
        self.lastConnectedAt = lastConnectedAt
        self.seamlessControlAuthorized = seamlessControlAuthorized
        self.signingPublicKey = signingPublicKey
    }

    private enum CodingKeys: String, CodingKey {
        case peerID
        case friendlyName
        case model
        case lastConnectedAt
        case seamlessControlAuthorized
        case signingPublicKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let peerID = try container.decode(UUID.self, forKey: .peerID)
        let friendlyName = try container.decodeIfPresent(
            String.self,
            forKey: .friendlyName
        ) ?? "Mac \(peerID.uuidString.prefix(8))"
        let model = try container.decodeIfPresent(
            String.self,
            forKey: .model
        )
        let lastConnectedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .lastConnectedAt
        )
        let seamlessControlAuthorized = try container.decodeIfPresent(
            Bool.self,
            forKey: .seamlessControlAuthorized
        ) ?? false
        let signingPublicKey = try container.decode(
            Data.self,
            forKey: .signingPublicKey
        )
        self.init(
            peerID: peerID,
            friendlyName: friendlyName,
            model: model,
            lastConnectedAt: lastConnectedAt,
            seamlessControlAuthorized: seamlessControlAuthorized,
            signingPublicKey: signingPublicKey
        )
    }
}
