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
    public static let currentDisconnectSignalVersion = 1

    public let sessionID: UUID
    public let role: SecureSessionRole
    public let sender: PeerIdentity
    /// An optional signed hardware model. It is optional on the wire so a
    /// newer release can still decode a handshake from an older peer;
    /// `SecureSessionService` deliberately turns that result into an explicit
    /// coordinated-upgrade requirement instead of selecting a weaker close
    /// protocol.
    public let senderModel: String?
    /// Signed capability extension for the current secure-session contract.
    /// The optional representation is retained so the wire decoder can identify
    /// pre-capability peers; `SecureSessionService` rejects nil with an explicit
    /// upgrade message instead of allowing a downgrade to EOF teardown.
    public let disconnectSignalVersion: Int?
    public let ephemeralPublicKey: Data
    public let nonce: Data

    public init(
        sessionID: UUID,
        role: SecureSessionRole,
        sender: PeerIdentity,
        senderModel: String? = nil,
        disconnectSignalVersion: Int? = currentDisconnectSignalVersion,
        ephemeralPublicKey: Data,
        nonce: Data
    ) {
        self.sessionID = sessionID
        self.role = role
        self.sender = sender
        self.senderModel = senderModel.map {
            PeerMetadataValidation.validatedModel($0)
        }
        self.disconnectSignalVersion = disconnectSignalVersion
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID
        case role
        case sender
        case senderModel
        case disconnectSignalVersion
        case ephemeralPublicKey
        case nonce
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            role: try container.decode(SecureSessionRole.self, forKey: .role),
            sender: try container.decode(PeerIdentity.self, forKey: .sender),
            senderModel: try container.decodeIfPresent(
                String.self,
                forKey: .senderModel
            ),
            disconnectSignalVersion: try container.decodeIfPresent(
                Int.self,
                forKey: .disconnectSignalVersion
            ),
            ephemeralPublicKey: try container.decode(
                Data.self,
                forKey: .ephemeralPublicKey
            ),
            nonce: try container.decode(Data.self, forKey: .nonce)
        )
    }

    public static func make(
        sessionID: UUID = UUID(),
        role: SecureSessionRole,
        sender: PeerIdentity,
        senderModel: String? = nil,
        disconnectSignalVersion: Int? = currentDisconnectSignalVersion,
        ephemeralKey: P256.KeyAgreement.PrivateKey
    ) -> SecureSessionHandshake {
        SecureSessionHandshake(
            sessionID: sessionID,
            role: role,
            sender: sender,
            senderModel: senderModel,
            disconnectSignalVersion: disconnectSignalVersion,
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

/// Encrypted control payloads used by the secure transport itself rather than
/// by the keyboard/mouse control protocol. The marker is sent inside a
/// `SecurePacket`, so only an already-authenticated peer can request the
/// corresponding session teardown.
public enum SecureSessionControlSignal {
    public static let disconnect = Data(
        "MacKVM secure session disconnect v1".utf8
    )
    public static let disconnectAcknowledgement = Data(
        "MacKVM secure session disconnect acknowledgement v1".utf8
    )

    public static func isDisconnect(_ payload: Data) -> Bool {
        payload == disconnect
    }

    public static func isDisconnectAcknowledgement(_ payload: Data) -> Bool {
        payload == disconnectAcknowledgement
    }
}

public enum SecureSessionWireMessage: Equatable, Sendable {
    case handshake(SecureSessionHandshake)
    case packet(SecurePacket)
}

public enum SecureSessionWireCodec {
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
        handshake: SecureSessionHandshake,
        signingWith privateKey: P256.Signing.PrivateKey
    ) throws -> Data {
        // Keep the base handshake byte-for-byte compatible with older
        // releases. The capability is a separately signed extension; older
        // peers can still parse the base envelope, while the current service
        // requires both sides to support the authenticated close contract.
        let baseHandshake = SecureSessionHandshake(
            sessionID: handshake.sessionID,
            role: handshake.role,
            sender: handshake.sender,
            disconnectSignalVersion: nil,
            ephemeralPublicKey: handshake.ephemeralPublicKey,
            nonce: handshake.nonce
        )
        let handshakeData = try CanonicalJSON.encoder().encode(baseHandshake)
        let signature = try privateKey.signature(for: handshakeData)
        let modelSignature: Data?
        if let senderModel = handshake.senderModel {
            let extensionData = try CanonicalJSON.encoder().encode(
                HandshakeModelExtension(
                    sessionID: handshake.sessionID,
                    role: handshake.role,
                    senderID: handshake.sender.id,
                    model: senderModel
                )
            )
            modelSignature = try privateKey.signature(
                for: extensionData
            ).derRepresentation
        } else {
            modelSignature = nil
        }
        let disconnectCapabilitySignature: Data?
        if let version = handshake.disconnectSignalVersion {
            let extensionData = try CanonicalJSON.encoder().encode(
                HandshakeDisconnectExtension(
                    sessionID: handshake.sessionID,
                    role: handshake.role,
                    senderID: handshake.sender.id,
                    version: version
                )
            )
            disconnectCapabilitySignature = try privateKey.signature(
                for: extensionData
            ).derRepresentation
        } else {
            disconnectCapabilitySignature = nil
        }
        return try frame(
            WireEnvelope(
                kind: .handshake,
                handshake: baseHandshake,
                signature: signature.derRepresentation,
                senderModel: handshake.senderModel,
                senderModelSignature: modelSignature,
                disconnectSignalVersion: handshake.disconnectSignalVersion,
                disconnectSignalVersionSignature: disconnectCapabilitySignature,
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
                senderModel: nil,
                senderModelSignature: nil,
                disconnectSignalVersion: nil,
                disconnectSignalVersionSignature: nil,
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
                .decodeAvailablePayloads(
                    from: &buffer,
                    maximumPayloadLength: maximumFramePayloadLength,
                    maximumFrameCount: maximumFramesPerDecode
                )
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
            guard PeerIdentity.isValidDisplayName(handshake.sender.name) else {
                throw SecureSessionError.invalidIdentityName
            }
            let data = try CanonicalJSON.encoder().encode(handshake)
            guard publicKey.isValidSignature(signature, for: data) else {
                throw SecureSessionError.invalidSignature
            }
            let model: String?
            switch (envelope.senderModel, envelope.senderModelSignature) {
            case (nil, nil):
                model = nil
            case let (.some(senderModel), .some(modelSignatureData)):
                guard let modelSignature = try? P256.Signing.ECDSASignature(
                    derRepresentation: modelSignatureData
                ),
                      PeerMetadataValidation.validatedModel(senderModel)
                        == senderModel else {
                    throw SecureSessionError.invalidHandshake
                }
                let extensionData = try CanonicalJSON.encoder().encode(
                    HandshakeModelExtension(
                        sessionID: handshake.sessionID,
                        role: handshake.role,
                        senderID: handshake.sender.id,
                        model: senderModel
                    )
                )
                guard publicKey.isValidSignature(
                    modelSignature,
                    for: extensionData
                ) else {
                    throw SecureSessionError.invalidSignature
                }
                model = senderModel
            default:
                throw SecureSessionError.invalidHandshake
            }
            let disconnectSignalVersion: Int?
            switch (
                envelope.disconnectSignalVersion,
                envelope.disconnectSignalVersionSignature
            ) {
            case (nil, nil):
                disconnectSignalVersion = nil
            case let (.some(version), .some(signatureData)):
                guard let capabilitySignature = try? P256.Signing.ECDSASignature(
                          derRepresentation: signatureData
                      ) else {
                    throw SecureSessionError.invalidHandshake
                }
                let extensionData = try CanonicalJSON.encoder().encode(
                    HandshakeDisconnectExtension(
                        sessionID: handshake.sessionID,
                        role: handshake.role,
                        senderID: handshake.sender.id,
                        version: version
                    )
                )
                guard publicKey.isValidSignature(
                    capabilitySignature,
                    for: extensionData
                ) else {
                    throw SecureSessionError.invalidSignature
                }
                disconnectSignalVersion = version
            default:
                throw SecureSessionError.invalidHandshake
            }
            let authenticatedHandshake = SecureSessionHandshake(
                sessionID: handshake.sessionID,
                role: handshake.role,
                sender: handshake.sender,
                senderModel: model,
                disconnectSignalVersion: disconnectSignalVersion,
                ephemeralPublicKey: handshake.ephemeralPublicKey,
                nonce: handshake.nonce
            )
            return .handshake(authenticatedHandshake)
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
            return try LengthPrefixedFrameCodec.encode(
                payload,
                maximumPayloadLength: maximumFramePayloadLength
            )
        } catch {
            throw SecureSessionError.invalidFrame
        }
    }
}

public final class SecureSessionChannel {
    public static let maximumPlaintextLength = 32 * 1024
    public static let maximumSealedDataLength =
        maximumPlaintextLength + 12 + 16
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
        guard plaintext.count <= Self.maximumPlaintextLength else {
            throw SecureSessionError.invalidFrame
        }
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
        guard packet.sealedData.count <= Self.maximumSealedDataLength else {
            throw SecureSessionError.oversizedPacket
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
    case peerRequiresUpgrade
    case invalidIdentityName
    case unexpectedSequence
    case oversizedPacket
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
    let senderModel: String?
    let senderModelSignature: Data?
    let disconnectSignalVersion: Int?
    let disconnectSignalVersionSignature: Data?
    let packet: SecurePacket?
}

/// Signed separately from the legacy handshake so adding device metadata does
/// not change the bytes older peers verify or the transcript they derive.
private struct HandshakeModelExtension: Codable {
    let sessionID: UUID
    let role: SecureSessionRole
    let senderID: UUID
    let model: String
}

/// Signed separately from the legacy handshake so older releases can ignore
/// the capability fields while newer releases can safely decide whether an
/// encrypted user-disconnect signal is understood by the peer.
private struct HandshakeDisconnectExtension: Codable {
    let sessionID: UUID
    let role: SecureSessionRole
    let senderID: UUID
    let version: Int
}
