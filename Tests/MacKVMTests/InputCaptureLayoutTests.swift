import CoreGraphics
import MacKVMCore
import XCTest
@testable import MacKVM

private struct StaleKeyboardLayoutProvider: KeyboardLayoutProviding {
    func currentIdentifier() -> String? { nil }
    func currentReverseMap() -> KeyboardLayoutReverseMap? { nil }
}

final class InputCaptureLayoutTests: XCTestCase {
    private func event(keyCode: UInt16, keyDown: Bool) throws -> CGEvent {
        try XCTUnwrap(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(keyCode),
                keyDown: keyDown
            )
        )
    }

    func testStaleLayoutDropsRemappableKeyPressAndMatchingRelease() throws {
        let capture = InputCaptureService(
            keyboardLayoutProvider: StaleKeyboardLayoutProvider()
        )
        let keyDown = try event(keyCode: 6, keyDown: true)
        let keyRepeat = try event(keyCode: 6, keyDown: true)
        let keyUp = try event(keyCode: 6, keyDown: false)

        XCTAssertNil(
            capture.makeRemoteEvent(type: .keyDown, event: keyDown)
        )
        XCTAssertNil(
            capture.makeRemoteEvent(type: .keyDown, event: keyRepeat)
        )
        XCTAssertNil(
            capture.makeRemoteEvent(type: .keyUp, event: keyUp)
        )
    }

    func testStaleLayoutDoesNotDropNonRemappableKey() throws {
        let capture = InputCaptureService(
            keyboardLayoutProvider: StaleKeyboardLayoutProvider()
        )
        let event = try event(keyCode: 123, keyDown: true)

        XCTAssertNotNil(
            capture.makeRemoteEvent(type: .keyDown, event: event)
        )
    }
}
