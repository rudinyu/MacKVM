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

    func testTargetHotkeysUseDedicatedKeysAndRequiredModifiers() {
        let flags: CGEventFlags = [
            .maskControl, .maskAlternate, .maskCommand
        ]

        XCTAssertTrue(
            InputTargetHotKey.matches(
                keyCode: InputTargetHotKey.cycleKeyCode,
                flags: flags,
                expectedKeyCode: InputTargetHotKey.cycleKeyCode
            )
        )
        XCTAssertTrue(
            InputTargetHotKey.matches(
                keyCode: InputTargetHotKey.returnLocalKeyCode,
                flags: flags,
                expectedKeyCode: InputTargetHotKey.returnLocalKeyCode
            )
        )
        XCTAssertFalse(
            InputTargetHotKey.matches(
                keyCode: InputTargetHotKey.cycleKeyCode,
                flags: [.maskControl, .maskCommand],
                expectedKeyCode: InputTargetHotKey.cycleKeyCode
            )
        )
        XCTAssertEqual(InputTargetHotKey.oneBasedSlot(for: 18), 1)
        XCTAssertEqual(InputTargetHotKey.oneBasedSlot(for: 25), 9)
        XCTAssertNil(InputTargetHotKey.oneBasedSlot(for: 29))
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
        XCTAssertEqual(
            RegisteredHotKeyAction.resolve(parameterStatus: noErr, id: 4),
            .cycleTargets
        )
        XCTAssertEqual(
            RegisteredHotKeyAction.resolve(parameterStatus: noErr, id: 5),
            .returnLocally
        )
        XCTAssertEqual(
            RegisteredHotKeyAction.resolve(parameterStatus: noErr, id: 100),
            .selectTarget(1)
        )
        XCTAssertEqual(
            RegisteredHotKeyAction.resolve(parameterStatus: noErr, id: 108),
            .selectTarget(9)
        )
        XCTAssertNil(
            RegisteredHotKeyAction.resolve(parameterStatus: noErr, id: 99)
        )
    }
}
