import Foundation
import XCTest
@testable import MacKVMCore

final class RemoteInputProtocolTests: XCTestCase {
    func testKeyboardEventRoundTrips() throws {
        let event = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 36,
            modifierFlags: 1 << 20
        )

        XCTAssertEqual(
            try RemoteInputCodec.decode(RemoteInputCodec.encode(event)),
            event
        )
    }

    func testKeyboardEventCarriesLayoutIdentifier() throws {
        let event = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 12,
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )

        XCTAssertEqual(
            try RemoteInputCodec.decode(RemoteInputCodec.encode(event)),
            event
        )
    }

    func testKeyboardEventCarriesAutoRepeatState() throws {
        let event = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 12,
            isAutorepeat: true
        )

        XCTAssertEqual(
            try RemoteInputCodec.decode(RemoteInputCodec.encode(event)),
            event
        )
    }

    func testKeyUpRejectsAutoRepeatState() {
        let event = RemoteInputEvent(
            kind: .keyUp,
            keyCode: 12,
            isAutorepeat: true
        )

        XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testPointerEventRejectsKeyboardLayoutIdentifier() {
        let event = RemoteInputEvent(
            kind: .mouseMoved,
            location: NormalizedPoint(x: 0.2, y: 0.3),
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )

        XCTAssertThrowsError(try event.validated()) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testFlagsChangedRetainsExplicitModifierState() throws {
        let event = RemoteInputEvent(
            kind: .flagsChanged,
            keyCode: 56,
            isPressed: false,
            modifierFlags: 1 << 17
        )

        XCTAssertEqual(
            try RemoteInputCodec.decode(RemoteInputCodec.encode(event)),
            event
        )
    }

    func testRejectsUnknownModifierFlagBits() {
        let event = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 36,
            modifierFlags: 1 << 63
        )

        XCTAssertThrowsError(try event.validated()) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testAcceptsKnownDeviceModifierBitsForLegacyPeers() throws {
        let event = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 36,
            modifierFlags: (1 << 20) | 0x8
        )

        XCTAssertNoThrow(try event.validated())
        XCTAssertEqual(
            RemoteInputEvent.normalizedModifierFlags(event.modifierFlags),
            1 << 20
        )
    }

    func testAcceptsLegacyStatelessCapsLockFlag() throws {
        let event = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 57,
            modifierFlags: (1 << 24) | (1 << 16)
        )

        XCTAssertNoThrow(try event.validated())
        XCTAssertEqual(
            RemoteInputEvent.normalizedModifierFlags(event.modifierFlags),
            1 << 16
        )
    }

    func testRejectsModifierStateOnNonModifierEvents() {
        let event = RemoteInputEvent(
            kind: .mouseMoved,
            isPressed: true,
            location: NormalizedPoint(x: 0.25, y: 0.75)
        )

        XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testKeyEventsRejectExplicitModifierEdgeState() {
        for kind in [RemoteInputKind.keyDown, .keyUp] {
            let event = RemoteInputEvent(
                kind: kind,
                keyCode: 0,
                isPressed: true
            )
            XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
                XCTAssertEqual(error as? RemoteInputError, .invalidFields)
            }
        }
    }

    func testPointerEventRoundTrips() throws {
        let event = RemoteInputEvent(
            kind: .leftMouseDown,
            modifierFlags: 1 << 17,
            location: NormalizedPoint(x: 0.25, y: 0.75),
            buttonNumber: 0,
            clickCount: 2,
            pressure: 0.75
        )

        XCTAssertEqual(
            try RemoteInputCodec.decode(RemoteInputCodec.encode(event)),
            event
        )
    }

    func testPointerEventAllowsPlatformMultiClickCount() throws {
        let event = RemoteInputEvent(
            kind: .leftMouseDown,
            location: NormalizedPoint(x: 0.25, y: 0.75),
            buttonNumber: 0,
            clickCount: 4
        )

        XCTAssertEqual(
            try RemoteInputCodec.decode(RemoteInputCodec.encode(event)),
            event
        )
    }

    func testRejectsButtonNumberThatDoesNotMatchMouseEventKind() {
        let event = RemoteInputEvent(
            kind: .leftMouseDown,
            location: NormalizedPoint(x: 0.25, y: 0.75),
            buttonNumber: 5,
            clickCount: 1
        )

        XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testRejectsPressureOutsideThePlatformRange() {
        for pressure in [-0.01, 1.01, .infinity, -.infinity, .nan] {
            let event = RemoteInputEvent(
                kind: .leftMouseDown,
                location: NormalizedPoint(x: 0.25, y: 0.75),
                buttonNumber: 0,
                clickCount: 1,
                pressure: pressure
            )

            XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
                XCTAssertEqual(error as? RemoteInputError, .invalidFields)
            }
        }
    }

    func testMouseMovementCannotCarryPressure() {
        let event = RemoteInputEvent(
            kind: .mouseMoved,
            location: NormalizedPoint(x: 0.25, y: 0.75),
            pressure: 1
        )

        XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testRejectsOutOfBoundsPointerLocation() {
        let event = RemoteInputEvent(
            kind: .mouseMoved,
            location: NormalizedPoint(x: 1.01, y: 0.5)
        )

        XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testRejectsPointerLocationAtExclusiveUpperBound() {
        let event = RemoteInputEvent(
            kind: .mouseMoved,
            location: NormalizedPoint(x: 1, y: 0.5)
        )

        XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testRejectsFieldsThatDoNotBelongToEventKind() {
        let event = RemoteInputEvent(
            kind: .keyUp,
            keyCode: 12,
            scrollDeltaY: 1
        )

        XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testRejectsOversizedPayloadBeforeDecoding() {
        let data = Data(
            repeating: 0,
            count: RemoteInputCodec.maximumPayloadLength + 1
        )

        XCTAssertThrowsError(try RemoteInputCodec.decode(data)) { error in
            XCTAssertEqual(error as? RemoteInputError, .payloadTooLarge)
        }
    }

    func testScrollRejectsNonFiniteValues() {
        let event = RemoteInputEvent(
            kind: .scroll,
            scrollDeltaX: .infinity,
            scrollDeltaY: 1
        )

        XCTAssertThrowsError(try event.validated()) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testScrollRejectsPressure() {
        let event = RemoteInputEvent(
            kind: .scroll,
            pressure: 0.5,
            scrollDeltaX: 0,
            scrollDeltaY: 1
        )

        XCTAssertThrowsError(try event.validated()) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testScrollCarriesTrackpadPhases() throws {
        let event = RemoteInputEvent(
            kind: .scroll,
            scrollDeltaX: 0.375,
            scrollDeltaY: 12.125,
            scrollPhase: .changed,
            scrollEventUnit: .pixel
        )

        XCTAssertEqual(
            try RemoteInputCodec.decode(RemoteInputCodec.encode(event)),
            event
        )
    }

    func testScrollCarriesMomentumPhase() throws {
        let event = RemoteInputEvent(
            kind: .scroll,
            scrollDeltaX: 0,
            scrollDeltaY: 3,
            scrollMomentumPhase: .continue,
            scrollEventUnit: .pixel
        )

        XCTAssertEqual(
            try RemoteInputCodec.decode(RemoteInputCodec.encode(event)),
            event
        )
    }

    func testScrollCarriesLineUnit() throws {
        let event = RemoteInputEvent(
            kind: .scroll,
            scrollDeltaX: 0,
            scrollDeltaY: 1,
            scrollEventUnit: .line
        )

        XCTAssertEqual(
            try RemoteInputCodec.decode(RemoteInputCodec.encode(event)),
            event
        )
    }

    /// A wheel-only mouse and a peer built before this field existed both send
    /// no phase, so the absent-phase payload has to stay byte-identical.
    func testScrollWithoutPhasesOmitsTheFields() throws {
        let event = RemoteInputEvent(
            kind: .scroll,
            scrollDeltaX: 0,
            scrollDeltaY: 1
        )
        let encoded = try RemoteInputCodec.encode(event)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertFalse(json.contains("scrollPhase"))
        XCTAssertFalse(json.contains("scrollMomentumPhase"))
        XCTAssertFalse(json.contains("scrollEventUnit"))
        XCTAssertEqual(try RemoteInputCodec.decode(encoded), event)
    }

    func testLegacyScrollPayloadWithoutPhasesStillDecodes() throws {
        let legacy = Data(
            #"{"kind":"scroll","modifierFlags":0,"scrollDeltaX":0,"scrollDeltaY":5}"#
                .utf8
        )

        let decoded = try RemoteInputCodec.decode(legacy)

        XCTAssertNil(decoded.scrollPhase)
        XCTAssertNil(decoded.scrollMomentumPhase)
        XCTAssertNil(decoded.scrollEventUnit)
        XCTAssertEqual(decoded.scrollDeltaY, 5)
    }

    func testRejectsScrollPhaseOnNonScrollEvents() {
        let keyEvent = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 12,
            scrollPhase: .began,
            scrollEventUnit: .pixel
        )
        let pointerEvent = RemoteInputEvent(
            kind: .leftMouseDown,
            location: NormalizedPoint(x: 0.25, y: 0.75),
            buttonNumber: 0,
            clickCount: 1,
            scrollMomentumPhase: .begin
        )

        for event in [keyEvent, pointerEvent] {
            XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
                XCTAssertEqual(error as? RemoteInputError, .invalidFields)
            }
        }
    }

    func testRejectsUnknownScrollPhaseValue() {
        let unknownPhase = Data(
            #"{"kind":"scroll","modifierFlags":0,"scrollDeltaX":0,"scrollDeltaY":1,"scrollPhase":64}"#
                .utf8
        )

        XCTAssertThrowsError(try RemoteInputCodec.decode(unknownPhase))
    }

    func testRejectsUnknownScrollEventUnitValue() {
        let unknownUnit = Data(
            #"{"kind":"scroll","modifierFlags":0,"scrollDeltaX":0,"scrollDeltaY":1,"scrollEventUnit":2}"#
                .utf8
        )

        XCTAssertThrowsError(try RemoteInputCodec.decode(unknownUnit))
    }

    func testSystemDefinedEventRoundTrips() throws {
        let event = RemoteInputEvent(
            kind: .systemDefined,
            isPressed: true,
            modifierFlags: 0,
            mediaKey: .soundUp
        )

        XCTAssertEqual(
            try RemoteInputCodec.decode(RemoteInputCodec.encode(event)),
            event
        )
    }

    func testSystemDefinedEventRequiresMediaKeyAndPressedState() {
        let missingKey = RemoteInputEvent(
            kind: .systemDefined,
            isPressed: true
        )
        let missingPressedState = RemoteInputEvent(
            kind: .systemDefined,
            mediaKey: .mute
        )

        for event in [missingKey, missingPressedState] {
            XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
                XCTAssertEqual(error as? RemoteInputError, .invalidFields)
            }
        }
    }

    func testSystemDefinedEventRejectsUnrelatedFields() {
        let withLocation = RemoteInputEvent(
            kind: .systemDefined,
            isPressed: true,
            location: NormalizedPoint(x: 0.1, y: 0.1),
            mediaKey: .play
        )
        let withKeyCode = RemoteInputEvent(
            kind: .systemDefined,
            keyCode: 12,
            isPressed: true,
            mediaKey: .play
        )
        let withLayoutIdentifier = RemoteInputEvent(
            kind: .systemDefined,
            isPressed: true,
            mediaKey: .play,
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )

        for event in [withLocation, withKeyCode, withLayoutIdentifier] {
            XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
                XCTAssertEqual(error as? RemoteInputError, .invalidFields)
            }
        }
    }

    func testRejectsMediaKeyOnNonSystemDefinedEvents() {
        let event = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 12,
            mediaKey: .mute
        )

        XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testRejectsUnknownMediaKeyValue() {
        // 6 is the power key's NX code, deliberately excluded from MediaKey.
        let powerKey = Data(
            #"{"kind":"systemDefined","modifierFlags":0,"isPressed":true,"mediaKey":6}"#
                .utf8
        )

        XCTAssertThrowsError(try RemoteInputCodec.decode(powerKey))
    }

    func testKeyDownCarriesCharacter() throws {
        let event = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 0,
            character: "a"
        )

        XCTAssertEqual(
            try RemoteInputCodec.decode(RemoteInputCodec.encode(event)),
            event
        )
    }

    func testKeyUpRejectsCharacter() {
        let event = RemoteInputEvent(
            kind: .keyUp,
            keyCode: 0,
            character: "a"
        )

        XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testFlagsChangedRejectsCharacter() {
        let event = RemoteInputEvent(
            kind: .flagsChanged,
            keyCode: 56,
            character: "a"
        )

        XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }

    func testCharacterMustBeExactlyOneScalar() {
        let empty = RemoteInputEvent(kind: .keyDown, keyCode: 0, character: "")
        let multiple = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 0,
            character: "ab"
        )

        for event in [empty, multiple] {
            XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
                XCTAssertEqual(error as? RemoteInputError, .invalidFields)
            }
        }
    }

    func testCharacterRejectsControlCharacters() {
        let event = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 51,
            character: "\u{7F}"
        )

        XCTAssertThrowsError(try RemoteInputCodec.encode(event)) { error in
            XCTAssertEqual(error as? RemoteInputError, .invalidFields)
        }
    }
}
