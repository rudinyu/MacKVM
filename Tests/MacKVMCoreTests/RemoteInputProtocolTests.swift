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

    func testPointerEventRoundTrips() throws {
        let event = RemoteInputEvent(
            kind: .leftMouseDown,
            modifierFlags: 1 << 17,
            location: NormalizedPoint(x: 0.25, y: 0.75),
            buttonNumber: 0,
            clickCount: 2
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
}
