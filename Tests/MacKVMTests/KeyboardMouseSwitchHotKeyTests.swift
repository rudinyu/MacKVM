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
}
