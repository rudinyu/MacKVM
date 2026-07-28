import Combine
import Foundation
import MacKVMCore

final class ControlCoordinator: ObservableObject {
    @Published private(set) var state: ControlSessionState = .idle
    @Published private(set) var isReceivingControl = false
    @Published private(set) var status = "Control session idle"

    var onControllingStarted: (() -> Void)?
    var onControllingStopped: (() -> Void)?
    var onReceivingStarted: (() -> Void)?
    var onReceivingStopped: (() -> Void)?

    private let localID: UUID
    private let secureSession: SecureSessionService
    private let inputCapture: InputCaptureService
    private let inputSink: RemoteInputSink
    private var machine = ControlSessionStateMachine()
    private var connectionObservation: AnyCancellable?
    private var requestTimeout: DispatchWorkItem?
    private var activeOutboundRequestID: UUID?
    private var activeInboundRequestID: UUID?

    init(
        localID: UUID,
        secureSession: SecureSessionService,
        inputCapture: InputCaptureService,
        inputSink: RemoteInputSink
    ) {
        self.localID = localID
        self.secureSession = secureSession
        self.inputCapture = inputCapture
        self.inputSink = inputSink

        inputCapture.onEvent = { [weak self] event in
            guard let self,
                  state == .controlling,
                  let requestID = activeOutboundRequestID else {
                return
            }
            send(.input(event, requestID: requestID))
        }
        inputCapture.onEmergencyStop = { [weak self] in
            self?.stopControl(reason: "Emergency shortcut returned input locally")
        }
        inputSink.onControlFailure = { [weak self] in
            self?.remoteInputSinkFailed()
        }
        secureSession.onPayload = { [weak self] data in
            self?.receive(data)
        }
        connectionObservation = secureSession.$connectedPeerID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peerID in
                self?.connectionChanged(peerID)
            }
    }

    func requestControl() {
        guard secureSession.connectedPeerID != nil else {
            status = "Connect to a paired Mac first"
            return
        }
        guard !isReceivingControl else {
            status = "This Mac is currently being controlled"
            return
        }
        inputCapture.refreshPermission()
        guard inputCapture.hasInputMonitoringPermission else {
            status = "Input Monitoring permission is required"
            return
        }
        inputSink.refreshPermission()
        guard inputSink.hasAccessibilityPermission else {
            status = "Accessibility permission is required to control another Mac"
            return
        }
        do {
            let requestID = UUID()
            state = try machine.handle(.requestControl)
            activeOutboundRequestID = requestID
            status = "Waiting for the other Mac to grant control…"
            send(
                ControlMessage(
                    kind: .requestControl,
                    requestID: requestID
                )
            )
            scheduleRequestTimeout()
        } catch {
            status = "Control can only start from the connected state"
        }
    }

    func stopControl(reason: String = "Control returned locally") {
        let wasControlling = state == .controlling
        requestTimeout?.cancel()
        requestTimeout = nil
        inputCapture.stopCapture()
        if state == .controlling || state == .suspended {
            let requestID = activeOutboundRequestID
            _ = try? machine.handle(.stopControl)
            state = machine.state
            activeOutboundRequestID = nil
            if let requestID {
                send(
                    ControlMessage(
                        kind: .endControl,
                        requestID: requestID
                    )
                )
            }
        }
        if wasControlling {
            onControllingStopped?()
        }
        status = reason
    }

    private func receive(_ data: Data) {
        let message: ControlMessage
        do {
            message = try ControlMessageCodec.decode(data)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.status = "Rejected an invalid control message"
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.handle(message)
        }
    }

    private func handle(_ message: ControlMessage) {
        switch message.kind {
        case .requestControl:
            guard let requestID = message.requestID else { return }
            handleControlRequest(requestID: requestID)
        case .controlGranted:
            guard message.requestID == activeOutboundRequestID else { return }
            handleControlGranted()
        case .controlDenied:
            guard state == .suspended,
                  message.requestID == activeOutboundRequestID else {
                return
            }
            requestTimeout?.cancel()
            _ = try? machine.handle(.stopControl)
            state = machine.state
            activeOutboundRequestID = nil
            status = "The other Mac denied control"
        case .endControl:
            if message.requestID == activeOutboundRequestID,
               state == .controlling || state == .suspended {
                let wasControlling = state == .controlling
                requestTimeout?.cancel()
                requestTimeout = nil
                inputCapture.stopCapture()
                _ = try? machine.handle(.stopControl)
                state = machine.state
                activeOutboundRequestID = nil
                if wasControlling {
                    onControllingStopped?()
                }
                status = "The other Mac ended control; input is local"
            }
            if message.requestID == activeInboundRequestID,
               isReceivingControl {
                isReceivingControl = false
                activeInboundRequestID = nil
                inputSink.endRemoteControl()
                onReceivingStopped?()
                status = "The other Mac returned control"
            }
        case .input:
            if let input = message.input,
               message.requestID == activeInboundRequestID,
               isReceivingControl {
                inputSink.receive(input)
            }
        }
    }

    private func handleControlRequest(requestID: UUID) {
        guard !isReceivingControl else {
            send(
                ControlMessage(
                    kind: .controlDenied,
                    requestID: requestID
                )
            )
            status = "Denied a second request while remote control is active"
            return
        }
        inputSink.refreshPermission()
        guard inputSink.hasAccessibilityPermission,
              let peerID = secureSession.connectedPeerID else {
            send(
                ControlMessage(
                    kind: .controlDenied,
                    requestID: requestID
                )
            )
            status = "Denied remote control: Accessibility permission is missing"
            return
        }
        if state == .controlling || state == .suspended {
            let localWins = PeerArbitration.localIDWins(
                localID: localID,
                remoteID: peerID
            )
            if localWins {
                send(
                    ControlMessage(
                        kind: .controlDenied,
                        requestID: requestID
                    )
                )
                status = "Kept local control after a simultaneous request"
                return
            }
            if state == .suspended {
                cancelPendingRequestForSimultaneousControl()
            } else {
                stopControl(
                    reason: "Yielded control to a request from the other Mac"
                )
            }
        }
        isReceivingControl = true
        activeInboundRequestID = requestID
        inputSink.beginRemoteControl()
        onReceivingStarted?()
        send(
            ControlMessage(
                kind: .controlGranted,
                requestID: requestID
            )
        )
        status = "Remote control granted to the other Mac"
    }

    private func handleControlGranted() {
        guard state == .suspended else { return }
        requestTimeout?.cancel()
        requestTimeout = nil
        do {
            state = try machine.handle(.controlGranted)
            inputCapture.startCapture(suppressingLocalEvents: true)
            guard inputCapture.isCapturing else {
                let requestID = activeOutboundRequestID
                _ = try? machine.handle(.stopControl)
                state = machine.state
                activeOutboundRequestID = nil
                if let requestID {
                    send(
                        ControlMessage(
                            kind: .endControl,
                            requestID: requestID
                        )
                    )
                }
                status = "Could not capture input; control stayed local"
                return
            }
            onControllingStarted?()
            status = "Controlling the other Mac — ⌃⌥⌘Esc returns locally"
        } catch {
            if let requestID = activeOutboundRequestID {
                send(
                    ControlMessage(
                        kind: .endControl,
                        requestID: requestID
                    )
                )
            }
            activeOutboundRequestID = nil
            status = "Ignored an unexpected control grant"
        }
    }

    private func connectionChanged(_ peerID: UUID?) {
        let wasControlling = state == .controlling
        let wasReceiving = isReceivingControl
        requestTimeout?.cancel()
        requestTimeout = nil
        activeOutboundRequestID = nil
        activeInboundRequestID = nil
        if wasControlling {
            onControllingStopped?()
        }
        if wasReceiving {
            onReceivingStopped?()
        }
        if peerID == nil {
            inputCapture.stopCapture()
            isReceivingControl = false
            inputSink.endRemoteControl()
            _ = try? machine.handle(.transportDisconnected)
            state = machine.state
            status = "Secure session disconnected; input is local"
        } else {
            if state == .controlling || state == .suspended {
                inputCapture.stopCapture()
            }
            isReceivingControl = false
            inputSink.endRemoteControl()
            _ = try? machine.handle(.transportConnected)
            state = machine.state
            status = "Secure session connected; input is local"
        }
    }

    private func remoteInputSinkFailed() {
        guard isReceivingControl else { return }
        isReceivingControl = false
        let requestID = activeInboundRequestID
        activeInboundRequestID = nil
        inputSink.endRemoteControl()
        onReceivingStopped?()
        if let requestID {
            send(
                ControlMessage(
                    kind: .endControl,
                    requestID: requestID
                )
            )
        }
        status = "Remote control ended because Accessibility is unavailable"
    }

    private func cancelPendingRequestForSimultaneousControl() {
        requestTimeout?.cancel()
        requestTimeout = nil
        inputCapture.stopCapture()
        _ = try? machine.handle(.stopControl)
        state = machine.state
        activeOutboundRequestID = nil
        status = "Yielded a simultaneous request to the other Mac"
    }

    private func scheduleRequestTimeout() {
        requestTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, state == .suspended else { return }
            stopControl(reason: "Control request timed out; input stayed local")
        }
        requestTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    }

    private func send(_ message: ControlMessage) {
        do {
            secureSession.send(try ControlMessageCodec.encode(message))
        } catch {
            status = "Could not encode the control message"
        }
    }
}
