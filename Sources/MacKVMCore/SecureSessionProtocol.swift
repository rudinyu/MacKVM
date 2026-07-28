import CryptoKit
import Foundation

public enum SecureSessionRole: String, Codable, Sendable {
    case initiator
    case responder
}

public enum SecureSessionCollisionPolicy {
    public static func preferredRole(
        localID: UUID,
        remoteID: UUID
    ) -> SecureSessionRole {
        PeerArbitration.localIDWins(
            localID: localID,
            remoteID: remoteID
        )
            ? .initiator
            : .responder
    }
}

public struct SecureSessionHandshake: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let role: SecureSessionRole
    public let sender: PeerIdentity
    public let ephemeralPublicKey: Data
    public let nonce: Data

    public init(
        sessionID: UUID,
        role: SecureSessionRole,
        sender: PeerIdentity,
        ephemeralPublicKey: Data,
        nonce: Data
    ) {
        self.sessionID = sessionID
        self.role = role
        self.sender = sender
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
    }

    public static func make(
        sessionID: UUID = UUID(),
        role: SecureSessionRole,
        sender: PeerIdentity,
        ephemeralKey: P256.KeyAgreement.PrivateKey
    ) -> SecureSessionHandshake {
        SecureSessionHandshake(
            sessionID: sessionID,
            role: role,
            sender: sender,
            ephemeralPublicKey: ephemeralKey.publicKey.x963Representation,
            nonce: PairingVerificationCode.makeContribution()
        )
    }
}

public struct SecurePacket: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let sequence: UInt64
    public let sealedData: Data

    public init(sessionID: UUID, sequence: UInt64, sealedData: Data) {
        self.sessionID = sessionID
        self.sequence = sequence
        self.sealedData = sealedData
    }
}

public enum SecureSessionWireMessage: Equatable, Sendable {
    case handshake(SecureSessionHandshake)
    case packet(SecurePacket)
}

public enum SecureSessionWireCodec {
    public static func encode(
        handshake: SecureSessionHandshake,
        signingWith privateKey: P256.Signing.PrivateKey
    ) throws -> Data {
        let handshakeData = try CanonicalJSON.encoder().encode(handshake)
        let signature = try privateKey.signature(for: handshakeData)
        return try frame(
            WireEnvelope(
                kind: .handshake,
                handshake: handshake,
                signature: signature.derRepresentation,
                packet: nil
            )
        )
    }

    public static func encode(packet: SecurePacket) throws -> Data {
        try frame(
            WireEnvelope(
                kind: .packet,
                handshake: nil,
                signature: nil,
                packet: packet
            )
        )
    }

    public static func decodeAvailableFrames(
        from buffer: inout Data
    ) throws -> [SecureSessionWireMessage] {
        var messages: [SecureSessionWireMessage] = []
        let payloads: [Data]
        do {
            payloads = try LengthPrefixedFrameCodec
                .decodeAvailablePayloads(from: &buffer)
        } catch {
            throw SecureSessionError.invalidFrame
        }
        for payload in payloads {
            let envelope = try JSONDecoder().decode(
                WireEnvelope.self,
                from: payload
            )
            messages.append(try decode(envelope))
        }
        return messages
    }

    private static func decode(
        _ envelope: WireEnvelope
    ) throws -> SecureSessionWireMessage {
        switch envelope.kind {
        case .handshake:
            guard let handshake = envelope.handshake,
                  envelope.packet == nil,
                  let signatureData = envelope.signature,
                  handshake.nonce.count == PairingVerificationCode.contributionLength,
                  let publicKey = try? P256.Signing.PublicKey(
                      x963Representation: handshake.sender.signingPublicKey
                  ),
                  let ephemeralKey = try? P256.KeyAgreement.PublicKey(
                      x963Representation: handshake.ephemeralPublicKey
                  ),
                  !ephemeralKey.x963Representation.isEmpty,
                  let signature = try? P256.Signing.ECDSASignature(
                      derRepresentation: signatureData
                  ) else {
                throw SecureSessionError.invalidHandshake
            }
            let data = try CanonicalJSON.encoder().encode(handshake)
            guard publicKey.isValidSignature(signature, for: data) else {
                throw SecureSessionError.invalidSignature
            }
            return .handshake(handshake)
        case .packet:
            guard let packet = envelope.packet,
                  envelope.handshake == nil,
                  envelope.signature == nil else {
                throw SecureSessionError.invalidFrame
            }
            return .packet(packet)
        }
    }

    private static func frame(_ envelope: WireEnvelope) throws -> Data {
        let payload = try CanonicalJSON.encoder().encode(envelope)
        do {
            return try LengthPrefixedFrameCodec.encode(payload)
        } catch {
            throw SecureSessionError.invalidFrame
        }
    }
}

public final class SecureSessionChannel {
    public let sessionID: UUID

    private let sendingKey: SymmetricKey
    private let receivingKey: SymmetricKey
    private var nextSendingSequence: UInt64 = 0
    private var nextReceivingSequence: UInt64 = 0

    public init(
        localRole: SecureSessionRole,
        localEphemeralKey: P256.KeyAgreement.PrivateKey,
        initiator: SecureSessionHandshake,
        responder: SecureSessionHandshake
    ) throws {
        guard initiator.role == .initiator,
              responder.role == .responder,
              initiator.sessionID == responder.sessionID else {
            throw SecureSessionError.invalidHandshake
        }
        let remoteKeyData = localRole == .initiator
            ? responder.ephemeralPublicKey
            : initiator.ephemeralPublicKey
        let remoteKey = try P256.KeyAgreement.PublicKey(
            x963Representation: remoteKeyData
        )
        let sharedSecret = try localEphemeralKey.sharedSecretFromKeyAgreement(
            with: remoteKey
        )
        let transcript = Self.transcript(
            initiator: initiator,
            responder: responder
        )
        let initiatorToResponder = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("MacKVM secure session i2r v1".utf8),
            outputByteCount: 32
        )
        let responderToInitiator = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: transcript,
            sharedInfo: Data("MacKVM secure session r2i v1".utf8),
            outputByteCount: 32
        )
        sessionID = initiator.sessionID
        if localRole == .initiator {
            sendingKey = initiatorToResponder
            receivingKey = responderToInitiator
        } else {
            sendingKey = responderToInitiator
            receivingKey = initiatorToResponder
        }
    }

    public func seal(_ plaintext: Data) throws -> SecurePacket {
        guard nextSendingSequence < UInt64.max else {
            throw SecureSessionError.sequenceExhausted
        }
        let sequence = nextSendingSequence
        let box = try ChaChaPoly.seal(
            plaintext,
            using: sendingKey,
            authenticating: authenticatedData(sequence: sequence)
        )
        nextSendingSequence += 1
        return SecurePacket(
            sessionID: sessionID,
            sequence: sequence,
            sealedData: box.combined
        )
    }

    public func open(_ packet: SecurePacket) throws -> Data {
        guard packet.sessionID == sessionID,
              packet.sequence == nextReceivingSequence else {
            throw SecureSessionError.unexpectedSequence
        }
        let box = try ChaChaPoly.SealedBox(combined: packet.sealedData)
        let plaintext = try ChaChaPoly.open(
            box,
            using: receivingKey,
            authenticating: authenticatedData(sequence: packet.sequence)
        )
        guard nextReceivingSequence < UInt64.max else {
            throw SecureSessionError.sequenceExhausted
        }
        nextReceivingSequence += 1
        return plaintext
    }

    private func authenticatedData(sequence: UInt64) -> Data {
        var data = Data("MacKVM packet v1".utf8)
        data.append(Data(sessionID.uuidString.utf8))
        data.append(contentsOf: Self.bytes(of: sequence))
        return data
    }

    private static func transcript(
        initiator: SecureSessionHandshake,
        responder: SecureSessionHandshake
    ) -> Data {
        var data = Data("MacKVM secure transcript v1".utf8)
        data.append(Data(initiator.sessionID.uuidString.utf8))
        data.append(initiator.sender.signingPublicKey)
        data.append(responder.sender.signingPublicKey)
        data.append(initiator.ephemeralPublicKey)
        data.append(responder.ephemeralPublicKey)
        data.append(initiator.nonce)
        data.append(responder.nonce)
        return Data(SHA256.hash(data: data))
    }

    private static func bytes(of value: UInt64) -> [UInt8] {
        (0..<8).reversed().map { shift in
            UInt8((value >> UInt64(shift * 8)) & 0xFF)
        }
    }
}

public enum SecureSessionError: Error, Equatable {
    case invalidFrame
    case invalidSignature
    case invalidHandshake
    case unexpectedSequence
    case sequenceExhausted
}

private enum WireKind: String, Codable {
    case handshake
    case packet
}

private struct WireEnvelope: Codable {
    let kind: WireKind
    let handshake: SecureSessionHandshake?
    let signature: Data?
    let packet: SecurePacket?
}
