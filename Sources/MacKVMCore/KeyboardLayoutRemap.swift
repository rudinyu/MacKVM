import Foundation

/// The physical key codes eligible for cross-layout character remapping:
/// letters, digits, and the standard ANSI/ISO symbol keys. Every other
/// keycode (arrows, Return, Tab, Delete, Escape, Space, function keys, the
/// keypad, and every modifier) occupies the same physical position and
/// produces the same meaning on every macOS keyboard layout, so remapping
/// would be pointless at best and a source of new bugs at worst.
public enum RemappableKeyCodes {
    public static let all: Set<UInt16> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
        20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37,
        38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 50
    ]
}

/// Abstracts the platform call (`UCKeyTranslate` on macOS) that turns a
/// physical key plus a modifier combination into the character a keyboard
/// layout produces for it. Kept as a protocol so `KeyboardLayoutReverseMap`'s
/// lookup-table logic is testable without real keyboard layout data.
public protocol UnicodeLayoutCharacterProviding {
    func character(
        forKeyCode keyCode: UInt16,
        shift: Bool,
        option: Bool,
        capsLock: Bool
    ) -> String?
}

/// The physical key and modifier combination that produces a given character
/// on one keyboard layout.
public struct RemappedKeyTarget: Equatable, Sendable {
    public let keyCode: UInt16
    public let shift: Bool
    public let option: Bool
    public let capsLock: Bool

    public init(keyCode: UInt16, shift: Bool, option: Bool, capsLock: Bool) {
        self.keyCode = keyCode
        self.shift = shift
        self.option = option
        self.capsLock = capsLock
    }
}

/// A character-to-key lookup table for one keyboard layout, built once by
/// exhaustively translating every remappable key under every Shift/Option/Caps
/// Lock combination. Building is `O(key count × 8)`, cheap enough to redo
/// whenever the local layout changes.
public struct KeyboardLayoutReverseMap {
    private let table: [String: RemappedKeyTarget]

    /// Modifier combinations in preference order: unmodified first, then
    /// progressively more modifiers, so the simplest key wins when a layout
    /// happens to produce the same character more than one way.
    private static let modifierCombinations:
        [(shift: Bool, option: Bool, capsLock: Bool)] = [
        (false, false, false),
        (true, false, false),
        (false, false, true),
        (false, true, false),
        (true, false, true),
        (true, true, false),
        (false, true, true),
        (true, true, true)
    ]

    public init(translator: any UnicodeLayoutCharacterProviding) {
        var table: [String: RemappedKeyTarget] = [:]
        for keyCode in RemappableKeyCodes.all.sorted() {
            for combination in Self.modifierCombinations {
                guard let character = translator.character(
                    forKeyCode: keyCode,
                    shift: combination.shift,
                    option: combination.option,
                    capsLock: combination.capsLock
                ), table[character] == nil else {
                    continue
                }
                table[character] = RemappedKeyTarget(
                    keyCode: keyCode,
                    shift: combination.shift,
                    option: combination.option,
                    capsLock: combination.capsLock
                )
            }
        }
        self.table = table
    }

    public func target(for character: String) -> RemappedKeyTarget? {
        table[character]
    }
}
