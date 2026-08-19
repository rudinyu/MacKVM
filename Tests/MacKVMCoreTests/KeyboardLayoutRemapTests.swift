import XCTest
@testable import MacKVMCore

/// Simulates a keyboard layout with a small explicit character table instead
/// of calling into UCKeyTranslate, so the reverse-map logic is verifiable
/// without real hardware or a specific host keyboard layout.
private struct StubLayout: UnicodeLayoutCharacterProviding {
    struct Entry: Hashable {
        let keyCode: UInt16
        let shift: Bool
        let option: Bool
        let capsLock: Bool
    }

    let characters: [Entry: String]

    func character(
        forKeyCode keyCode: UInt16,
        shift: Bool,
        option: Bool,
        capsLock: Bool
    ) -> String? {
        characters[
            Entry(
                keyCode: keyCode,
                shift: shift,
                option: option,
                capsLock: capsLock
            )
        ]
    }
}

final class KeyboardLayoutRemapTests: XCTestCase {
    func testFindsUnmodifiedKey() {
        let layout = StubLayout(characters: [
            .init(keyCode: 0, shift: false, option: false, capsLock: false): "a"
        ])
        let map = KeyboardLayoutReverseMap(translator: layout)

        XCTAssertEqual(
            map.target(for: "a"),
            RemappedKeyTarget(
                keyCode: 0,
                shift: false,
                option: false,
                capsLock: false
            )
        )
    }

    func testFindsShiftedKey() {
        let layout = StubLayout(characters: [
            .init(keyCode: 18, shift: false, option: false, capsLock: false): "1",
            .init(keyCode: 18, shift: true, option: false, capsLock: false): "!"
        ])
        let map = KeyboardLayoutReverseMap(translator: layout)

        XCTAssertEqual(
            map.target(for: "!"),
            RemappedKeyTarget(
                keyCode: 18,
                shift: true,
                option: false,
                capsLock: false
            )
        )
    }

    func testFindsOptionModifiedKey() {
        let layout = StubLayout(characters: [
            .init(keyCode: 33, shift: false, option: false, capsLock: false): "[",
            .init(keyCode: 33, shift: false, option: true, capsLock: false): "\u{201C}"
        ])
        let map = KeyboardLayoutReverseMap(translator: layout)

        XCTAssertEqual(
            map.target(for: "\u{201C}"),
            RemappedKeyTarget(
                keyCode: 33,
                shift: false,
                option: true,
                capsLock: false
            )
        )
    }

    func testCapsLockProducesUppercaseLetter() {
        let layout = StubLayout(characters: [
            .init(keyCode: 0, shift: false, option: false, capsLock: false): "a",
            .init(keyCode: 0, shift: false, option: false, capsLock: true): "A"
        ])
        let map = KeyboardLayoutReverseMap(translator: layout)

        XCTAssertEqual(
            map.target(for: "A"),
            RemappedKeyTarget(
                keyCode: 0,
                shift: false,
                option: false,
                capsLock: true
            )
        )
    }

    /// When two keys can produce the same character, the combination
    /// requiring fewer modifiers wins, matching the declared preference
    /// order rather than whichever key happened to be enumerated last.
    func testPrefersFewerModifiersOnCollision() {
        let layout = StubLayout(characters: [
            .init(keyCode: 0, shift: false, option: false, capsLock: false): "x",
            .init(keyCode: 1, shift: true, option: false, capsLock: false): "x"
        ])
        let map = KeyboardLayoutReverseMap(translator: layout)

        XCTAssertEqual(map.target(for: "x")?.keyCode, 0)
    }

    func testUnproducibleCharacterReturnsNil() {
        let layout = StubLayout(characters: [
            .init(keyCode: 0, shift: false, option: false, capsLock: false): "a"
        ])
        let map = KeyboardLayoutReverseMap(translator: layout)

        XCTAssertNil(map.target(for: "€"))
    }

    func testOnlyRemappableKeyCodesAreConsulted() {
        // keyCode 36 is Return, deliberately outside RemappableKeyCodes.all.
        let layout = StubLayout(characters: [
            .init(keyCode: 36, shift: false, option: false, capsLock: false): "q"
        ])
        let map = KeyboardLayoutReverseMap(translator: layout)

        XCTAssertNil(map.target(for: "q"))
    }

    func testRemappableKeyCodesExcludeNonCharacterKeys() {
        let nonCharacterKeys: Set<UInt16> = [
            36, // Return
            48, // Tab
            49, // Space
            51, // Delete
            53, // Escape
            54, 55, 56, 57, 58, 59, 60, 61, 62, // modifiers and caps lock
            123, 124, 125, 126 // arrow keys
        ]

        XCTAssertTrue(RemappableKeyCodes.all.isDisjoint(with: nonCharacterKeys))
    }
}
