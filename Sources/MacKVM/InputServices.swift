import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import MacKVMCore

private enum InjectedEventMarker {
    static let value: Int64 = 0x4D_4B_56_4D
}

final class InputCaptureService: ObservableObject {
    @Published private(set) var hasInputMonitoringPermission: Bool
    @Published private(set) var isCapturing = false
    @Published private(set) var status = "Input capture stopped"

    var onEvent: ((RemoteInputEvent) -> Void)?
    var onEmergencyStop: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suppressesLocalEvents = false

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
            : "Enable Input Monitoring in System Settings, then reopen MacKVM"
    }

    func startCapture(suppressingLocalEvents: Bool = false) {
        refreshPermission()
        guard hasInputMonitoringPermission else {
            status = "Input Monitoring permission is required"
            return
        }
        guard eventTap == nil else { return }

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
            return false
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
    ) -> RemoteInputEvent {
        RemoteInputEvent(
            kind: kind,
            keyCode: UInt16(
                event.getIntegerValueField(.keyboardEventKeycode)
            ),
            modifierFlags: flags
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

final class RemoteInputSink: ObservableObject {
    @Published private(set) var hasAccessibilityPermission: Bool
    @Published private(set) var status = "Remote input ready"

    var onControlFailure: (() -> Void)?

    private let queue = DispatchQueue(label: "app.mackvm.input-injection")
    private let eventSource = CGEventSource(stateID: .hidSystemState)
    private var hasPublishedInputActivity = false
    private var isAcceptingRemoteInput = false
    private var pressedKeyCodes: Set<UInt16> = []
    private var pressedMouseButtons: Set<Int> = []

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
            : "Enable Accessibility in System Settings, then reopen MacKVM"
    }

    func beginRemoteControl() {
        queue.async { [weak self] in
            self?.isAcceptingRemoteInput = true
            self?.hasPublishedInputActivity = false
            self?.publish(status: "Remote control granted")
        }
    }

    func endRemoteControl() {
        queue.async { [weak self] in
            guard let self else { return }
            isAcceptingRemoteInput = false
            releaseAllInputsOnQueue()
            hasPublishedInputActivity = false
            publish(status: "Remote control ended")
        }
    }

    func receive(_ input: RemoteInputEvent) {
        queue.async { [weak self] in
            guard let self, isAcceptingRemoteInput else { return }
            guard AXIsProcessTrusted() else {
                isAcceptingRemoteInput = false
                releaseAllInputsOnQueue()
                publish(
                    permission: false,
                    status: "Accessibility permission is required"
                )
                DispatchQueue.main.async { [weak self] in
                    self?.onControlFailure?()
                }
                return
            }
            do {
                try inject(input.validated())
            } catch {
                publish(status: "Rejected invalid remote input")
            }
        }
    }

    private func inject(_ input: RemoteInputEvent) throws {
        let event: CGEvent?
        switch input.kind {
        case .keyDown, .keyUp, .flagsChanged:
            guard let keyCode = input.keyCode else {
                throw RemoteInputError.invalidFields
            }
            event = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: CGKeyCode(keyCode),
                keyDown: input.kind != .keyUp
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
        event.flags = CGEventFlags(rawValue: input.modifierFlags)
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
        let modifierKeyCodes: [UInt16] = [
            54, 55, 56, 57, 58, 59, 60, 61, 62
        ]
        for keyCode in pressedKeyCodes.union(modifierKeyCodes) {
            guard let event = CGEvent(
                keyboardEventSource: eventSource,
                virtualKey: CGKeyCode(keyCode),
                keyDown: false
            ) else {
                continue
            }
            markAndPost(event)
        }
        pressedKeyCodes.removeAll()

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
    }

    private func markAndPost(_ event: CGEvent) {
        event.flags = []
        event.setIntegerValueField(
            .eventSourceUserData,
            value: InjectedEventMarker.value
        )
        event.post(tap: .cghidEventTap)
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
