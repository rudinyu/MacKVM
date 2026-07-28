import Foundation

public enum RemoteInputKind: String, Codable, CaseIterable, Sendable {
    case keyDown
    case keyUp
    case flagsChanged
    case mouseMoved
    case leftMouseDown
    case leftMouseUp
    case leftMouseDragged
    case rightMouseDown
    case rightMouseUp
    case rightMouseDragged
    case otherMouseDown
    case otherMouseUp
    case otherMouseDragged
    case scroll
}

public struct NormalizedPoint: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct RemoteInputEvent: Codable, Equatable, Sendable {
    public let kind: RemoteInputKind
    public let keyCode: UInt16?
    public let modifierFlags: UInt64
    public let location: NormalizedPoint?
    public let buttonNumber: Int?
    public let clickCount: Int?
    public let scrollDeltaX: Double?
    public let scrollDeltaY: Double?

    public init(
        kind: RemoteInputKind,
        keyCode: UInt16? = nil,
        modifierFlags: UInt64 = 0,
        location: NormalizedPoint? = nil,
        buttonNumber: Int? = nil,
        clickCount: Int? = nil,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.location = location
        self.buttonNumber = buttonNumber
        self.clickCount = clickCount
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
    }

    public func validated() throws -> RemoteInputEvent {
        switch kind {
        case .keyDown, .keyUp, .flagsChanged:
            guard keyCode != nil,
                  location == nil,
                  buttonNumber == nil,
                  clickCount == nil,
                  scrollDeltaX == nil,
                  scrollDeltaY == nil else {
                throw RemoteInputError.invalidFields
            }

        case .mouseMoved:
            guard try validLocation(),
                  keyCode == nil,
                  buttonNumber == nil,
                  clickCount == nil,
                  scrollDeltaX == nil,
                  scrollDeltaY == nil else {
                throw RemoteInputError.invalidFields
            }

        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            guard try validPointer(buttonNumbers: 0...0) else {
                throw RemoteInputError.invalidFields
            }

        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            guard try validPointer(buttonNumbers: 1...1) else {
                throw RemoteInputError.invalidFields
            }

        case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            guard try validPointer(buttonNumbers: 2...31) else {
                throw RemoteInputError.invalidFields
            }

        case .scroll:
            guard location == nil,
                  keyCode == nil,
                  buttonNumber == nil,
                  clickCount == nil,
                  let scrollDeltaX,
                  let scrollDeltaY,
                  scrollDeltaX.isFinite,
                  scrollDeltaY.isFinite,
                  abs(scrollDeltaX) <= 10_000,
                  abs(scrollDeltaY) <= 10_000 else {
                throw RemoteInputError.invalidFields
            }
        }
        return self
    }

    private func validLocation() throws -> Bool {
        guard let location,
              location.x.isFinite,
              location.y.isFinite,
              (0..<1).contains(location.x),
              (0..<1).contains(location.y) else {
            throw RemoteInputError.invalidFields
        }
        return true
    }

    private func validPointer(
        buttonNumbers: ClosedRange<Int>
    ) throws -> Bool {
        guard try validLocation(),
              keyCode == nil,
              let buttonNumber,
              buttonNumbers.contains(buttonNumber),
              let clickCount,
              (0...255).contains(clickCount),
              scrollDeltaX == nil,
              scrollDeltaY == nil else {
            throw RemoteInputError.invalidFields
        }
        return true
    }
}

public enum RemoteInputError: Error, Equatable {
    case payloadTooLarge
    case invalidFields
}

public enum RemoteInputCodec {
    public static let maximumPayloadLength = 16_384

    public static func encode(_ event: RemoteInputEvent) throws -> Data {
        let validated = try event.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(validated)
        guard data.count <= maximumPayloadLength else {
            throw RemoteInputError.payloadTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> RemoteInputEvent {
        guard data.count <= maximumPayloadLength else {
            throw RemoteInputError.payloadTooLarge
        }
        return try JSONDecoder().decode(RemoteInputEvent.self, from: data)
            .validated()
    }
}
