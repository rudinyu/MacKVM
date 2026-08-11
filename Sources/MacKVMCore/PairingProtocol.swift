import CryptoKit
import Foundation

public enum PairingMessageKind: String, Codable, Sendable {
    case request
    case challenge
    case reveal
    case confirmation
    case decision
    case completion
    case completionAcknowledgement
}

public struct PairingEnvelope: Codable, Equatable, Sendable {
    public let kind: PairingMessageKind
    public let requestID: UUID
    public let sender: PeerIdentity
    /// Optional signed hardware metadata. It is transported as a separately
    /// signed extension so peers from older releases can still verify the
    /// legacy message bytes.
    public let senderModel: String?
    public let verificationCommitment: Data?
    public let verificationContribution: Data?
    public let accepted: Bool?

    public init(
        kind: PairingMessageKind,
        requestID: UUID = UUID(),
        sender: PeerIdentity,
        senderModel: String? = nil,
        verificationCommitment: Data? = nil,
        verificationContribution: Data? = nil,
        accepted: Bool? = nil
    ) {
        self.kind = kind
        self.requestID = requestID
        self.sender = sender
        self.senderModel = senderModel.map {
            PeerMetadataValidation.validatedModel($0)
        }
        self.verificationCommitment = verificationCommitment
        self.verificationContribution = verificationContribution
        self.accepted = accepted
    }

    public static func request(
        from sender: PeerIdentity,
        requestID: UUID = UUID(),
        commitment: Data,
        senderModel: String? = nil
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .request,
            requestID: requestID,
            sender: sender,
            senderModel: senderModel,
            verificationCommitment: commitment
        )
    }

    public static func challenge(
        to message: PairingEnvelope,
        from sender: PeerIdentity,
        commitment: Data,
        senderModel: String? = nil
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .challenge,
            requestID: message.requestID,
            sender: sender,
            senderModel: senderModel,
            verificationCommitment: commitment
        )
    }

    public static func reveal(
        to message: PairingEnvelope,
        from sender: PeerIdentity,
        contribution: Data,
        senderModel: String? = nil
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .reveal,
            requestID: message.requestID,
            sender: sender,
            senderModel: senderModel,
            verificationContribution: contribution
        )
    }

    public static func confirmation(
        to message: PairingEnvelope,
        from sender: PeerIdentity,
        contribution: Data,
        senderModel: String? = nil
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .confirmation,
            requestID: message.requestID,
            sender: sender,
            senderModel: senderModel,
            verificationContribution: contribution
        )
    }

    public static func decision(
        to message: PairingEnvelope,
        from sender: PeerIdentity,
        accepted: Bool,
        senderModel: String? = nil
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .decision,
            requestID: message.requestID,
            sender: sender,
            senderModel: senderModel,
            accepted: accepted
        )
    }

    public static func completion(
        to message: PairingEnvelope,
        from sender: PeerIdentity,
        senderModel: String? = nil
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .completion,
            requestID: message.requestID,
            sender: sender,
            senderModel: senderModel
        )
    }

    public static func completionAcknowledgement(
        to message: PairingEnvelope,
        from sender: PeerIdentity,
        senderModel: String? = nil
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .completionAcknowledgement,
            requestID: message.requestID,
            sender: sender,
            senderModel: senderModel
        )
    }
}

public enum PairingWireCodec {
    public static let maximumFramePayloadLength =
        LengthPrefixedFrameCodec.maximumSecurePayloadLength
    public static let maximumFramesPerDecode = 16

    public static func hasCompleteFrame(in buffer: Data) -> Bool {
        LengthPrefixedFrameCodec.hasCompleteFrame(
            in: buffer,
            maximumPayloadLength: maximumFramePayloadLength
        )
    }

    public static func encode(
        _ message: PairingEnvelope,
        signingWith privateKey: P256.Signing.PrivateKey
    ) throws -> Data {
        // Keep the legacy signed message bytes unchanged. Model metadata is
        // an optional separately signed extension so older peers can ignore
        // the additional fields and still verify the base signature.
        let baseMessage = PairingEnvelope(
            kind: message.kind,
            requestID: message.requestID,
            sender: message.sender,
            verificationCommitment: message.verificationCommitment,
            verificationContribution: message.verificationContribution,
            accepted: message.accepted
        )
        let messageData = try canonicalData(for: baseMessage)
        let signature = try privateKey.signature(for: messageData)
        let modelSignature: Data?
        if let senderModel = message.senderModel {
            let extensionData = try canonicalData(
                for: PairingModelExtension(
                    kind: message.kind,
                    requestID: message.requestID,
                    senderID: message.sender.id,
                    model: senderModel
                )
            )
            modelSignature = try privateKey.signature(
                for: extensionData
            ).derRepresentation
        } else {
            modelSignature = nil
        }
        let signedEnvelope = SignedPairingEnvelope(
            message: baseMessage,
            signature: signature.derRepresentation,
            senderModel: message.senderModel,
            senderModelSignature: modelSignature
        )
        let payload = try CanonicalJSON.encoder().encode(signedEnvelope)
        do {
            return try LengthPrefixedFrameCodec.encode(
                payload,
                maximumPayloadLength: maximumFramePayloadLength
            )
        } catch {
            throw PairingWireError.payloadTooLarge
        }
    }

    public static func decodeAvailableFrames(
        from buffer: inout Data,
        maximumFrameCount: Int = maximumFramesPerDecode
    ) throws -> [PairingEnvelope] {
        var messages: [PairingEnvelope] = []
        let payloads: [Data]
        do {
            payloads = try LengthPrefixedFrameCodec
                .decodeAvailablePayloads(
                    from: &buffer,
                    maximumPayloadLength: maximumFramePayloadLength,
                    maximumFrameCount: maximumFrameCount
                )
        } catch {
            throw PairingWireError.payloadTooLarge
        }
        for payload in payloads {
            let signedEnvelope = try JSONDecoder().decode(
                SignedPairingEnvelope.self,
                from: payload
            )
            messages.append(try verify(signedEnvelope))
        }
        return messages
    }

    private static func verify(
        _ signedEnvelope: SignedPairingEnvelope
    ) throws -> PairingEnvelope {
        guard signedEnvelope.message.senderModel == nil else {
            throw PairingWireError.invalidModel
        }
        guard PeerIdentity.isValidDisplayName(
            signedEnvelope.message.sender.name
        ) else {
            throw PairingWireError.invalidIdentityName
        }
        guard let publicKey = try? P256.Signing.PublicKey(
            x963Representation: signedEnvelope.message.sender.signingPublicKey
        ), let signature = try? P256.Signing.ECDSASignature(
            derRepresentation: signedEnvelope.signature
        ) else {
            throw PairingWireError.invalidSignature
        }

        let messageData = try canonicalData(for: signedEnvelope.message)
        guard publicKey.isValidSignature(signature, for: messageData) else {
            throw PairingWireError.invalidSignature
        }

        let model: String?
        switch (
            signedEnvelope.senderModel,
            signedEnvelope.senderModelSignature
        ) {
        case (nil, nil):
            model = nil
        case let (.some(senderModel), .some(modelSignatureData)):
            guard PeerMetadataValidation.validatedModel(senderModel)
                    == senderModel,
                  let modelSignature = try? P256.Signing.ECDSASignature(
                      derRepresentation: modelSignatureData
                  ) else {
                throw PairingWireError.invalidModel
            }
            let extensionData = try canonicalData(
                for: PairingModelExtension(
                    kind: signedEnvelope.message.kind,
                    requestID: signedEnvelope.message.requestID,
                    senderID: signedEnvelope.message.sender.id,
                    model: senderModel
                )
            )
            guard publicKey.isValidSignature(
                modelSignature,
                for: extensionData
            ) else {
                throw PairingWireError.invalidSignature
            }
            model = senderModel
        default:
            throw PairingWireError.invalidModel
        }
        // Reconstruct the authenticated message only after both signatures
        // have been verified. Callers must never consume an unsigned model.
        let message = signedEnvelope.message
        return PairingEnvelope(
            kind: message.kind,
            requestID: message.requestID,
            sender: message.sender,
            senderModel: model,
            verificationCommitment: message.verificationCommitment,
            verificationContribution: message.verificationContribution,
            accepted: message.accepted
        )
    }

    private static func canonicalData<T: Encodable>(for value: T) throws -> Data {
        try CanonicalJSON.encoder().encode(value)
    }
}

public enum PairingWireError: Error, Equatable {
    case payloadTooLarge
    case tooManyMessages
    case invalidSignature
    case invalidIdentityName
    case invalidModel
}

private struct SignedPairingEnvelope: Codable {
    let message: PairingEnvelope
    let signature: Data
    let senderModel: String?
    let senderModelSignature: Data?
}

private struct PairingModelExtension: Codable {
    let kind: PairingMessageKind
    let requestID: UUID
    let senderID: UUID
    let model: String
}

public enum PairingVerificationCode {
    public static let contributionLength = 32

    public static func makeContribution() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data(
            (0..<contributionLength).map { _ in
                UInt8.random(in: .min ... .max, using: &generator)
            }
        )
    }

    public static func commitment(
        requestID: UUID,
        publicKey: Data,
        contribution: Data
    ) -> Data {
        var input = Data("MacKVM pairing commitment v1".utf8)
        input.append(Data(requestID.uuidString.utf8))
        input.append(publicKey)
        input.append(contribution)
        return Data(SHA256.hash(data: input))
    }

    public static func verifies(
        commitment: Data,
        requestID: UUID,
        publicKey: Data,
        contribution: Data
    ) -> Bool {
        contribution.count == contributionLength
            && commitment == self.commitment(
                requestID: requestID,
                publicKey: publicKey,
                contribution: contribution
            )
    }

    public static func make(
        requestID: UUID,
        initiatorPublicKey: Data,
        responderPublicKey: Data,
        initiatorContribution: Data,
        responderContribution: Data
    ) -> String {
        var input = Data("MacKVM pairing verification v1".utf8)
        input.append(Data(requestID.uuidString.utf8))
        input.append(initiatorPublicKey)
        input.append(responderPublicKey)
        input.append(initiatorContribution)
        input.append(responderContribution)

        let digest = SHA256.hash(data: input)
        let numericCode = digest.prefix(4).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        } % 1_000_000
        return String(format: "%06u", numericCode)
    }
}
