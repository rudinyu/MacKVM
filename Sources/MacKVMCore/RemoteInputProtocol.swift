import Foundation

public enum RemoteInputKind: String, Codable, CaseIterable, Sendable {
    case keyDown
    case keyUp
    case flagsChanged
    case systemDefined
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

/// The macOS system-defined (NX) keys MacKVM is willing to forward. This enum
/// is the allowlist itself: an unlisted code fails to decode, so a peer cannot
/// ask the receiver to synthesize an arbitrary system key.
///
/// Three groups are deliberately excluded:
/// - the power key (6), because a remote peer must not be able to open the
///   shutdown dialog or sleep the receiving Mac;
/// - caps lock (4), which already travels as a `flagsChanged` edge and would
///   otherwise toggle twice;
/// - eject, num lock, help, and the legacy contrast/mirror keys, which have no
///   role in sharing a keyboard and mouse.
public enum MediaKey: Int, Codable, CaseIterable, Sendable {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case play = 16
    case next = 17
    case previous = 18
    case fast = 19
    case rewind = 20
    case illuminationUp = 21
    case illuminationDown = 22
    case illuminationToggle = 23
}

/// Mirrors `CGScrollPhase`. The platform's `none` value (0) is represented by
/// a missing field so a mouse wheel, which reports no phase at all, and a
/// legacy peer that never sends the field decode identically.
public enum ScrollPhase: Int, Codable, CaseIterable, Sendable {
    case began = 1
    case changed = 2
    case ended = 4
    case cancelled = 8
    case mayBegin = 128
}

/// Mirrors `CGMomentumScrollPhase`, the inertia that continues after a
/// trackpad flick is released. `none` (0) is likewise a missing field.
public enum ScrollMomentumPhase: Int, Codable, CaseIterable, Sendable {
    case begin = 1
    case `continue` = 2
    case end = 3
}

public struct RemoteInputEvent: Codable, Equatable, Sendable {
    public let kind: RemoteInputKind
    public let keyCode: UInt16?
    /// Explicit edge state for flagsChanged events. Older senders may omit it;
    /// receivers retain a conservative transition fallback for compatibility.
    public let isPressed: Bool?
    public let modifierFlags: UInt64
    public let location: NormalizedPoint?
    public let buttonNumber: Int?
    public let clickCount: Int?
    public let scrollDeltaX: Double?
    public let scrollDeltaY: Double?
    /// Trackpad scroll and momentum phases. Both stay optional: a legacy peer
    /// omits them, and a plain mouse wheel reports neither. Forwarding them
    /// lets the receiver reproduce macOS inertia instead of discrete steps.
    public let scrollPhase: ScrollPhase?
    public let scrollMomentumPhase: ScrollMomentumPhase?
    /// Media, brightness, and keyboard-illumination key for `systemDefined`
    /// events. It uses its own field rather than `keyCode` because NX key
    /// codes and virtual key codes are different namespaces that overlap: NX
    /// code 16 is Play, while virtual key code 16 is the letter Y.
    public let mediaKey: MediaKey?
    /// The character `keyCode` produces under the sender's own keyboard
    /// layout and current Shift/Option/Caps Lock state. It is attached only
    /// to `keyDown`, never `keyUp`: the receiver resolves a `keyDown` to a
    /// local key once and remembers that choice for the matching `keyUp`, so
    /// a modifier released mid-press cannot change which physical key gets
    /// released. It exists so a receiver on a different keyboard layout can
    /// find the local key that produces the same character instead of
    /// injecting a keycode that means something else there.
    public let character: String?
    /// Input-source identifier for keyboard events. It remains optional so a
    /// legacy peer can still send mouse input and older keyboard events.
    public let keyboardLayoutIdentifier: String?

    public init(
        kind: RemoteInputKind,
        keyCode: UInt16? = nil,
        isPressed: Bool? = nil,
        modifierFlags: UInt64 = 0,
        location: NormalizedPoint? = nil,
        buttonNumber: Int? = nil,
        clickCount: Int? = nil,
        scrollDeltaX: Double? = nil,
        scrollDeltaY: Double? = nil,
        scrollPhase: ScrollPhase? = nil,
        scrollMomentumPhase: ScrollMomentumPhase? = nil,
        mediaKey: MediaKey? = nil,
        character: String? = nil,
        keyboardLayoutIdentifier: String? = nil
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.isPressed = isPressed
        self.modifierFlags = modifierFlags
        self.location = location
        self.buttonNumber = buttonNumber
        self.clickCount = clickCount
        self.scrollDeltaX = scrollDeltaX
        self.scrollDeltaY = scrollDeltaY
        self.scrollPhase = scrollPhase
        self.scrollMomentumPhase = scrollMomentumPhase
        self.mediaKey = mediaKey
        self.character = character
        self.keyboardLayoutIdentifier = keyboardLayoutIdentifier
    }

    public func validated() throws -> RemoteInputEvent {
        guard validModifierFlags else {
            throw RemoteInputError.invalidFields
        }
        switch kind {
        case .keyDown:
            guard keyCode != nil,
                  isPressed == nil,
                  location == nil,
                  buttonNumber == nil,
                  clickCount == nil,
                  scrollDeltaX == nil,
                  scrollDeltaY == nil,
                  hasNoScrollPhase,
                  mediaKey == nil,
                  validCharacter,
                  validKeyboardLayoutIdentifier else {
                throw RemoteInputError.invalidFields
            }

        case .keyUp:
            // The receiver resolves a layout remap once, at keyDown, and
            // reuses it here by the physical keyCode alone. A character on
            // keyUp would be redundant at best and, if it ever disagreed
            // with the keyDown's, a source of a keyUp targeting a different
            // local key than the one that was pressed.
            guard keyCode != nil,
                  isPressed == nil,
                  location == nil,
                  buttonNumber == nil,
                  clickCount == nil,
                  scrollDeltaX == nil,
                  scrollDeltaY == nil,
                  hasNoScrollPhase,
                  mediaKey == nil,
                  character == nil,
                  validKeyboardLayoutIdentifier else {
                throw RemoteInputError.invalidFields
            }

        case .flagsChanged:
            guard keyCode != nil,
                  location == nil,
                  buttonNumber == nil,
                  clickCount == nil,
                  scrollDeltaX == nil,
                  scrollDeltaY == nil,
                  hasNoScrollPhase,
                  mediaKey == nil,
                  character == nil,
                  validKeyboardLayoutIdentifier else {
                throw RemoteInputError.invalidFields
            }

        case .systemDefined:
            // An explicit pressed state is required: unlike a virtual key,
            // there is no separate keyUp event kind to fall back on, and the
            // receiver must never guess an edge for a key it will inject.
            guard mediaKey != nil,
                  isPressed != nil,
                  keyCode == nil,
                  location == nil,
                  buttonNumber == nil,
                  clickCount == nil,
                  scrollDeltaX == nil,
                  scrollDeltaY == nil,
                  hasNoScrollPhase,
                  character == nil,
                  // Media keys are layout independent, so they must not carry
                  // a layout identifier that would strand them behind the
                  // receiver's layout-mismatch check.
                  keyboardLayoutIdentifier == nil else {
                throw RemoteInputError.invalidFields
            }

        case .mouseMoved:
            guard try validLocation(),
                  keyCode == nil,
                  isPressed == nil,
                  buttonNumber == nil,
                  clickCount == nil,
                  scrollDeltaX == nil,
                  scrollDeltaY == nil,
                  hasNoScrollPhase,
                  mediaKey == nil,
                  character == nil,
                  keyboardLayoutIdentifier == nil else {
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
                  isPressed == nil,
                  buttonNumber == nil,
                  clickCount == nil,
                  mediaKey == nil,
                  character == nil,
                  keyboardLayoutIdentifier == nil,
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

    /// Scroll phases describe a scroll stream and must never ride along with a
    /// key or pointer event, where the receiver would set them on an injected
    /// CGEvent that has no scroll semantics.
    private var hasNoScrollPhase: Bool {
        scrollPhase == nil && scrollMomentumPhase == nil
    }

    /// The public CGEvent modifier bits MacKVM can safely reproduce. Keep the
    /// wire format strict: unknown/reserved bits must not be copied into a
    /// receiver's CGEventFlags value by an authenticated peer.
    private var validModifierFlags: Bool {
        modifierFlags & ~Self.validModifierFlagsMask == 0
    }

    /// Returns only the device-independent flags that can be reconstructed on
    /// another Mac. Capture uses this before encoding, and injection uses it
    /// again so legacy peers cannot pass device-specific bits through.
    public static func normalizedModifierFlags(_ flags: UInt64) -> UInt64 {
        flags & publicModifierFlagsMask
    }

    private static let publicModifierFlagsMask: UInt64 =
        0x0000_0000_00FF_0100

    // Older macOS event taps can include these known device-dependent bits.
    // They are accepted for wire compatibility, then removed by
    // normalizedModifierFlags before a CGEvent is injected.
    private static let deviceModifierFlagsMask: UInt64 =
        0x0000_0000_0100_20FF

    private static let validModifierFlagsMask: UInt64 =
        publicModifierFlagsMask | deviceModifierFlagsMask

    /// Exactly one Unicode scalar, excluding control characters. UCKeyTranslate
    /// with dead keys disabled never produces a composed grapheme cluster, so
    /// anything wider is unexpected input rather than a legitimate character.
    private var validCharacter: Bool {
        guard let character else { return true }
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else {
            return false
        }
        return scalar.value >= 0x20 && scalar.value != 0x7F
    }

    private var validKeyboardLayoutIdentifier: Bool {
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
              isPressed == nil,
              let buttonNumber,
              buttonNumbers.contains(buttonNumber),
              let clickCount,
              (0...255).contains(clickCount),
              keyboardLayoutIdentifier == nil,
              scrollDeltaX == nil,
              scrollDeltaY == nil,
              hasNoScrollPhase,
              mediaKey == nil,
              character == nil else {
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
