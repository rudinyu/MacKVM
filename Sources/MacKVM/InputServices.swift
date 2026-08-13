import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import MacKVMCore

enum KeyboardLayoutIdentifier {
    /// Delegates to the physical-layout lookup in `CarbonKeyboardLayout`.
    /// Switching an input method (for example toggling Zhuyin on and off)
    /// does not change this value, since it identifies the hardware layout
    /// beneath the input method rather than the input method itself.
    static func current() -> String? {
        CarbonKeyboardLayout.currentIdentifier()
    }
}

private enum InjectedEventMarker {
    static let value: Int64 = 0x4D_4B_56_4D
}

/// Media, brightness, and illumination keys are delivered as `NSSystemDefined`
/// events, which `CGEventType` has no case for. The tap mask and the dispatch
/// below therefore both work from the raw event type, and the payload is read
/// through `NSEvent`, the only API that exposes `data1`.
private enum SystemDefinedEvent {
    /// `NSEvent.EventType.systemDefined`.
    static let cgEventTypeRawValue: UInt32 = 14
    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`, the media/brightness key subtype.
    static let auxControlSubtype: Int16 = 8
    private static let keyDownState = 0x0A
    private static let keyUpState = 0x0B

    /// Reads a media key from a captured event. Any subtype, key code, or key
    /// state outside the supported set returns nil and is simply not
    /// forwarded, which also keeps unrelated system events off the wire.
    static func decode(_ event: CGEvent) -> (key: MediaKey, isPressed: Bool)? {
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == auxControlSubtype else {
            return nil
        }
        let data1 = nsEvent.data1
        guard let key = MediaKey(
            rawValue: Int((data1 & 0xFFFF_0000) >> 16)
        ) else {
            return nil
        }
        switch Int((data1 & 0x0000_FF00) >> 8) {
        case keyDownState:
            return (key, true)
        case keyUpState:
            return (key, false)
        default:
            return nil
        }
    }

    static func makeEvent(
        key: MediaKey,
        isPressed: Bool,
        flags: CGEventFlags
    ) -> CGEvent? {
        let keyState = isPressed ? keyDownState : keyUpState
        let data1 = (key.rawValue << 16) | (keyState << 8)
        return NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            // Modifiers are preserved because macOS uses them: Shift-Option
            // with a volume key performs a quarter-step adjustment.
            modifierFlags: NSEvent.ModifierFlags(
                rawValue: UInt(flags.rawValue)
            ),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: auxControlSubtype,
            data1: data1,
            data2: -1
        )?.cgEvent
    }
}

private enum VirtualKeyCode {
    static let commandLeft: UInt16 = 54
    static let commandRight: UInt16 = 55
    static let shiftLeft: UInt16 = 56
    static let capsLock: UInt16 = 57
    static let optionLeft: UInt16 = 58
    static let controlLeft: UInt16 = 59
    static let shiftRight: UInt16 = 60
    static let optionRight: UInt16 = 61
    static let controlRight: UInt16 = 62
}

struct ModifierFlagProjection {
    typealias Group = (flags: CGEventFlags, keyCodes: Set<UInt16>)

    static func projectedFlags(
        reportedFlags: CGEventFlags,
        keyCode: UInt16,
        isPressed: Bool?,
        pressedKeyCodes: Set<UInt16>
    ) -> CGEventFlags {
        var flags = reportedFlags
        guard let group = group(for: keyCode) else { return flags }
        var nextPressedKeys = pressedKeyCodes
        let nextState = isPressed ?? !pressedKeyCodes.contains(keyCode)
        if nextState {
            nextPressedKeys.insert(keyCode)
        } else {
            nextPressedKeys.remove(keyCode)
        }
        flags.remove(group.flags)
        if !group.keyCodes.isDisjoint(with: nextPressedKeys) {
            flags.insert(group.flags)
        }
        return flags
    }

    static func aggregateFlags(
        for keyCodes: Set<UInt16>
    ) -> CGEventFlags {
        var flags: CGEventFlags = []
        for group in groups
            where !group.keyCodes.isDisjoint(with: keyCodes) {
            flags.insert(group.flags)
        }
        return flags
    }

    static func releaseFlags(
        preservingLocalKeyCodes localKeyCodes: Set<UInt16>,
        remainingRemoteKeyCodes: Set<UInt16>
    ) -> CGEventFlags {
        var flags = aggregateFlags(for: localKeyCodes)
        flags.formUnion(aggregateFlags(for: remainingRemoteKeyCodes))
        return flags
    }

    static var modifierKeyCodes: Set<UInt16> {
        Set(groups.flatMap(\.keyCodes))
    }

    static func group(for keyCode: UInt16) -> Group? {
        groups.first { $0.keyCodes.contains(keyCode) }
    }

    private static let groups: [Group] = {
        [
            (.maskShift, [VirtualKeyCode.shiftLeft, VirtualKeyCode.shiftRight]),
            (.maskControl, [VirtualKeyCode.controlLeft, VirtualKeyCode.controlRight]),
            (.maskAlternate, [VirtualKeyCode.optionLeft, VirtualKeyCode.optionRight]),
            (.maskCommand, [VirtualKeyCode.commandLeft, VirtualKeyCode.commandRight]),
            (.maskAlphaShift, [VirtualKeyCode.capsLock])
        ]
    }()

}

private struct CapsLockStateTracker {
    private var lastState: Bool?

    mutating func edge(for state: Bool) -> Bool? {
        guard lastState != state else { return nil }
        lastState = state
        return state
    }

    mutating func observe(_ state: Bool) {
        lastState = state
    }

    mutating func reset() {
        lastState = nil
    }
}

struct CapsLockCapturePolicy {
    private var stateTracker = CapsLockStateTracker()

    mutating func nextState(from flags: CGEventFlags) -> Bool? {
        stateTracker.edge(for: flags.contains(.maskAlphaShift))
    }

    mutating func reset() {
        stateTracker.reset()
    }
}

struct CapsLockRemoteInputPolicy {
    private var stateTracker = CapsLockStateTracker()

    mutating func keyDown(
        explicitState: Bool?,
        modifierFlags: UInt64
    ) -> Bool? {
        let reportedState = CGEventFlags(rawValue: modifierFlags)
            .contains(.maskAlphaShift)
        if let explicitState {
            stateTracker.observe(explicitState)
            return explicitState
        }
        return stateTracker.edge(for: reportedState)
    }

    mutating func reset() {
        stateTracker.reset()
    }
}

final class InputCaptureService: ObservableObject, ControlInputCapture {
    @Published private(set) var hasInputMonitoringPermission: Bool
    @Published private(set) var isCapturing = false
    @Published private(set) var status = "Input capture stopped"

    var onEvent: ((RemoteInputEvent) -> Void)?
    var onEmergencyStop: (() -> Void)?

    var keyboardLayoutIdentifier: String? {
        KeyboardLayoutIdentifier.current()
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suppressesLocalEvents = false
    private var capsLockCapturePolicy = CapsLockCapturePolicy()

    init() {
        hasInputMonitoringPermission = CGPreflightListenEventAccess()
    }

    func refreshPermission() {
        hasInputMonitoringPermission = CGPreflightListenEventAccess()
    }

    func requestPermission() {
        hasInputMonitoringPermission = CGRequestListenEventAccess()
        status = hasInputMonitoringPermission
            ? "Input Monitoring permission granted"
            : "Enable Input Monitoring in System Settings, then return to MacKVM"
    }

    func startCapture(suppressingLocalEvents: Bool = false) {
        refreshPermission()
        guard hasInputMonitoringPermission else {
            status = "Input Monitoring permission is required"
            return
        }
        guard eventTap == nil else { return }
        capsLockCapturePolicy.reset()

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: suppressingLocalEvents ? .defaultTap : .listenOnly,
            eventsOfInterest: Self.eventMask,
            callback: inputEventTapCallback,
            userInfo: userInfo
        ) else {
            status = "Could not create the input event tap"
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        suppressesLocalEvents = suppressingLocalEvents
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isCapturing = true
        status = "Forwarding keyboard and mouse events"
    }

    func stopCapture() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        suppressesLocalEvents = false
        capsLockCapturePolicy.reset()
        isCapturing = false
        status = "Input capture stopped"
    }

    fileprivate func capture(
        type: CGEventType,
        event: CGEvent
    ) -> Bool {
        guard event.getIntegerValueField(.eventSourceUserData)
                != InjectedEventMarker.value else {
            return false
        }
        if isEmergencyShortcut(type: type, event: event) {
            if type == .keyDown,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.onEmergencyStop?()
                }
            }
            return true
        }
        if type.rawValue == SystemDefinedEvent.cgEventTypeRawValue {
            guard let (key, isPressed) = SystemDefinedEvent.decode(event) else {
                // An unrecognized system-defined event (a subtype or key
                // outside the allowlist) is dropped rather than forwarded,
                // and is not treated as consumed local input.
                return false
            }
            onEvent?(
                RemoteInputEvent(
                    kind: .systemDefined,
                    isPressed: isPressed,
                    modifierFlags: event.flags.rawValue,
                    mediaKey: key
                )
            )
            return suppressesLocalEvents
        }
        guard let remoteEvent = makeRemoteEvent(type: type, event: event) else {
            // A duplicate Caps Lock flagsChanged edge is intentionally not
            // forwarded, but it must still be consumed while local input is
            // suppressed or it would toggle the controlling Mac locally.
            return suppressesLocalEvents
                && type == .flagsChanged
                && event.getIntegerValueField(
                    .keyboardEventKeycode
                ) == Int64(VirtualKeyCode.capsLock)
        }
        onEvent?(remoteEvent)
        return suppressesLocalEvents
    }

    private func isEmergencyShortcut(
        type: CGEventType,
        event: CGEvent
    ) -> Bool {
        guard type == .keyDown || type == .keyUp else { return false }
        let required: CGEventFlags = [
            .maskControl, .maskAlternate, .maskCommand
        ]
        return event.getIntegerValueField(.keyboardEventKeycode) == 53
            && event.flags.intersection(required) == required
    }

    private func makeRemoteEvent(
        type: CGEventType,
        event: CGEvent
    ) -> RemoteInputEvent? {
        let flags = event.flags.rawValue
        switch type {
        case .keyDown:
            return keyboardEvent(.keyDown, event: event, flags: flags)
        case .keyUp:
            return keyboardEvent(.keyUp, event: event, flags: flags)
        case .flagsChanged:
            return keyboardEvent(.flagsChanged, event: event, flags: flags)
        case .mouseMoved:
            return pointerEvent(.mouseMoved, event: event, flags: flags)
        case .leftMouseDown:
            return pointerEvent(.leftMouseDown, event: event, flags: flags)
        case .leftMouseUp:
            return pointerEvent(.leftMouseUp, event: event, flags: flags)
        case .leftMouseDragged:
            return pointerEvent(.leftMouseDragged, event: event, flags: flags)
        case .rightMouseDown:
            return pointerEvent(.rightMouseDown, event: event, flags: flags)
        case .rightMouseUp:
            return pointerEvent(.rightMouseUp, event: event, flags: flags)
        case .rightMouseDragged:
            return pointerEvent(.rightMouseDragged, event: event, flags: flags)
        case .otherMouseDown:
            return pointerEvent(.otherMouseDown, event: event, flags: flags)
        case .otherMouseUp:
            return pointerEvent(.otherMouseUp, event: event, flags: flags)
        case .otherMouseDragged:
            return pointerEvent(.otherMouseDragged, event: event, flags: flags)
        case .scrollWheel:
            // A phase value of 0 means "no phase" on this platform, and the
            // failable initializers map it to nil. A mouse wheel therefore
            // keeps producing exactly the payload it produced before.
            return RemoteInputEvent(
                kind: .scroll,
                modifierFlags: flags,
                scrollDeltaX: event.getDoubleValueField(
                    .scrollWheelEventPointDeltaAxis2
                ),
                scrollDeltaY: event.getDoubleValueField(
                    .scrollWheelEventPointDeltaAxis1
                ),
                scrollPhase: ScrollPhase(
                    rawValue: Int(
                        event.getIntegerValueField(.scrollWheelEventScrollPhase)
                    )
                ),
                scrollMomentumPhase: ScrollMomentumPhase(
                    rawValue: Int(
                        event.getIntegerValueField(
                            .scrollWheelEventMomentumPhase
                        )
                    )
                )
            )
        case .tapDisabledByTimeout:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return nil
        case .tapDisabledByUserInput:
            DispatchQueue.main.async { [weak self] in
                self?.onEmergencyStop?()
            }
            return nil
        default:
            return nil
        }
    }

    private func keyboardEvent(
        _ kind: RemoteInputKind,
        event: CGEvent,
        flags: UInt64
    ) -> RemoteInputEvent? {
        let keyCode = UInt16(
            event.getIntegerValueField(.keyboardEventKeycode)
        )
        let isPressed: Bool?
        if kind != .flagsChanged {
            isPressed = nil
        } else if keyCode == VirtualKeyCode.capsLock {
            // Caps Lock is a toggle and macOS commonly emits two identical
            // flagsChanged events for one physical press. Forward only the
            // state edge so the receiver cannot toggle twice.
            guard let nextState = capsLockCapturePolicy.nextState(
                from: event.flags
            ) else {
                return nil
            }
            isPressed = nextState
        } else {
            isPressed = CGEventSource.keyState(
                .combinedSessionState,
                key: CGKeyCode(keyCode)
            )
        }
        // Only keyDown carries a character, and only for keys whose meaning
        // actually depends on the layout; see RemoteInputEvent.character.
        let character: String?
        if kind == .keyDown, RemappableKeyCodes.all.contains(keyCode) {
            // Command/Control select an application shortcut by logical key,
            // not by the character the key types with its current
            // modifiers, so the unmodified base character is sent instead —
            // the receiver looks up the same key regardless of whether Caps
            // Lock or Shift happens to be on, and applies the sender's
            // actual flags (including a real Shift, which selects a
            // different shortcut such as Redo instead of Undo) unchanged.
            let isShortcut = event.flags.contains(.maskCommand)
                || event.flags.contains(.maskControl)
            character = CarbonKeyboardLayout.currentTranslator()?.character(
                forKeyCode: keyCode,
                shift: !isShortcut && event.flags.contains(.maskShift),
                option: !isShortcut && event.flags.contains(.maskAlternate),
                capsLock: !isShortcut && event.flags.contains(.maskAlphaShift)
            )
        } else {
            character = nil
        }
        return RemoteInputEvent(
            kind: kind,
            keyCode: keyCode,
            isPressed: isPressed,
            modifierFlags: flags,
            character: character,
            keyboardLayoutIdentifier: keyboardLayoutIdentifier
        )
    }

    private func pointerEvent(
        _ kind: RemoteInputKind,
        event: CGEvent,
        flags: UInt64
    ) -> RemoteInputEvent? {
        guard let location = MainDisplayCoordinateSpace.normalizeClamped(
            event.location
        ) else {
            return nil
        }
        if kind == .mouseMoved {
            return RemoteInputEvent(
                kind: kind,
                modifierFlags: flags,
                location: location
            )
        }
        return RemoteInputEvent(
            kind: kind,
            modifierFlags: flags,
            location: location,
            buttonNumber: Int(
                event.getIntegerValueField(.mouseEventButtonNumber)
            ),
            clickCount: min(
                255,
                max(
                    0,
                    Int(event.getIntegerValueField(.mouseEventClickState))
                )
            )
        )
    }

    private static let eventMask: CGEventMask = {
        let eventTypes: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .mouseMoved,
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
        // NSSystemDefined (media/brightness keys) has no CGEventType case, so
        // its bit is added from the raw event-type number directly.
        return mask
            | (CGEventMask(1) << SystemDefinedEvent.cgEventTypeRawValue)
    }()
}

/// Where a received keyDown/keyUp should actually be injected. `.identity`
/// covers the overwhelming common case (matching layouts, or a key outside
/// `RemappableKeyCodes.all`): inject the sender's own keyCode unchanged,
/// exactly as before this feature existed. `.remapped` carries the local key
/// a `KeyboardLayoutReverseMap` lookup found for the sender's character.
///
/// `applyModifiers` distinguishes what the lookup was *for*. For plain
/// typing it is true: `RemappedKeyTarget`'s Shift/Option/Caps Lock recipe
/// must be applied so the injected key reproduces the sender's exact
/// character. For a Command/Control-held key it is false: only the keycode
/// came from the lookup (using the character the key produces with no
/// modifiers, so a Caps Lock or Shift the sender happened to be holding
/// cannot change which key was found), and the sender's original flags —
/// including its own Shift, which selects a different shortcut such as Redo
/// instead of Undo — are injected completely unchanged. Remapping only the
/// keycode, never the flags, is what keeps Command-Z landing on the local
/// key that actually produces "z" on a layout where Y and Z are swapped,
/// without also being able to turn Command-C into Command-Shift-C because
/// the sender's Caps Lock happened to be on.
///
/// Internal rather than private: this is the logic two review passes found
/// five real bugs in (auto-repeat retargeting a held key, Caps Lock/Option
/// corrupting a shortcut, wrong-key targeting on swapped layouts, and more),
/// so it needs to be reachable from `@testable import MacKVM`, the same way
/// `ModifierFlagProjection` above already is.
enum KeyInjectionTarget: Equatable {
    case identity(keyCode: UInt16)
    case remapped(RemappedKeyTarget, applyModifiers: Bool)

    var keyCode: UInt16 {
        switch self {
        case .identity(let keyCode):
            return keyCode
        case .remapped(let target, _):
            return target.keyCode
        }
    }
}

enum RemoteInputSinkError: Error, Equatable {
    /// A remappable key arrived under a differing keyboard layout with no
    /// local key producing the same character.
    case unmappableKey
}

final class RemoteInputSink: ObservableObject, ControlInputSink {
    @Published private(set) var hasAccessibilityPermission: Bool
    @Published private(set) var status = "Remote input ready"

    var onControlFailure: ((ControlInputFailure) -> Void)?

    private let queue = DispatchQueue(label: "app.mackvm.input-injection")
    // Keep injected modifier state in Quartz's private source table. The
    // HID table queried during teardown then represents physical local keys,
    // rather than echoing the remote flags we are about to release.
    private let eventSource = CGEventSource(stateID: .privateState)
    private var hasPublishedInputActivity = false
    private var isAcceptingRemoteInput = false
    private var pressedKeyCodes: Set<UInt16> = []
    private var pressedMouseButtons: Set<Int> = []
    private var capsLockRemoteInputPolicy = CapsLockRemoteInputPolicy()
    // Rebuilt only when the local layout identifier changes; building it
    // enumerates every remappable key, so it must not happen per keystroke.
    private var reverseMapLayoutIdentifier: String?
    private var reverseMap: KeyboardLayoutReverseMap?
    // Resolved once at keyDown, by the sender's physical keyCode, and reused
    // as-is at the matching keyUp. This guarantees a press and its release
    // always target the same local key even if a modifier changes, or the
    // reverse map is rebuilt, while the key is held.
    private var activeKeyRemap: [UInt16: KeyInjectionTarget] = [:]
    private let inputAdmission = BoundedAdmissionGate(
        // Remote input opens only after Accessibility is confirmed and the
        // serial injection queue has entered the active-control generation.
        capacity: BoundedAdmissionGate.defaultCapacity
    )
    private let keyboardLayoutProvider: any KeyboardLayoutProviding

    init(
        keyboardLayoutProvider: any KeyboardLayoutProviding =
            CarbonKeyboardLayoutProvider()
    ) {
        self.keyboardLayoutProvider = keyboardLayoutProvider
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    func refreshPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    func requestPermission() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(options)
        status = hasAccessibilityPermission
            ? "Accessibility permission granted"
            : "Enable Accessibility in System Settings, then return to MacKVM"
    }

    /// Marks the sink ready to receive remote input before invoking completion.
    /// The completion always runs on the main queue, after the serial injection
    /// queue has established the accepting state.
    func beginRemoteControl(
        completion: @escaping (Bool) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            guard AXIsProcessTrusted() else {
                invalidateInputAdmission()
                publish(
                    permission: false,
                    status: "Accessibility permission is required"
                )
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            isAcceptingRemoteInput = true
            beginInputAdmission()
            capsLockRemoteInputPolicy.reset()
            hasPublishedInputActivity = false
            publish(status: "Remote control granted")
            DispatchQueue.main.async {
                completion(true)
            }
        }
    }

    /// Stops accepting input and releases held keys/buttons before completion.
    /// The completion always runs on the main queue.
    func endRemoteControl(
        completion: @escaping () -> Void
    ) {
        // Invalidate before enqueueing teardown so a receive call racing with
        // the user's stop action cannot add more work ahead of key release.
        invalidateInputAdmission()
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            isAcceptingRemoteInput = false
            capsLockRemoteInputPolicy.reset()
            releaseAllInputsOnQueue()
            hasPublishedInputActivity = false
            publish(status: "Remote control ended")
            DispatchQueue.main.async(execute: completion)
        }
    }

    func receive(_ input: RemoteInputEvent) {
        let admission = inputAdmission.reserve()
        guard admission.accepted else {
            if admission.shouldSignalFailure {
                DispatchQueue.main.async { [weak self] in
                    self?.onControlFailure?(.queueOverloaded)
                }
            }
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            defer { inputAdmission.release(admission) }
            guard inputAdmission.isCurrent(admission),
                  isAcceptingRemoteInput else { return }
            guard AXIsProcessTrusted() else {
                isAcceptingRemoteInput = false
                invalidateInputAdmission()
                releaseAllInputsOnQueue()
                publish(
                    permission: false,
                    status: "Accessibility permission is required"
                )
                DispatchQueue.main.async { [weak self] in
                    self?.onControlFailure?(.accessibilityPermission)
                }
                return
            }
            do {
                let validatedInput = try input.validated()
                try inject(validatedInput)
            } catch RemoteInputSinkError.unmappableKey {
                // A differing keyboard layout is no longer fatal by itself
                // (see resolveKeyInjectionTarget); this only fires once a
                // specific key turns out to have no equivalent on this
                // layout, which the roadmap's remap design accepts as the
                // fallback rather than silently dropping one keystroke.
                isAcceptingRemoteInput = false
                invalidateInputAdmission()
                releaseAllInputsOnQueue()
                publish(
                    status: "Remote control ended: keyboard layout changed"
                )
                DispatchQueue.main.async { [weak self] in
                    self?.onControlFailure?(.keyboardLayoutMismatch)
                }
            } catch {
                publish(status: "Rejected invalid remote input")
            }
        }
    }

    private func beginInputAdmission() {
        inputAdmission.begin()
    }

    private func invalidateInputAdmission() {
        inputAdmission.invalidate()
    }

    private func inject(_ input: RemoteInputEvent) throws {
        guard let input = inputWithInferredCapsLockState(input) else {
            return
        }
        let event: CGEvent?
        var keyInjectionTarget: KeyInjectionTarget?
        switch input.kind {
        case .keyDown, .keyUp:
            guard let remoteKeyCode = input.keyCode else {
                throw RemoteInputError.invalidFields
            }
            guard let target = resolveKeyInjectionTarget(
                for: input,
                remoteKeyCode: remoteKeyCode
            ) else {
                throw RemoteInputSinkError.unmappableKey
            }
            keyInjectionTarget = target
            let keyDown = input.kind == .keyDown
            event = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: CGKeyCode(target.keyCode),
                keyDown: keyDown
            )

        case .flagsChanged:
            guard let keyCode = input.keyCode else {
                throw RemoteInputError.invalidFields
            }
            let keyDown = keyDownState(for: input, keyCode: keyCode)
            event = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: CGKeyCode(keyCode),
                keyDown: keyDown
            )
            event?.type = .flagsChanged

        case .systemDefined:
            guard let mediaKey = input.mediaKey,
                  let isPressed = input.isPressed else {
                throw RemoteInputError.invalidFields
            }
            event = SystemDefinedEvent.makeEvent(
                key: mediaKey,
                isPressed: isPressed,
                flags: CGEventFlags(rawValue: input.modifierFlags)
            )

        case .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .rightMouseUp, .rightMouseDragged,
             .otherMouseDown, .otherMouseUp, .otherMouseDragged:
            guard let location = input.location,
                  let point = MainDisplayCoordinateSpace.denormalize(location),
                  let mouseMapping = mouseMapping(for: input) else {
                throw RemoteInputError.invalidFields
            }
            event = CGEvent(
                mouseEventSource: eventSource,
                mouseType: mouseMapping.type,
                mouseCursorPosition: point,
                mouseButton: mouseMapping.button
            )
            if let clickCount = input.clickCount {
                event?.setIntegerValueField(
                    .mouseEventClickState,
                    value: Int64(clickCount)
                )
            }

        case .scroll:
            guard let deltaX = input.scrollDeltaX,
                  let deltaY = input.scrollDeltaY else {
                throw RemoteInputError.invalidFields
            }
            event = CGEvent(
                scrollWheelEvent2Source: eventSource,
                units: .pixel,
                wheelCount: 2,
                wheel1: clampedWheelValue(deltaY),
                wheel2: clampedWheelValue(deltaX),
                wheel3: 0
            )
            // Restore the trackpad phases so the receiver reproduces macOS
            // inertia. Omitted phases leave the platform default of 0, which
            // is what a mouse wheel and a legacy peer both mean.
            if let scrollPhase = input.scrollPhase {
                event?.setIntegerValueField(
                    .scrollWheelEventScrollPhase,
                    value: Int64(scrollPhase.rawValue)
                )
            }
            if let scrollMomentumPhase = input.scrollMomentumPhase {
                event?.setIntegerValueField(
                    .scrollWheelEventMomentumPhase,
                    value: Int64(scrollMomentumPhase.rawValue)
                )
            }
        }

        guard let event else {
            throw RemoteInputError.invalidFields
        }
        event.flags = eventFlags(for: input, remap: keyInjectionTarget)
        event.setIntegerValueField(
            .eventSourceUserData,
            value: InjectedEventMarker.value
        )
        event.post(tap: .cghidEventTap)
        trackPressedState(input, injectedKeyCode: keyInjectionTarget?.keyCode)
        if !hasPublishedInputActivity {
            hasPublishedInputActivity = true
            publish(status: "Remote input active")
        }
    }

    /// flagsChanged is an edge event, and the aggregate modifier mask cannot
    /// distinguish left/right variants, so this uses the tracked state
    /// supplied by the sender when available. keyDown/keyUp never call this:
    /// their pressed state is simply which of the two kinds arrived.
    private func keyDownState(
        for input: RemoteInputEvent,
        keyCode: UInt16
    ) -> Bool {
        input.isPressed ?? !pressedKeyCodes.contains(keyCode)
    }

    /// Chooses where a keyDown/keyUp should actually be injected. Returns nil
    /// only when the sender's key is remappable, the layouts genuinely
    /// differ, and this layout has no key that produces the same character —
    /// the one case `inject` treats as fatal.
    func resolveKeyInjectionTarget(
        for input: RemoteInputEvent,
        remoteKeyCode: UInt16
    ) -> KeyInjectionTarget? {
        if input.kind == .keyUp {
            // Reusing the keyDown's resolution, rather than recomputing it,
            // is what guarantees a press and its release always target the
            // same local key regardless of modifier or layout changes in
            // between.
            return activeKeyRemap.removeValue(forKey: remoteKeyCode)
                ?? .identity(keyCode: remoteKeyCode)
        }
        // A key held down auto-repeats as further keyDown events for the
        // same physical key before its keyUp arrives. Reusing the first
        // resolution for every repeat — rather than recomputing and
        // overwriting it — keeps the whole press pinned to one local key
        // even if a modifier changes mid-hold; recomputing per repeat could
        // retarget a live press to a different local key and leave the
        // original one stuck down, since only one target per remote keyCode
        // is tracked.
        if let existing = activeKeyRemap[remoteKeyCode] {
            return existing
        }
        let target = computeKeyInjectionTarget(
            for: input,
            remoteKeyCode: remoteKeyCode
        )
        if let target {
            activeKeyRemap[remoteKeyCode] = target
        }
        return target
    }

    func computeKeyInjectionTarget(
        for input: RemoteInputEvent,
        remoteKeyCode: UInt16
    ) -> KeyInjectionTarget? {
        guard let remoteLayout = input.keyboardLayoutIdentifier,
              let localLayout = keyboardLayoutProvider.currentIdentifier(),
              remoteLayout != localLayout,
              RemappableKeyCodes.all.contains(remoteKeyCode) else {
            return .identity(keyCode: remoteKeyCode)
        }
        guard let character = input.character else {
            // The sender could not translate this key on its own layout
            // (for example, an ISO key with no glyph there); there is
            // nothing to look up on this one either.
            return nil
        }
        refreshReverseMapIfNeeded(for: localLayout)
        guard let target = reverseMap?.target(for: character) else {
            return nil
        }
        let modifierFlags = CGEventFlags(rawValue: input.modifierFlags)
        let isShortcut = modifierFlags.contains(.maskCommand)
            || modifierFlags.contains(.maskControl)
        return .remapped(target, applyModifiers: !isShortcut)
    }

    func refreshReverseMapIfNeeded(for localLayout: String) {
        guard reverseMapLayoutIdentifier != localLayout else { return }
        guard let map = keyboardLayoutProvider.currentReverseMap() else {
            reverseMap = nil
            reverseMapLayoutIdentifier = nil
            return
        }
        reverseMap = map
        reverseMapLayoutIdentifier = localLayout
    }

    private func inputWithInferredCapsLockState(
        _ input: RemoteInputEvent
    ) -> RemoteInputEvent? {
        guard input.kind == .flagsChanged,
              input.keyCode == VirtualKeyCode.capsLock else {
            return input
        }
        // Explicit edge states are already de-duplicated by the sender's
        // CapsLockCapturePolicy. This receiver policy only re-derives edges
        // for legacy messages that omit isPressed.
        guard let capsLockKeyDown = capsLockRemoteInputPolicy.keyDown(
            explicitState: input.isPressed,
            modifierFlags: input.modifierFlags
        ) else {
            return nil
        }
        guard input.isPressed == nil else { return input }
        return RemoteInputEvent(
            kind: input.kind,
            keyCode: input.keyCode,
            isPressed: capsLockKeyDown,
            modifierFlags: input.modifierFlags,
            location: input.location,
            buttonNumber: input.buttonNumber,
            clickCount: input.clickCount,
            scrollDeltaX: input.scrollDeltaX,
            scrollDeltaY: input.scrollDeltaY,
            keyboardLayoutIdentifier: input.keyboardLayoutIdentifier
        )
    }

    /// `injectedKeyCode` is the key actually posted to the receiver's HID
    /// stack, which is the sender's `keyCode` unchanged unless a layout
    /// remap chose a different local key. Teardown releases whatever this
    /// records, so tracking anything else here would leave the real injected
    /// key stuck down after control ends.
    private func trackPressedState(
        _ input: RemoteInputEvent,
        injectedKeyCode: UInt16? = nil
    ) {
        switch input.kind {
        case .keyDown:
            if let keyCode = injectedKeyCode ?? input.keyCode {
                pressedKeyCodes.insert(keyCode)
            }
        case .keyUp:
            if let keyCode = injectedKeyCode ?? input.keyCode {
                pressedKeyCodes.remove(keyCode)
            }
        case .flagsChanged:
            if let keyCode = input.keyCode {
                let isPressed = input.isPressed
                    ?? !pressedKeyCodes.contains(keyCode)
                if isPressed {
                    pressedKeyCodes.insert(keyCode)
                } else {
                    pressedKeyCodes.remove(keyCode)
                }
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if let buttonNumber = input.buttonNumber {
                pressedMouseButtons.insert(buttonNumber)
            }
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            if let buttonNumber = input.buttonNumber {
                pressedMouseButtons.remove(buttonNumber)
            }
        default:
            break
        }
    }

    private func releaseAllInputsOnQueue() {
        // Release only keys and buttons injected by this sink. Releasing a
        // fixed modifier list would also release modifiers held locally by
        // the user when a remote session ends.
        let keysToRelease = pressedKeyCodes.sorted()
        let localModifierKeyCodes = Set(
            ModifierFlagProjection.modifierKeyCodes.filter {
                CGEventSource.keyState(
                    .hidSystemState,
                    key: CGKeyCode($0)
                )
            }
        )
        for keyCode in keysToRelease {
            // Clear tracking even if CoreGraphics cannot allocate a synthetic
            // key-up event; retaining it would poison the next session's
            // modifier projection and teardown state.
            pressedKeyCodes.remove(keyCode)
            guard let event = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: CGKeyCode(keyCode),
                keyDown: false
            ) else {
                continue
            }
            if ModifierFlagProjection.group(for: keyCode) != nil {
                event.type = .flagsChanged
                var remainingKeys = pressedKeyCodes
                remainingKeys.remove(keyCode)
                markAndPost(
                    event,
                    flags: ModifierFlagProjection.releaseFlags(
                        preservingLocalKeyCodes: localModifierKeyCodes,
                        remainingRemoteKeyCodes: remainingKeys
                    )
                )
            } else {
                markAndPost(event)
            }
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        for buttonNumber in pressedMouseButtons {
            let type: CGEventType = buttonNumber == 0
                ? .leftMouseUp
                : buttonNumber == 1 ? .rightMouseUp : .otherMouseUp
            guard let button = CGMouseButton(
                rawValue: UInt32(buttonNumber)
            ),
            let event = CGEvent(
                mouseEventSource: eventSource,
                mouseType: type,
                mouseCursorPosition: location,
                mouseButton: button
            ) else {
                continue
            }
            event.setIntegerValueField(
                .mouseEventButtonNumber,
                value: Int64(buttonNumber)
            )
            markAndPost(event)
        }
        pressedMouseButtons.removeAll()
        capsLockRemoteInputPolicy.reset()
        // Nothing here is a stuck-key risk to clear: every key it names was
        // already released above by the loop that drains pressedKeyCodes.
        activeKeyRemap.removeAll()
    }

    private func markAndPost(
        _ event: CGEvent,
        flags: CGEventFlags = []
    ) {
        event.flags = flags
        event.setIntegerValueField(
            .eventSourceUserData,
            value: InjectedEventMarker.value
        )
        event.post(tap: .cghidEventTap)
    }

    func eventFlags(
        for input: RemoteInputEvent,
        remap: KeyInjectionTarget? = nil
    ) -> CGEventFlags {
        if let remap, case .remapped(let target, let applyModifiers) = remap {
            guard applyModifiers else {
                // Only the keycode came from the lookup (see
                // KeyInjectionTarget); the sender's own flags — Command,
                // Control, and whatever Shift/Option/Caps Lock it actually
                // held — pass through completely unchanged.
                return CGEventFlags(rawValue: input.modifierFlags)
            }
            // Shift/Option/Caps Lock are replaced with whatever this local
            // layout needs to produce the sender's character, which may
            // differ from what the sender itself held.
            var flags = CGEventFlags(rawValue: input.modifierFlags)
            flags.remove([.maskShift, .maskAlternate, .maskAlphaShift])
            if target.shift { flags.insert(.maskShift) }
            if target.option { flags.insert(.maskAlternate) }
            if target.capsLock { flags.insert(.maskAlphaShift) }
            return flags
        }
        guard input.kind == .flagsChanged,
              let keyCode = input.keyCode else {
            return CGEventFlags(rawValue: input.modifierFlags)
        }
        return ModifierFlagProjection.projectedFlags(
            reportedFlags: CGEventFlags(rawValue: input.modifierFlags),
            keyCode: keyCode,
            isPressed: input.isPressed,
            pressedKeyCodes: pressedKeyCodes
        )
    }

    private func mouseMapping(
        for input: RemoteInputEvent
    ) -> (type: CGEventType, button: CGMouseButton)? {
        switch input.kind {
        case .mouseMoved:
            return (.mouseMoved, .left)
        case .leftMouseDown:
            return (.leftMouseDown, .left)
        case .leftMouseUp:
            return (.leftMouseUp, .left)
        case .leftMouseDragged:
            return (.leftMouseDragged, .left)
        case .rightMouseDown:
            return (.rightMouseDown, .right)
        case .rightMouseUp:
            return (.rightMouseUp, .right)
        case .rightMouseDragged:
            return (.rightMouseDragged, .right)
        case .otherMouseDown:
            guard let button = extraMouseButton(for: input) else { return nil }
            return (.otherMouseDown, button)
        case .otherMouseUp:
            guard let button = extraMouseButton(for: input) else { return nil }
            return (.otherMouseUp, button)
        case .otherMouseDragged:
            guard let button = extraMouseButton(for: input) else { return nil }
            return (.otherMouseDragged, button)
        default:
            return nil
        }
    }

    private func extraMouseButton(
        for input: RemoteInputEvent
    ) -> CGMouseButton? {
        guard let buttonNumber = input.buttonNumber else { return nil }
        return CGMouseButton(rawValue: UInt32(buttonNumber))
    }

    private func clampedWheelValue(_ value: Double) -> Int32 {
        Int32(max(Double(Int32.min), min(Double(Int32.max), value.rounded())))
    }

    private func publish(
        permission: Bool? = nil,
        status: String
    ) {
        DispatchQueue.main.async { [weak self] in
            if let permission {
                self?.hasAccessibilityPermission = permission
            }
            self?.status = status
        }
    }
}

private let inputEventTapCallback: CGEventTapCallBack = {
    _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let service = Unmanaged<InputCaptureService>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return service.capture(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}

private enum MainDisplayCoordinateSpace {
    // MacKVM intentionally maps only the KVM target configured as the main
    // display. Pointer positions on other displays clamp to that screen edge.
    static func normalizeClamped(_ point: CGPoint) -> NormalizedPoint? {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        guard !bounds.isNull,
              bounds.width > 0,
              bounds.height > 0 else {
            return nil
        }
        let normalizedX = (point.x - bounds.minX) / bounds.width
        let normalizedY = (point.y - bounds.minY) / bounds.height
        return NormalizedPoint(
            x: min(max(normalizedX, 0), CGFloat(1).nextDown),
            y: min(max(normalizedY, 0), CGFloat(1).nextDown)
        )
    }

    static func denormalize(_ point: NormalizedPoint) -> CGPoint? {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        guard !bounds.isNull,
              bounds.width > 0,
              bounds.height > 0 else {
            return nil
        }
        return CGPoint(
            x: bounds.minX + point.x * bounds.width,
            y: bounds.minY + point.y * bounds.height
        )
    }

}
