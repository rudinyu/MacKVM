import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import MacKVMCore

enum KeyboardLayoutIdentifier {
    private static let inputSourceKey =
        "AppleCurrentKeyboardLayoutInputSourceID"

    static func current() -> String? {
        let configured = UserDefaults.standard.string(forKey: inputSourceKey)
            ?? Locale.current.identifier
        let trimmed = configured.trimmingCharacters(
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
}

private enum InjectedEventMarker {
    static let value: Int64 = 0x4D_4B_56_4D
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
            return RemoteInputEvent(
                kind: .scroll,
                modifierFlags: flags,
                scrollDeltaX: event.getDoubleValueField(
                    .scrollWheelEventPointDeltaAxis2
                ),
                scrollDeltaY: event.getDoubleValueField(
                    .scrollWheelEventPointDeltaAxis1
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
        return RemoteInputEvent(
            kind: kind,
            keyCode: keyCode,
            isPressed: isPressed,
            modifierFlags: flags,
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
        return eventTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << $1.rawValue)
        }
    }()
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
    private let inputAdmission = BoundedAdmissionGate(
        // Remote input opens only after Accessibility is confirmed and the
        // serial injection queue has entered the active-control generation.
        capacity: BoundedAdmissionGate.defaultCapacity
    )

    init() {
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
                guard validatedInput.keyboardLayoutIdentifier == nil
                    || validatedInput.keyboardLayoutIdentifier
                        == KeyboardLayoutIdentifier.current() else {
                    isAcceptingRemoteInput = false
                    invalidateInputAdmission()
                    releaseAllInputsOnQueue()
                    publish(
                        status: "Remote control ended: keyboard layout changed"
                    )
                    DispatchQueue.main.async { [weak self] in
                        self?.onControlFailure?(.keyboardLayoutMismatch)
                    }
                    return
                }
                try inject(validatedInput)
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
        switch input.kind {
        case .keyDown, .keyUp, .flagsChanged:
            guard let keyCode = input.keyCode else {
                throw RemoteInputError.invalidFields
            }
            let keyDown = try keyDownState(for: input, keyCode: keyCode)
            event = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: CGKeyCode(keyCode),
                keyDown: keyDown
            )
            if input.kind == .flagsChanged {
                event?.type = .flagsChanged
            }

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
        }

        guard let event else {
            throw RemoteInputError.invalidFields
        }
        event.flags = eventFlags(for: input)
        event.setIntegerValueField(
            .eventSourceUserData,
            value: InjectedEventMarker.value
        )
        event.post(tap: .cghidEventTap)
        trackPressedState(input)
        if !hasPublishedInputActivity {
            hasPublishedInputActivity = true
            publish(status: "Remote input active")
        }
    }

    private func keyDownState(
        for input: RemoteInputEvent,
        keyCode: UInt16
    ) throws -> Bool {
        switch input.kind {
        case .keyDown:
            return true
        case .keyUp:
            return false
        case .flagsChanged:
            // flagsChanged is an edge event. The aggregate modifier mask
            // cannot distinguish left/right variants, so use the tracked
            // state supplied by the sender when available.
            return input.isPressed ?? !pressedKeyCodes.contains(keyCode)
        default:
            throw RemoteInputError.invalidFields
        }
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

    private func trackPressedState(_ input: RemoteInputEvent) {
        switch input.kind {
        case .keyDown:
            if let keyCode = input.keyCode {
                pressedKeyCodes.insert(keyCode)
            }
        case .keyUp:
            if let keyCode = input.keyCode {
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

    private func eventFlags(for input: RemoteInputEvent) -> CGEventFlags {
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
