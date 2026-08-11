import Carbon.HIToolbox
import Foundation
import MacKVMCore

/// The macOS keyboard-layout input source, read fresh on every call rather
/// than cached, since the user can switch layouts or input methods at any
/// time and this must always reflect what is active right now.
enum CarbonKeyboardLayout {
    /// The physical keyboard layout identifier, independent of any input
    /// method (Zhuyin, Pinyin, ...) layered on top of it.
    ///
    /// `TISCopyCurrentKeyboardLayoutInputSource` is deliberately used instead
    /// of `TISCopyCurrentKeyboardInputSource`: the latter returns the active
    /// input method's own identifier (for example
    /// `com.apple.inputmethod.TCIM.Zhuyin`) while the underlying hardware
    /// layout it types through is unchanged. Comparing input-method
    /// identifiers between two Macs would treat switching an IME on or off as
    /// a layout change and end remote control for no real reason; comparing
    /// the underlying keyboard layout does not.
    static func currentIdentifier() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?
            .takeRetainedValue(),
              let idPointer = TISGetInputSourceProperty(
                  source,
                  kTISPropertyInputSourceID
              ) else {
            return nil
        }
        let identifier = Unmanaged<CFString>
            .fromOpaque(idPointer)
            .takeUnretainedValue() as String
        let trimmed = identifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 256,
              trimmed.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value != 0x7F
              }) else {
            return nil
        }
        return trimmed
    }

    /// A translator backed by the layout identified by `currentIdentifier()`,
    /// for building a `KeyboardLayoutReverseMap` against what is active now.
    static func currentTranslator() -> UnicodeLayoutCharacterProviding? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?
            .takeRetainedValue() else {
            return nil
        }
        return CarbonUnicodeLayoutTranslator(inputSource: source)
    }
}

/// Wraps one `TISInputSource`'s Unicode layout data and exposes it through
/// `UnicodeLayoutCharacterProviding`, isolating every unsafe-pointer and
/// Carbon-modifier-bit detail behind the same small interface
/// `KeyboardLayoutReverseMap` already builds against in tests.
private struct CarbonUnicodeLayoutTranslator: UnicodeLayoutCharacterProviding {
    let inputSource: TISInputSource

    func character(
        forKeyCode keyCode: UInt16,
        shift: Bool,
        option: Bool,
        capsLock: Bool
    ) -> String? {
        guard let layoutDataPointer = TISGetInputSourceProperty(
            inputSource,
            kTISPropertyUnicodeKeyLayoutData
        ) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>
            .fromOpaque(layoutDataPointer)
            .takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }

        var carbonModifiers: UInt32 = 0
        if shift { carbonModifiers |= UInt32(shiftKey) }
        if option { carbonModifiers |= UInt32(optionKey) }
        if capsLock { carbonModifiers |= UInt32(alphaLock) }
        // UCKeyTranslate expects the classic EventRecord modifier field,
        // shifted right 8 bits, not the raw shiftKey/optionKey/alphaLock
        // constants directly.
        let keyModifiers = (carbonModifiers >> 8) & 0xFF

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength = 0
        let status = bytes.withMemoryRebound(
            to: UCKeyboardLayout.self,
            capacity: 1
        ) { layout in
            UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDown),
                keyModifiers,
                // The keyboard-type parameter only matters for the legacy
                // KCHR resource format. `kTISPropertyUnicodeKeyLayoutData`
                // is always the modern UCHR format, which ignores it, so a
                // fixed 0 avoids depending on the low-memory-globals API
                // that would otherwise supply it.
                0,
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &actualLength,
                &chars
            )
        }
        guard status == noErr, actualLength > 0 else {
            return nil
        }
        return String(utf16CodeUnits: chars, count: actualLength)
    }
}
