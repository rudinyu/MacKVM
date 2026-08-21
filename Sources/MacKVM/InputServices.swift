import AppKit
import ApplicationServices
import Carbon
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

/// A deliberately uncommon, four-modifier shortcut for toggling the
/// keyboard/mouse route without opening the menu. Escape remains the
/// emergency return shortcut while this one is reserved for switching.
enum KeyboardMouseSwitchHotKey {
    static let keyCode: UInt16 = 40 // K
    static let displayName = "Control-Option-Command-K"

    static func matches(
        keyCode: UInt16,
        flags: CGEventFlags
    ) -> Bool {
        guard keyCode == Self.keyCode else { return false }
        let required: CGEventFlags = [
            .maskControl, .maskAlternate, .maskCommand
        ]
        return flags.intersection(required) == required
    }

    static func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat else { return false }
        return matches(
            keyCode: UInt16(event.keyCode),
            flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        )
    }
}

/// The dedicated "Other Mac" route shortcut. `O` means “Other” and uses the
/// same guarded display-plus-control toggle as the Show other Mac action.
enum OtherMonitorSwitchHotKey {
    static let keyCode: UInt16 = 31 // O
    static let displayName = "Control-Option-Command-O"

    static func matches(
        keyCode: UInt16,
        flags: CGEventFlags
    ) -> Bool {
        guard keyCode == Self.keyCode else { return false }
        let required: CGEventFlags = [
            .maskControl, .maskAlternate, .maskCommand
        ]
        return flags.intersection(required) == required
    }

    static func matches(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat else { return false }
        return matches(
            keyCode: UInt16(event.keyCode),
            flags: CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
        )
    }
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
    var onSwitchControl: (() -> Void)?
    var onSwitchMonitor: (() -> Void)?

    var keyboardLayoutIdentifier: String? {
        KeyboardLayoutIdentifier.current()
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var hotKeyEventTap: CFMachPort?
    private var hotKeyRunLoopSource: CFRunLoopSource?
    private var registeredHotKey: EventHotKeyRef?
    private var registeredEmergencyHotKey: EventHotKeyRef?
    private var registeredMonitorSwitchHotKey: EventHotKeyRef?
    private var registeredHotKeyHandler: EventHandlerRef?
    private var suppressesLocalEvents = false
    private var capsLockCapturePolicy = CapsLockCapturePolicy()

    init() {
        hasInputMonitoringPermission = CGPreflightListenEventAccess()
    }

    deinit {
        stopHotKeyMonitoring()
    }

    func refreshPermission() {
        hasInputMonitoringPermission = CGPreflightListenEventAccess()
        stopHotKeyMonitoring()
        startHotKeyMonitoring()
    }

    func requestPermission() {
        hasInputMonitoringPermission = CGRequestListenEventAccess()
        stopHotKeyMonitoring()
        startHotKeyMonitoring()
        status = hasInputMonitoringPermission
            ? "Input Monitoring permission granted"
            : "Enable Input Monitoring in System Settings, then return to MacKVM"
    }

    /// Installs a dedicated session event tap for the switch and emergency
    /// shortcuts. Unlike
    /// NSEvent's global monitor, a session tap can consume the event even
    /// when another application is focused, so the shortcut cannot trigger a
    /// second action in that application. This tap is intentionally separate
    /// from the full input-capture tap: it remains available while idle and
    /// while receiving control.
    func startHotKeyMonitoring() {
        guard hotKeyEventTap == nil,
              registeredHotKey == nil,
              registeredHotKeyHandler == nil else {
            return
        }
        // A session event tap is the strongest path because it can consume
        // the shortcut before a foreground application sees it. A receiver
        // may only have Accessibility permission, however, so fall back to a
        // Carbon registered hot key, which is global and does not require
        // Input Monitoring.
        guard hasInputMonitoringPermission else {
            startCarbonHotKey()
            return
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.hotKeyEventMask,
            callback: hotKeyEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            startCarbonHotKey()
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            tap,
            0
        ) else {
            startCarbonHotKey()
            return
        }
        hotKeyEventTap = tap
        hotKeyRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func startCarbonHotKey() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            registeredHotKeyEventHandler,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &registeredHotKeyHandler
        )
        guard installStatus == noErr else {
            status = "Could not create the global switch shortcut"
            return
        }

        let switchStatus = registerCarbonHotKey(
            keyCode: KeyboardMouseSwitchHotKey.keyCode,
            id: RegisteredSwitchHotKey.id,
            modifiers: RegisteredSwitchHotKey.modifiers,
            storage: &registeredHotKey
        )
        let emergencyStatus = registerCarbonHotKey(
            keyCode: EmergencyReturnHotKey.keyCode,
            id: RegisteredEmergencyHotKey.id,
            modifiers: EmergencyReturnHotKey.modifiers,
            storage: &registeredEmergencyHotKey
        )
        let monitorStatus = registerCarbonHotKey(
            keyCode: OtherMonitorSwitchHotKey.keyCode,
            id: RegisteredMonitorSwitchHotKey.id,
            modifiers: RegisteredMonitorSwitchHotKey.modifiers,
            storage: &registeredMonitorSwitchHotKey
        )

        // Registration is intentionally independent. A conflicting K
        // shortcut must not remove Escape emergency recovery or the monitor
        // route shortcut, and vice versa.
        if switchStatus != noErr {
            status = "Could not create the global keyboard/mouse shortcut"
        } else if emergencyStatus != noErr {
            status = "Could not create the global emergency shortcut"
        } else if monitorStatus != noErr {
            status = "Could not create the global monitor shortcut"
        }
        if registeredHotKey == nil,
           registeredEmergencyHotKey == nil,
           registeredMonitorSwitchHotKey == nil {
            if let registeredHotKeyHandler {
                RemoveEventHandler(registeredHotKeyHandler)
            }
            registeredHotKeyHandler = nil
        }
    }

    private func registerCarbonHotKey(
        keyCode: UInt16,
        id: UInt32,
        modifiers: UInt32,
        storage: inout EventHotKeyRef?
    ) -> OSStatus {
        let hotKeyID = EventHotKeyID(
            signature: RegisteredSwitchHotKey.signature,
            id: id
        )
        let result = RegisterEventHotKey(
            UInt32(keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &storage
        )
        if result != noErr {
            storage = nil
        }
        return result
    }

    func stopHotKeyMonitoring() {
        if let hotKeyEventTap {
            CGEvent.tapEnable(tap: hotKeyEventTap, enable: false)
        }
        if let hotKeyRunLoopSource {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                hotKeyRunLoopSource,
                .commonModes
            )
        }
        hotKeyRunLoopSource = nil
        hotKeyEventTap = nil
        if let registeredHotKey {
            UnregisterEventHotKey(registeredHotKey)
        }
        if let registeredEmergencyHotKey {
            UnregisterEventHotKey(registeredEmergencyHotKey)
        }
        if let registeredMonitorSwitchHotKey {
            UnregisterEventHotKey(registeredMonitorSwitchHotKey)
        }
        if let registeredHotKeyHandler {
            RemoveEventHandler(registeredHotKeyHandler)
        }
        registeredHotKey = nil
        registeredEmergencyHotKey = nil
        registeredMonitorSwitchHotKey = nil
        registeredHotKeyHandler = nil
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
        if isMonitorSwitchShortcut(type: type, event: event) {
            if type == .keyDown,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                dispatchMonitorSwitch()
            }
            return true
        }
        if isSwitchShortcut(type: type, event: event) {
            if type == .keyDown,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                dispatchSwitchHotKey()
            }
            return true
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
        if suppressesLocalEvents,
           type == .flagsChanged,
           Self.shouldSuppressReservedHotKeyModifierFlags(event.flags) {
            // K, O, and Escape all reserve the same three modifiers. Consume
            // the flagsChanged edge that completes that chord so the remote
            // Mac never observes the full modifier-only combination before
            // the trigger key can be handled locally. Partial modifier use
            // remains available for ordinary remote shortcuts.
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
                    modifierFlags: RemoteInputEvent.normalizedModifierFlags(
                        event.flags.rawValue
                    ),
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

    private func isSwitchShortcut(
        type: CGEventType,
        event: CGEvent
    ) -> Bool {
        guard type == .keyDown || type == .keyUp else { return false }
        return KeyboardMouseSwitchHotKey.matches(
            keyCode: UInt16(
                event.getIntegerValueField(.keyboardEventKeycode)
            ),
            flags: event.flags
        )
    }

    private func isMonitorSwitchShortcut(
        type: CGEventType,
        event: CGEvent
    ) -> Bool {
        guard type == .keyDown || type == .keyUp else { return false }
        return OtherMonitorSwitchHotKey.matches(
            keyCode: UInt16(
                event.getIntegerValueField(.keyboardEventKeycode)
            ),
            flags: event.flags
        )
    }

    private func dispatchSwitchHotKey() {
        DispatchQueue.main.async { [weak self] in
            self?.onSwitchControl?()
        }
    }

    private func dispatchMonitorSwitch() {
        DispatchQueue.main.async { [weak self] in
            self?.onSwitchMonitor?()
        }
    }

    private func dispatchEmergencyStop() {
        DispatchQueue.main.async { [weak self] in
            self?.onEmergencyStop?()
        }
    }

    fileprivate func handleRegisteredHotKey(_ event: EventRef?) {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard let action = RegisteredHotKeyAction.resolve(
            parameterStatus: status,
            id: hotKeyID.id
        ) else {
            // A failed Carbon parameter lookup must be a no-op. Falling back
            // to K here could toggle remote input while the user is trying
            // to use Escape for emergency local recovery.
            return
        }
        switch action {
        case .emergencyStop:
            dispatchEmergencyStop()
        case .monitorSwitch:
            dispatchMonitorSwitch()
        case .switchControl:
            dispatchSwitchHotKey()
        }
    }

    fileprivate func reenableHotKeyEventTap() {
        guard let hotKeyEventTap else { return }
        CGEvent.tapEnable(tap: hotKeyEventTap, enable: true)
    }

    fileprivate func captureHotKey(
        type: CGEventType,
        event: CGEvent
    ) -> Bool {
        guard event.getIntegerValueField(.eventSourceUserData)
                != InjectedEventMarker.value else {
            return false
        }
        let isSwitchShortcut = isSwitchShortcut(type: type, event: event)
        let isEmergencyShortcut = isEmergencyShortcut(type: type, event: event)
        let isMonitorSwitchShortcut = isMonitorSwitchShortcut(
            type: type,
            event: event
        )
        guard isSwitchShortcut || isEmergencyShortcut || isMonitorSwitchShortcut
        else { return false }
        if type == .keyDown,
           event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            if isSwitchShortcut {
                dispatchSwitchHotKey()
            } else if isEmergencyShortcut {
                dispatchEmergencyStop()
            } else {
                dispatchMonitorSwitch()
            }
        }
        // Consume both edges whenever the modifiers are still held. This
        // keeps the foreground application from seeing a partial shortcut,
        // including emergency return while no input capture is active.
        return true
    }

    private func makeRemoteEvent(
        type: CGEventType,
        event: CGEvent
    ) -> RemoteInputEvent? {
        let flags = RemoteInputEvent.normalizedModifierFlags(
            event.flags.rawValue
        )
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

    private static let hotKeyEventMask: CGEventMask = {
        (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
    }()

    static func shouldSuppressReservedHotKeyModifierFlags(
        _ flags: CGEventFlags
    ) -> Bool {
        let required: CGEventFlags = [
            .maskControl, .maskAlternate, .maskCommand
        ]
        return flags.intersection(required) == required
    }
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
    /// Carbon's notification-driven layout cache is stale. This is a
    /// transient state while the main-thread refresh is queued; it must not
    /// tear down an otherwise healthy remote-control session.
    case layoutUnavailable
    /// CoreGraphics could not allocate the event needed to inject input. This
    /// is terminal for the current control session so held input is released
    /// instead of leaving a key or button stuck remotely.
    case eventCreationFailed
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
    // Resolved once at keyDown, by the sender's physical keyCode, and reused
    // as-is at the matching keyUp. This guarantees a press and its release
    // always target the same local key even if the provider refreshes its
    // layout snapshot while the key is held.
    private var activeKeyRemap: [UInt16: KeyInjectionTarget] = [:]
    // A key-down can arrive while the notification-driven Carbon cache is
    // refreshing.  It is safer to drop that press than to inject it using the
    // raw key code; the matching key-up must then be dropped as well or it
    // could release an unrelated local key on a different layout.
    private var droppedKeyUps: Set<UInt16> = []
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
            guard releaseAllInputsOnQueue() else {
                publish(
                    status: "Remote control cannot start until input is released"
                )
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            isAcceptingRemoteInput = true
            beginInputAdmission()
            capsLockRemoteInputPolicy.reset()
            droppedKeyUps.removeAll()
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
            let released = releaseAllInputsOnQueue()
            hasPublishedInputActivity = false
            publish(
                status: released
                    ? "Remote control ended"
                    : "Remote control ended; input release will be retried"
            )
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
            } catch RemoteInputSinkError.layoutUnavailable {
                // A layout-change notification can race with an input event.
                // The provider schedules a main-thread refresh and this event
                // is intentionally dropped; the next event will use the new
                // cached layout. Do not end the control session for a
                // transiently unavailable Carbon source.
                if input.kind == .keyDown, let keyCode = input.keyCode {
                    droppedKeyUps.insert(keyCode)
                }
                return
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
            } catch RemoteInputSinkError.eventCreationFailed {
                // A failable CGEvent initializer must terminate the receiving
                // session. Otherwise a key-up or mouse-up can remain in the
                // remote HID state with no later event able to release it.
                isAcceptingRemoteInput = false
                invalidateInputAdmission()
                let released = releaseAllInputsOnQueue()
                publish(
                    status: released
                        ? "Remote control ended: macOS rejected an input event"
                        : "Remote control ended: retrying input release"
                )
                DispatchQueue.main.async { [weak self] in
                    self?.onControlFailure?(.eventInjectionFailed)
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
            if input.kind == .keyUp,
               droppedKeyUps.remove(remoteKeyCode) != nil {
                // The corresponding key-down was intentionally dropped while
                // the layout cache was unavailable, so this release must not
                // be sent using a raw key code.
                return
            }
            let target = try resolveKeyInjectionTargetOrThrow(
                for: input,
                remoteKeyCode: remoteKeyCode
            )
            if input.kind == .keyDown {
                // A later press can legitimately succeed after a transient
                // layout refresh; its release belongs to this newly injected
                // press, not to the previously dropped one.
                droppedKeyUps.remove(remoteKeyCode)
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
                flags: CGEventFlags(
                    rawValue: RemoteInputEvent.normalizedModifierFlags(
                        input.modifierFlags
                    )
                )
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
            throw RemoteInputSinkError.eventCreationFailed
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

    /// Chooses where a keyDown/keyUp should actually be injected. The
    /// best-effort API remains optional for callers that only need a lookup;
    /// the injection path uses `resolveKeyInjectionTargetOrThrow` so it can
    /// distinguish a transient cache refresh from a genuinely unmappable key.
    func resolveKeyInjectionTarget(
        for input: RemoteInputEvent,
        remoteKeyCode: UInt16
    ) -> KeyInjectionTarget? {
        try? resolveKeyInjectionTargetOrThrow(
            for: input,
            remoteKeyCode: remoteKeyCode
        )
    }

    /// Resolves a key for the actual injection path while preserving the
    /// distinction between a temporarily stale layout cache and a key that
    /// genuinely has no local equivalent.
    func resolveKeyInjectionTargetOrThrow(
        for input: RemoteInputEvent,
        remoteKeyCode: UInt16
    ) throws -> KeyInjectionTarget {
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
        let target = try computeKeyInjectionTargetOrThrow(
            for: input,
            remoteKeyCode: remoteKeyCode
        )
        activeKeyRemap[remoteKeyCode] = target
        return target
    }

    func computeKeyInjectionTarget(
        for input: RemoteInputEvent,
        remoteKeyCode: UInt16
    ) -> KeyInjectionTarget? {
        try? computeKeyInjectionTargetOrThrow(
            for: input,
            remoteKeyCode: remoteKeyCode
        )
    }

    private func computeKeyInjectionTargetOrThrow(
        for input: RemoteInputEvent,
        remoteKeyCode: UInt16
    ) throws -> KeyInjectionTarget {
        guard let remoteLayout = input.keyboardLayoutIdentifier,
              RemappableKeyCodes.all.contains(remoteKeyCode) else {
            return .identity(keyCode: remoteKeyCode)
        }
        // A sender that supplied a layout identifier needs a known local
        // identifier before we can safely decide that the raw key code is
        // already correct. If Carbon is temporarily unavailable, the caller
        // drops this one event and retries on the next event after the cache
        // refresh; it must not tear down the active control session.
        guard let snapshot = keyboardLayoutProvider.currentSnapshot() else {
            throw RemoteInputSinkError.layoutUnavailable
        }
        let localLayout = snapshot.identifier
        guard remoteLayout != localLayout else {
            return .identity(keyCode: remoteKeyCode)
        }
        guard let character = input.character else {
            // The sender could not translate this key on its own layout
            // (for example, an ISO key with no glyph there); there is
            // nothing to look up on this one either.
            throw RemoteInputSinkError.unmappableKey
        }
        guard let target = snapshot.reverseMap.target(for: character) else {
            throw RemoteInputSinkError.unmappableKey
        }
        let modifierFlags = CGEventFlags(
            rawValue: RemoteInputEvent.normalizedModifierFlags(
                input.modifierFlags
            )
        )
        let isShortcut = modifierFlags.contains(.maskCommand)
            || modifierFlags.contains(.maskControl)
        return .remapped(target, applyModifiers: !isShortcut)
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

    @discardableResult
    private func releaseAllInputsOnQueue() -> Bool {
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
        var allReleased = true
        for keyCode in keysToRelease {
            guard let event = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: CGKeyCode(keyCode),
                keyDown: false
            ) else {
                // Keep the entry so a later teardown can retry the release.
                // Dropping it here would make a failed CoreGraphics
                // allocation indistinguishable from a delivered key-up.
                allReleased = false
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
            pressedKeyCodes.remove(keyCode)
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
                allReleased = false
                continue
            }
            event.setIntegerValueField(
                .mouseEventButtonNumber,
                value: Int64(buttonNumber)
            )
            markAndPost(event)
            pressedMouseButtons.remove(buttonNumber)
        }
        capsLockRemoteInputPolicy.reset()
        droppedKeyUps.removeAll()
        activeKeyRemap.removeAll()
        return allReleased
            && pressedKeyCodes.isEmpty
            && pressedMouseButtons.isEmpty
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
        let normalizedModifierFlags =
            RemoteInputEvent.normalizedModifierFlags(input.modifierFlags)
        if let remap, case .remapped(let target, let applyModifiers) = remap {
            guard applyModifiers else {
                // Only the keycode came from the lookup (see
                // KeyInjectionTarget); the sender's own flags — Command,
                // Control, and whatever Shift/Option/Caps Lock it actually
                // held — pass through completely unchanged.
                return CGEventFlags(rawValue: normalizedModifierFlags)
            }
            // Shift/Option/Caps Lock are replaced with whatever this local
            // layout needs to produce the sender's character, which may
            // differ from what the sender itself held.
            var flags = CGEventFlags(rawValue: normalizedModifierFlags)
            flags.remove([.maskShift, .maskAlternate, .maskAlphaShift])
            if target.shift { flags.insert(.maskShift) }
            if target.option { flags.insert(.maskAlternate) }
            if target.capsLock { flags.insert(.maskAlphaShift) }
            return flags
        }
        guard input.kind == .flagsChanged,
              let keyCode = input.keyCode else {
            return CGEventFlags(rawValue: normalizedModifierFlags)
        }
        return ModifierFlagProjection.projectedFlags(
            reportedFlags: CGEventFlags(rawValue: normalizedModifierFlags),
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

private let hotKeyEventTapCallback: CGEventTapCallBack = {
    _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let service = Unmanaged<InputCaptureService>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // macOS can disable a tap after a callback timeout or while another
        // process temporarily owns event-input handling. Re-enable this
        // dedicated shortcut tap immediately so the global switch key does
        // not silently disappear until the next permission refresh.
        service.reenableHotKeyEventTap()
        return Unmanaged.passUnretained(event)
    }
    return service.captureHotKey(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}

private enum RegisteredSwitchHotKey {
    static let signature: OSType = 0x4D4B_564D // "MKVM"
    static let id: UInt32 = 1
    static let modifiers: UInt32 =
        UInt32(controlKey | optionKey | cmdKey)
}

enum RegisteredHotKeyAction: Equatable {
    case switchControl
    case emergencyStop
    case monitorSwitch

    static func resolve(
        parameterStatus: OSStatus,
        id: UInt32
    ) -> RegisteredHotKeyAction? {
        guard parameterStatus == noErr else { return nil }
        switch id {
        case RegisteredSwitchHotKey.id:
            return .switchControl
        case RegisteredEmergencyHotKey.id:
            return .emergencyStop
        case RegisteredMonitorSwitchHotKey.id:
            return .monitorSwitch
        default:
            return nil
        }
    }
}

private enum EmergencyReturnHotKey {
    static let keyCode: UInt16 = 53 // Escape
    static let modifiers: UInt32 =
        UInt32(controlKey | optionKey | cmdKey)
}

private enum RegisteredEmergencyHotKey {
    static let signature: OSType = RegisteredSwitchHotKey.signature
    static let id: UInt32 = 2
}

private enum RegisteredMonitorSwitchHotKey {
    static let signature: OSType = RegisteredSwitchHotKey.signature
    static let id: UInt32 = 3
    static let modifiers: UInt32 =
        UInt32(controlKey | optionKey | cmdKey)
}

private let registeredHotKeyEventHandler: EventHandlerUPP = {
    _, event, userInfo in
    guard let userInfo else { return noErr }
    let service = Unmanaged<InputCaptureService>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    service.handleRegisteredHotKey(event)
    return noErr
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
