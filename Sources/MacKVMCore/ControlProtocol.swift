import Foundation

public enum ControlMessageKind: String, Codable, Sendable {
    case requestControl
    case controlGranted
    case controlDenied
    case endControl
    case input
}

public struct ControlMessage: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let currentProtocolVersion =
        ControlProtocolCompatibility.currentVersion
    public static let minimumCompatibleProtocolVersion =
        ControlProtocolCompatibility.minimumCompatibleVersion

    public let version: Int
    public let kind: ControlMessageKind
    public let requestID: UUID?
    public let input: RemoteInputEvent?
    /// Optional negotiation fields are attached to control requests so an
    /// older peer can continue to decode the message while a newer peer can
    /// reject incompatible protocol or keyboard-layout combinations before
    /// granting input.
    public let protocolVersion: Int?
    public let minimumProtocolVersion: Int?
    public let keyboardLayoutIdentifier: String?

    public init(
        version: Int = currentVersion,
        kind: ControlMessageKind,
        requestID: UUID? = nil,
        input: RemoteInputEvent? = nil,
        protocolVersion: Int? = nil,
        minimumProtocolVersion: Int? = nil,
        keyboardLayoutIdentifier: String? = nil
    ) {
        self.version = version
        self.kind = kind
        self.requestID = requestID
        self.input = input
        self.protocolVersion = protocolVersion
        self.minimumProtocolVersion = minimumProtocolVersion
        self.keyboardLayoutIdentifier = keyboardLayoutIdentifier
    }

    public static func input(
        _ event: RemoteInputEvent,
        requestID: UUID
    ) -> ControlMessage {
        ControlMessage(
            kind: .input,
            requestID: requestID,
            input: event
        )
    }

    public static func requestControl(
        requestID: UUID,
        keyboardLayoutIdentifier: String? = nil
    ) -> ControlMessage {
        ControlMessage(
            kind: .requestControl,
            requestID: requestID,
            protocolVersion: currentProtocolVersion,
            minimumProtocolVersion: minimumCompatibleProtocolVersion,
            keyboardLayoutIdentifier: keyboardLayoutIdentifier
        )
    }

    public func validated() throws -> ControlMessage {
        guard version == Self.currentVersion else {
            throw ControlProtocolError.unsupportedVersion
        }
        switch kind {
        case .input:
            guard requestID != nil,
                  let input,
                  protocolVersion == nil,
                  minimumProtocolVersion == nil,
                  keyboardLayoutIdentifier == nil else {
                throw ControlProtocolError.invalidFields
            }
            _ = try input.validated()
        case .requestControl:
            guard requestID != nil,
                  input == nil,
                  validNegotiationFields else {
                throw ControlProtocolError.invalidFields
            }
        case .controlGranted, .controlDenied, .endControl:
            guard requestID != nil,
                  input == nil,
                  protocolVersion == nil,
                  minimumProtocolVersion == nil,
                  keyboardLayoutIdentifier == nil else {
                throw ControlProtocolError.invalidFields
            }
        }
        return self
    }

    private var validNegotiationFields: Bool {
        if let protocolVersion {
            guard (1...255).contains(protocolVersion) else { return false }
            let minimum = minimumProtocolVersion ?? protocolVersion
            guard (1...255).contains(minimum), minimum <= protocolVersion else {
                return false
            }
        } else if minimumProtocolVersion != nil {
            return false
        }
        guard let keyboardLayoutIdentifier else { return true }
        let trimmed = keyboardLayoutIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return !trimmed.isEmpty
            && trimmed.utf8.count <= 256
            && trimmed.unicodeScalars.allSatisfy {
                $0.value >= 0x20 && $0.value != 0x7F
            }
    }
}

/// A small version range is enough for control-message negotiation.  A
/// missing range is treated as the legacy v1 peer so upgrades remain
/// compatible with the released protocol.
public enum ControlProtocolCompatibility {
    public static let currentVersion = 1
    public static let minimumCompatibleVersion = 1

    public static func isCompatible(
        remoteVersion: Int?,
        remoteMinimumVersion: Int?
    ) -> Bool {
        let remoteCurrent = remoteVersion ?? 1
        let remoteMinimum = remoteMinimumVersion ?? remoteCurrent
        guard remoteMinimum >= 1,
              remoteMinimum <= remoteCurrent else {
            return false
        }
        return max(minimumCompatibleVersion, remoteMinimum)
            <= min(currentVersion, remoteCurrent)
    }
}

public enum ControlProtocolError: Error, Equatable {
    case payloadTooLarge
    case unsupportedVersion
    case invalidFields
}

public enum ControlMessageCodec {
    public static let maximumPayloadLength = 32_768

    public static func encode(_ message: ControlMessage) throws -> Data {
        let validated = try message.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(validated)
        guard data.count <= maximumPayloadLength else {
            throw ControlProtocolError.payloadTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> ControlMessage {
        guard data.count <= maximumPayloadLength else {
            throw ControlProtocolError.payloadTooLarge
        }
        return try JSONDecoder().decode(ControlMessage.self, from: data)
            .validated()
    }
}

public enum ControlSessionState: String, Equatable, Sendable {
    case idle
    case connected
    case suspended
    case controlling
    case disconnected
}

public enum ControlSessionAction: Equatable, Sendable {
    case transportConnected
    case requestControl
    case controlGranted
    case suspend
    case resume
    case stopControl
    case transportDisconnected
    case reset
}

public enum ControlStateError: Error, Equatable {
    case invalidTransition
}

public struct ControlSessionStateMachine: Sendable {
    public private(set) var state: ControlSessionState

    public init(state: ControlSessionState = .idle) {
        self.state = state
    }

    @discardableResult
    public mutating func handle(
        _ action: ControlSessionAction
    ) throws -> ControlSessionState {
        switch (state, action) {
        case (_, .transportConnected):
            state = .connected
        case (.connected, .requestControl):
            state = .suspended
        case (.suspended, .controlGranted):
            state = .controlling
        case (.controlling, .suspend):
            state = .suspended
        case (.suspended, .resume):
            state = .controlling
        case (.controlling, .stopControl),
             (.suspended, .stopControl):
            state = .connected
        case (_, .transportDisconnected):
            state = .disconnected
        case (_, .reset):
            state = .idle
        default:
            throw ControlStateError.invalidTransition
        }
        return state
    }
}
