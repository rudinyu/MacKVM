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
    public let verificationCommitment: Data?
    public let verificationContribution: Data?
    public let accepted: Bool?

    public init(
        kind: PairingMessageKind,
        requestID: UUID = UUID(),
        sender: PeerIdentity,
        verificationCommitment: Data? = nil,
        verificationContribution: Data? = nil,
        accepted: Bool? = nil
    ) {
        self.kind = kind
        self.requestID = requestID
        self.sender = sender
        self.verificationCommitment = verificationCommitment
        self.verificationContribution = verificationContribution
        self.accepted = accepted
    }

    public static func request(
        from sender: PeerIdentity,
        requestID: UUID = UUID(),
        commitment: Data
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .request,
            requestID: requestID,
            sender: sender,
            verificationCommitment: commitment
        )
    }

    public static func challenge(
        to message: PairingEnvelope,
        from sender: PeerIdentity,
        commitment: Data
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .challenge,
            requestID: message.requestID,
            sender: sender,
            verificationCommitment: commitment
        )
    }

    public static func reveal(
        to message: PairingEnvelope,
        from sender: PeerIdentity,
        contribution: Data
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .reveal,
            requestID: message.requestID,
            sender: sender,
            verificationContribution: contribution
        )
    }

    public static func confirmation(
        to message: PairingEnvelope,
        from sender: PeerIdentity,
        contribution: Data
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .confirmation,
            requestID: message.requestID,
            sender: sender,
            verificationContribution: contribution
        )
    }

    public static func decision(
        to message: PairingEnvelope,
        from sender: PeerIdentity,
        accepted: Bool
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .decision,
            requestID: message.requestID,
            sender: sender,
            accepted: accepted
        )
    }

    public static func completion(
        to message: PairingEnvelope,
        from sender: PeerIdentity
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .completion,
            requestID: message.requestID,
            sender: sender
        )
    }

    public static func completionAcknowledgement(
        to message: PairingEnvelope,
        from sender: PeerIdentity
    ) -> PairingEnvelope {
        PairingEnvelope(
            kind: .completionAcknowledgement,
            requestID: message.requestID,
            sender: sender
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
        let messageData = try canonicalData(for: message)
        let signature = try privateKey.signature(for: messageData)
        let signedEnvelope = SignedPairingEnvelope(
            message: message,
            signature: signature.derRepresentation
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
            try verify(signedEnvelope)
            messages.append(signedEnvelope.message)
        }
        return messages
    }

    private static func verify(
        _ signedEnvelope: SignedPairingEnvelope
    ) throws {
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
    }

    private static func canonicalData(
        for message: PairingEnvelope
    ) throws -> Data {
        try CanonicalJSON.encoder().encode(message)
    }
}

public enum PairingWireError: Error, Equatable {
    case payloadTooLarge
    case tooManyMessages
    case invalidSignature
    case invalidIdentityName
}

private struct SignedPairingEnvelope: Codable {
    let message: PairingEnvelope
    let signature: Data
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
