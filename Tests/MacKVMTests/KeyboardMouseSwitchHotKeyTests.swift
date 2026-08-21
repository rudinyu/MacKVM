import CoreGraphics
import XCTest
@testable import MacKVM

final class KeyboardMouseSwitchHotKeyTests: XCTestCase {
    func testMatchesDedicatedShortcut() {
        let flags: CGEventFlags = [
            .maskControl, .maskAlternate, .maskCommand
        ]

        XCTAssertTrue(
            KeyboardMouseSwitchHotKey.matches(
                keyCode: KeyboardMouseSwitchHotKey.keyCode,
                flags: flags
            )
        )
    }

    func testRejectsWrongKeyOrMissingModifier() {
        let flags: CGEventFlags = [
            .maskControl, .maskAlternate, .maskCommand
        ]

        XCTAssertFalse(
            KeyboardMouseSwitchHotKey.matches(
                keyCode: 53,
                flags: flags
            )
        )
        XCTAssertFalse(
            KeyboardMouseSwitchHotKey.matches(
                keyCode: KeyboardMouseSwitchHotKey.keyCode,
                flags: [.maskControl, .maskCommand]
            )
        )
    }

    func testOtherMonitorShortcutMatchesDedicatedOKey() {
        let flags: CGEventFlags = [
            .maskControl, .maskAlternate, .maskCommand
        ]

        XCTAssertTrue(
            OtherMonitorSwitchHotKey.matches(
                keyCode: OtherMonitorSwitchHotKey.keyCode,
                flags: flags
            )
        )
        XCTAssertFalse(
            OtherMonitorSwitchHotKey.matches(
                keyCode: KeyboardMouseSwitchHotKey.keyCode,
                flags: flags
            )
        )
    }

    func testOtherMonitorShortcutRequiresAllModifiers() {
        XCTAssertFalse(
            OtherMonitorSwitchHotKey.matches(
                keyCode: OtherMonitorSwitchHotKey.keyCode,
                flags: [.maskControl, .maskAlternate]
            )
        )
    }

    func testReservedModifierChordIsConsumedBeforeTriggerKey() {
        XCTAssertTrue(
            InputCaptureService.shouldSuppressReservedHotKeyModifierFlags([
                .maskControl, .maskAlternate, .maskCommand
            ])
        )
    }

    func testPartialModifierCombinationRemainsAvailableToRemoteMac() {
        XCTAssertFalse(
            InputCaptureService.shouldSuppressReservedHotKeyModifierFlags([
                .maskControl, .maskAlternate
            ])
        )
    }

    func testCarbonHotKeyLookupFailureDoesNotSelectAnAction() {
        XCTAssertNil(
            RegisteredHotKeyAction.resolve(
                parameterStatus: -50,
                id: 1
            )
        )
    }

    func testCarbonHotKeyIDsSelectOnlyTheirRegisteredAction() {
        XCTAssertEqual(
            RegisteredHotKeyAction.resolve(parameterStatus: noErr, id: 1),
            .switchControl
        )
        XCTAssertEqual(
            RegisteredHotKeyAction.resolve(parameterStatus: noErr, id: 2),
            .emergencyStop
        )
        XCTAssertEqual(
            RegisteredHotKeyAction.resolve(parameterStatus: noErr, id: 3),
            .monitorSwitch
        )
        XCTAssertNil(
            RegisteredHotKeyAction.resolve(parameterStatus: noErr, id: 99)
        )
    }
}
