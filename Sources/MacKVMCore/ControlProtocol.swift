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

    public let version: Int
    public let kind: ControlMessageKind
    public let requestID: UUID?
    public let input: RemoteInputEvent?

    public init(
        version: Int = currentVersion,
        kind: ControlMessageKind,
        requestID: UUID? = nil,
        input: RemoteInputEvent? = nil
    ) {
        self.version = version
        self.kind = kind
        self.requestID = requestID
        self.input = input
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

    public func validated() throws -> ControlMessage {
        guard version == Self.currentVersion else {
            throw ControlProtocolError.unsupportedVersion
        }
        switch kind {
        case .input:
            guard requestID != nil, let input else {
                throw ControlProtocolError.invalidFields
            }
            _ = try input.validated()
        case .requestControl, .controlGranted, .controlDenied, .endControl:
            guard requestID != nil, input == nil else {
                throw ControlProtocolError.invalidFields
            }
        }
        return self
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
