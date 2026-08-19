import CoreGraphics
import MacKVMCore
import XCTest
@testable import MacKVM

/// A deterministic stand-in for a real keyboard layout, so these tests do
/// not depend on whatever layout happens to be active on the machine
/// running them.
private struct FakeLayout: UnicodeLayoutCharacterProviding {
    struct Entry: Hashable {
        let keyCode: UInt16
        let shift: Bool
        let option: Bool
        let capsLock: Bool
    }

    let table: [Entry: String]

    func character(
        forKeyCode keyCode: UInt16,
        shift: Bool,
        option: Bool,
        capsLock: Bool
    ) -> String? {
        table[
            Entry(keyCode: keyCode, shift: shift, option: option, capsLock: capsLock)
        ]
    }
}

private struct FakeKeyboardLayoutProvider: KeyboardLayoutProviding {
    let identifier: String?
    let reverseMap: KeyboardLayoutReverseMap?

    func currentIdentifier() -> String? { identifier }
    func currentReverseMap() -> KeyboardLayoutReverseMap? { reverseMap }
}

/// Covers `RemoteInputSink`'s cross-layout key-remap resolution — the logic
/// two review passes found five real bugs in (auto-repeat retargeting a held
/// key, Caps Lock/Option corrupting a Command-modified shortcut, wrong-key
/// targeting on a layout where letter positions swap, and more). A fake
/// `KeyboardLayoutProviding` stands in for Carbon so these are deterministic
/// regardless of the test machine's actual keyboard layout.
final class RemoteInputSinkKeyRemapTests: XCTestCase {
    /// Models the German QWERTZ vs. US ANSI Y/Z swap: keyCode 6 is "Z" on
    /// US and "Y" on German; keyCode 16 is "Y" on US and "Z" on German.
    /// Only the receiver's ("German") side is modeled, since that's the
    /// only side `computeKeyInjectionTarget` ever looks up against.
    private func germanLayoutProvider() -> FakeKeyboardLayoutProvider {
        let translator = FakeLayout(table: [
            .init(keyCode: 16, shift: false, option: false, capsLock: false): "z",
            .init(keyCode: 16, shift: true, option: false, capsLock: false): "Z",
            .init(keyCode: 6, shift: false, option: false, capsLock: false): "y"
        ])
        return FakeKeyboardLayoutProvider(
            identifier: "com.apple.keylayout.German",
            reverseMap: KeyboardLayoutReverseMap(translator: translator)
        )
    }

    func testMatchingLayoutUsesIdentityWithoutConsultingCharacter() {
        let sink = RemoteInputSink(
            keyboardLayoutProvider: FakeKeyboardLayoutProvider(
                identifier: "com.apple.keylayout.US",
                reverseMap: KeyboardLayoutReverseMap(
                    translator: FakeLayout(table: [:])
                )
            )
        )
        let input = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 6,
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )

        XCTAssertEqual(
            sink.resolveKeyInjectionTarget(for: input, remoteKeyCode: 6),
            .identity(keyCode: 6)
        )
    }

    func testNonRemappableKeyCodeIsAlwaysIdentity() {
        let sink = RemoteInputSink(keyboardLayoutProvider: germanLayoutProvider())
        // 123 is the left-arrow key, outside RemappableKeyCodes.all.
        let input = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 123,
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )

        XCTAssertEqual(
            sink.resolveKeyInjectionTarget(for: input, remoteKeyCode: 123),
            .identity(keyCode: 123)
        )
    }

    func testMissingCharacterIsUnmappable() {
        let sink = RemoteInputSink(keyboardLayoutProvider: germanLayoutProvider())
        let input = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 6,
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )

        XCTAssertNil(sink.resolveKeyInjectionTarget(for: input, remoteKeyCode: 6))
    }

    func testUnavailableLocalLayoutIsUnmappable() {
        let sink = RemoteInputSink(
            keyboardLayoutProvider: FakeKeyboardLayoutProvider(
                identifier: nil,
                reverseMap: nil
            )
        )
        let input = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 6,
            character: "z",
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )

        XCTAssertNil(sink.resolveKeyInjectionTarget(for: input, remoteKeyCode: 6))
    }

    func testUnavailableLocalLayoutIsTransientForInjectionPath() {
        let sink = RemoteInputSink(
            keyboardLayoutProvider: FakeKeyboardLayoutProvider(
                identifier: nil,
                reverseMap: nil
            )
        )
        let input = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 6,
            character: "z",
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )

        XCTAssertThrowsError(
            try sink.resolveKeyInjectionTargetOrThrow(
                for: input,
                remoteKeyCode: 6
            )
        ) { error in
            XCTAssertEqual(error as? RemoteInputSinkError, .layoutUnavailable)
        }
    }

    func testCharacterWithNoLocalEquivalentIsUnmappable() {
        let sink = RemoteInputSink(keyboardLayoutProvider: germanLayoutProvider())
        let input = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 6,
            character: "€",
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )

        XCTAssertNil(sink.resolveKeyInjectionTarget(for: input, remoteKeyCode: 6))
    }

    /// The core regression: Command-Z from a US sender must land on the
    /// German receiver's key that actually produces "z" (keyCode 16), not
    /// the sender's raw keyCode 6, which is "y" on German.
    func testCommandHeldKeyRemapsKeycodeButPreservesOriginalFlags() {
        let sink = RemoteInputSink(keyboardLayoutProvider: germanLayoutProvider())
        let cmdFlags = UInt64(CGEventFlags.maskCommand.rawValue)
        let input = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 6,
            modifierFlags: cmdFlags,
            character: "z",
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )

        let target = sink.resolveKeyInjectionTarget(for: input, remoteKeyCode: 6)

        XCTAssertEqual(
            target,
            .remapped(
                RemappedKeyTarget(
                    keyCode: 16,
                    shift: false,
                    option: false,
                    capsLock: false
                ),
                applyModifiers: false
            )
        )
        XCTAssertEqual(
            sink.eventFlags(for: input, remap: target),
            CGEventFlags(rawValue: cmdFlags)
        )
    }

    /// Caps Lock must not change which key Command-Z is remapped to, nor
    /// leak into the injected flags as a Shift bit (which would turn
    /// Command-Z into Command-Shift-Z).
    func testCommandHeldKeyIgnoresSendersCapsLockState() {
        let sink = RemoteInputSink(keyboardLayoutProvider: germanLayoutProvider())
        let flags = UInt64(
            CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlphaShift.rawValue
        )
        let input = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 6,
            modifierFlags: flags,
            character: "z",
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )

        let target = sink.resolveKeyInjectionTarget(for: input, remoteKeyCode: 6)
        let injectedFlags = sink.eventFlags(for: input, remap: target)

        XCTAssertEqual(target?.keyCode, 16)
        XCTAssertFalse(injectedFlags.contains(.maskShift))
        XCTAssertTrue(injectedFlags.contains(.maskAlphaShift))
        XCTAssertTrue(injectedFlags.contains(.maskCommand))
    }

    /// Plain typing (no Command/Control) is the opposite of the shortcut
    /// case: the target's Shift/Option/Caps Lock recipe must be applied so
    /// the injected key reproduces the sender's exact character.
    func testPlainTypingAppliesTheTargetsModifierRecipe() {
        let sink = RemoteInputSink(keyboardLayoutProvider: germanLayoutProvider())
        let input = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 6,
            character: "Z",
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )

        let target = sink.resolveKeyInjectionTarget(for: input, remoteKeyCode: 6)

        XCTAssertEqual(
            target,
            .remapped(
                RemappedKeyTarget(
                    keyCode: 16,
                    shift: true,
                    option: false,
                    capsLock: false
                ),
                applyModifiers: true
            )
        )
        XCTAssertTrue(
            sink.eventFlags(for: input, remap: target).contains(.maskShift)
        )
    }

    /// The auto-repeat regression: a held key resends keyDown repeatedly
    /// before its keyUp. A repeat must reuse the first resolution rather
    /// than recomputing one, even when the repeat's own fields would
    /// resolve differently, or the live press could be retargeted mid-hold
    /// and strand the originally-injected key.
    func testAutoRepeatReusesTheFirstResolution() {
        let sink = RemoteInputSink(keyboardLayoutProvider: germanLayoutProvider())
        let firstKeyDown = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 6,
            character: "z",
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )
        let firstTarget = sink.resolveKeyInjectionTarget(
            for: firstKeyDown,
            remoteKeyCode: 6
        )

        // A repeat arrives with Shift now also held and a different
        // character than the original keyDown.
        let repeatKeyDown = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 6,
            modifierFlags: UInt64(CGEventFlags.maskShift.rawValue),
            character: "Z",
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )
        let repeatTarget = sink.resolveKeyInjectionTarget(
            for: repeatKeyDown,
            remoteKeyCode: 6
        )

        XCTAssertEqual(firstTarget, repeatTarget)
    }

    /// The matching keyUp must resolve to the same target the keyDown did,
    /// and release the tracked entry so a later, unrelated keyUp for the
    /// same physical key does not reuse a stale resolution.
    func testKeyUpReusesTheStoredTargetThenReleasesIt() {
        let sink = RemoteInputSink(keyboardLayoutProvider: germanLayoutProvider())
        let keyDown = RemoteInputEvent(
            kind: .keyDown,
            keyCode: 6,
            character: "z",
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )
        let downTarget = sink.resolveKeyInjectionTarget(
            for: keyDown,
            remoteKeyCode: 6
        )

        let keyUp = RemoteInputEvent(
            kind: .keyUp,
            keyCode: 6,
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )
        let upTarget = sink.resolveKeyInjectionTarget(for: keyUp, remoteKeyCode: 6)

        XCTAssertEqual(downTarget, upTarget)

        // Nothing was tracked for this keyUp (the matching keyDown already
        // consumed and cleared it above), so it falls back to identity
        // rather than guessing at a target.
        let strayKeyUp = sink.resolveKeyInjectionTarget(for: keyUp, remoteKeyCode: 6)
        XCTAssertEqual(strayKeyUp, .identity(keyCode: 6))
    }
}
