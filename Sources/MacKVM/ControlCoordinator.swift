import Combine
import Foundation
import MacKVMCore

struct IncomingControlRequest: Identifiable, Equatable {
    let id: UUID
    let peerID: UUID
}

enum ControlInputFailure {
    case accessibilityPermission
    case queueOverloaded
    case keyboardLayoutMismatch
}

struct ControlConnectionPublication: Equatable {
    let peerID: UUID?
    let admissionGeneration: UInt64?
}

/// Narrow abstractions keep the consent coordinator testable without changing
/// the production secure-session or input-service implementations.
protocol ControlSessionTransport: AnyObject {
    var connectedPeerID: UUID? { get }
    var connectedPeerIDPublisher: AnyPublisher<UUID?, Never> { get }
    var connectionPublicationPublisher:
        AnyPublisher<ControlConnectionPublication, Never> { get }
    var onPayload: ((Data) -> Void)? { get set }
    var onAuthenticated: (() -> UInt64)? { get set }

    func send(_ payload: Data)
    func disconnect()
}

protocol ControlInputCapture: AnyObject {
    var hasInputMonitoringPermission: Bool { get }
    var isCapturing: Bool { get }
    var onEvent: ((RemoteInputEvent) -> Void)? { get set }
    var onEmergencyStop: (() -> Void)? { get set }

    func refreshPermission()
    func startCapture(suppressingLocalEvents: Bool)
    func stopCapture()
}

protocol ControlInputSink: AnyObject {
    var hasAccessibilityPermission: Bool { get }
    var onControlFailure: ((ControlInputFailure) -> Void)? { get set }

    func refreshPermission()
    func beginRemoteControl(completion: @escaping (Bool) -> Void)
    func endRemoteControl(completion: @escaping () -> Void)
    func receive(_ input: RemoteInputEvent)
}

final class ControlCoordinator: ObservableObject {
    private struct ReceiverTeardown {
        enum Phase {
            case releasingInput
            case restoringMonitor
        }

        let request: IncomingControlRequest
        var phase: Phase
        let notifyPeer: Bool
        var restoreMonitor: Bool
        var completions: [() -> Void]
    }

    @Published private(set) var state: ControlSessionState = .idle
    @Published private(set) var isReceivingControl = false
    @Published private(set) var isRemoteInputTearingDown = false
    @Published private(set) var pendingIncomingControlRequest:
        IncomingControlRequest?
    @Published private(set) var status = "Control session idle"

    var onControllingStarted: (() -> Void)?
    var onControllingStopped: (() -> Void)?
    var onReceivingStarted: (() -> Void)?
    var onReceivingStopped: ((@escaping () -> Void) -> Void)?
    var onIncomingControlRequest: ((IncomingControlRequest) -> Void)?

    private static let controlRequestTimeout: TimeInterval = 15
    private let localID: UUID
    private let secureSession: any ControlSessionTransport
    private let inputCapture: any ControlInputCapture
    private let inputSink: any ControlInputSink
    private let localControlAllowed: () -> Bool
    private let keyboardLayoutIdentifier: () -> String?
    private var machine = ControlSessionStateMachine()
    private var connectionObservation: AnyCancellable?
    private var requestTimeout: DispatchWorkItem?
    private var incomingRequestTimeout: DispatchWorkItem?
    private var activeOutboundRequestID: UUID?
    private var activeInboundControlRequest: IncomingControlRequest?
    private var preparingIncomingControlRequest: IncomingControlRequest?
    private var receiverTeardown: ReceiverTeardown?
    private var transientRemoteInputTeardownCompletions: [() -> Void] = []
    private var isStoppingForQuit = false
    private var hasObservedConnectionState = false
    private var observedConnectedPeerID: UUID?
    private var observedAdmissionGeneration: UInt64?
    // Starts enabled so a payload cannot race the first asynchronous
    // connected-peer publisher update; authentication re-activates it after
    // a disconnect invalidates the previous generation.
    private let inboundAdmission = BoundedAdmissionGate(
        capacity: BoundedAdmissionGate.defaultCapacity,
        initiallyEnabled: true
    )

    init(
        localID: UUID,
        secureSession: any ControlSessionTransport,
        inputCapture: any ControlInputCapture,
        inputSink: any ControlInputSink,
        localControlAllowed: @escaping () -> Bool = { true },
        keyboardLayoutIdentifier: @escaping () -> String? = { nil }
    ) {
        self.localID = localID
        self.secureSession = secureSession
        self.inputCapture = inputCapture
        self.inputSink = inputSink
        self.localControlAllowed = localControlAllowed
        self.keyboardLayoutIdentifier = keyboardLayoutIdentifier
        // Treat the initial publisher value as describing the gate's initial
        // generation. If authentication races that first nil delivery, the
        // nil event must not invalidate the newer authenticated generation.
        observedAdmissionGeneration = inboundAdmission.currentGeneration()

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
        inputSink.onControlFailure = { [weak self] failure in
            self?.remoteInputSinkFailed(failure)
        }
        secureSession.onPayload = { [weak self] data in
            self?.receive(data)
        }
        secureSession.onAuthenticated = { [weak self] in
            guard let self else { return 0 }
            // Authentication starts a fresh generation even if the previous
            // disconnect is still waiting in the main-queue publisher. The
            // returned token travels with that publication, so stale UI
            // events cannot invalidate a newer authenticated session.
            self.inboundAdmission.begin()
            return self.inboundAdmission.currentGeneration()
        }
        connectionObservation = secureSession.connectionPublicationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] publication in
                self?.connectionChanged(publication)
            }
    }

    func requestControl() {
        guard !isStoppingForQuit else { return }
        guard localControlAllowed() else {
            status = "This Mac has no physical keyboard/mouse path in the selected topology"
            return
        }
        guard !isRemoteInputTearingDown else {
            status = "Wait for remote input to finish returning locally"
            return
        }
        guard secureSession.connectedPeerID != nil else {
            status = "Connect to a paired Mac first"
            return
        }
        guard pendingIncomingControlRequest == nil,
              preparingIncomingControlRequest == nil else {
            status = "Respond to the incoming control request first"
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
                ControlMessage.requestControl(
                    requestID: requestID,
                    keyboardLayoutIdentifier: keyboardLayoutIdentifier()
                )
            )
            scheduleRequestTimeout()
        } catch {
            status = "Control can only start from the connected state"
        }
    }

    func stopControl(reason: String = "Control returned locally") {
        if isReceivingControl {
            endReceivingControl(reason: reason)
            return
        }
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

    /// Accepts the exact incoming request currently shown by the UI. Input is
    /// enabled on the injection queue before the grant is sent to the peer.
    func acceptIncomingControlRequest(_ requestID: UUID) {
        guard !isStoppingForQuit else { return }
        guard !isRemoteInputTearingDown else {
            status = "Wait for remote input to finish returning locally"
            return
        }
        guard let request = pendingIncomingControlRequest,
              request.id == requestID else {
            return
        }
        incomingRequestTimeout?.cancel()
        incomingRequestTimeout = nil
        pendingIncomingControlRequest = nil

        inputSink.refreshPermission()
        guard inputSink.hasAccessibilityPermission else {
            rejectIncomingControlRequest(
                request,
                reason: "Denied remote control: Accessibility permission is missing"
            )
            return
        }
        guard secureSession.connectedPeerID == request.peerID else {
            status = "Control request expired because the secure session changed"
            return
        }

        preparingIncomingControlRequest = request
        status = "Preparing to receive remote control…"
        inputSink.beginRemoteControl { [weak self] didStart in
            self?.completeIncomingControlAcceptance(
                request,
                didStart: didStart
            )
        }
    }

    /// Denies the exact incoming request currently shown by the UI.
    func denyIncomingControlRequest(_ requestID: UUID) {
        guard !isStoppingForQuit else { return }
        guard let request = pendingIncomingControlRequest,
              request.id == requestID else {
            return
        }
        rejectIncomingControlRequest(
            request,
            reason: "The incoming control request was denied"
        )
    }

    /// Ends a remote-control session from the receiving Mac. It immediately
    /// stops accepting new events; held keys and buttons are released before
    /// the peer is notified that control has ended.
    func endReceivingControl(reason: String = "Remote control ended locally") {
        guard !isStoppingForQuit else { return }
        guard let request = activeInboundControlRequest,
              isReceivingControl else {
            return
        }
        finishReceivingControl(
            request,
            reason: reason,
            notifyPeer: true
        )
    }

    /// Stops every local control path before app termination. The final monitor
    /// route belongs to the caller, so a receiver shutdown cannot queue its
    /// usual remote-display route after the app has asked for the local route.
    func stopForQuit(completion: @escaping () -> Void) {
        guard !isStoppingForQuit else { return }
        isStoppingForQuit = true
        requestTimeout?.cancel()
        requestTimeout = nil
        incomingRequestTimeout?.cancel()
        incomingRequestTimeout = nil
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

        if let request = pendingIncomingControlRequest {
            pendingIncomingControlRequest = nil
            sendResponse(kind: .controlDenied, for: request)
        }
        if let request = preparingIncomingControlRequest {
            preparingIncomingControlRequest = nil
            sendResponse(kind: .controlDenied, for: request)
        }

        if var teardown = receiverTeardown {
            teardown.restoreMonitor = false
            teardown.completions.append(completion)
            receiverTeardown = teardown
            status = "MacKVM is quitting"
            return
        }

        if let request = activeInboundControlRequest,
           isReceivingControl {
            finishReceivingControl(
                request,
                reason: "MacKVM is quitting",
                notifyPeer: true,
                restoreMonitor: false,
                completion: completion
            )
            return
        }

        isReceivingControl = false
        activeInboundControlRequest = nil
        endTransientRemoteInput(completion: completion)
        status = "MacKVM is quitting"
    }

    private func receive(_ data: Data) {
        let admission = inboundAdmission.reserve()
        guard admission.accepted else {
            if admission.shouldSignalFailure {
                // Control messages include state transitions and key/button
                // releases. Once the main queue cannot keep up, terminate
                // the encrypted session instead of silently losing ordering.
                secureSession.disconnect()
            }
            return
        }
        let message: ControlMessage
        do {
            message = try ControlMessageCodec.decode(data)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.inboundAdmission.release(admission)
                self?.status = "Rejected an invalid control message"
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isCurrent = self.inboundAdmission.isCurrent(admission)
            self.inboundAdmission.release(admission)
            guard isCurrent else { return }
            self.handle(message)
        }
    }

    private func handle(_ message: ControlMessage) {
        guard !isStoppingForQuit else { return }
        switch message.kind {
        case .requestControl:
            guard let requestID = message.requestID else { return }
            handleControlRequest(message: message, requestID: requestID)
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
            if let request = pendingIncomingControlRequest,
               message.requestID == request.id {
                cancelIncomingControlRequest(
                    request,
                    reason: "The other Mac cancelled its control request"
                )
            }
            if let request = preparingIncomingControlRequest,
               message.requestID == request.id {
                cancelIncomingControlRequest(
                    request,
                    reason: "The other Mac cancelled its control request"
                )
            }
            if let request = activeInboundControlRequest,
               message.requestID == request.id,
               isReceivingControl {
                finishReceivingControl(
                    request,
                    reason: "The other Mac returned control",
                    notifyPeer: false
                )
            }
        case .input:
            if let input = message.input,
               message.requestID == activeInboundControlRequest?.id,
               isReceivingControl {
                inputSink.receive(input)
            }
        }
    }

    private func handleControlRequest(
        message: ControlMessage,
        requestID: UUID
    ) {
        guard let peerID = secureSession.connectedPeerID else {
            status = "Ignored a control request without a secure session"
            return
        }
        let request = IncomingControlRequest(id: requestID, peerID: peerID)
        guard ControlProtocolCompatibility.isCompatible(
            remoteVersion: message.protocolVersion,
            remoteMinimumVersion: message.minimumProtocolVersion
        ) else {
            sendResponse(kind: .controlDenied, for: request)
            status = "Denied control: the other Mac uses an incompatible protocol"
            return
        }
        // A differing keyboard layout no longer denies the request outright:
        // RemoteInputSink resolves each remappable key to its equivalent on
        // this layout, and ends control only if a specific key turns out to
        // have no equivalent here.
        guard !isRemoteInputTearingDown else {
            sendResponse(kind: .controlDenied, for: request)
            status = "Denied a control request while remote input is returning locally"
            return
        }
        guard !isReceivingControl else {
            sendResponse(
                kind: .controlDenied,
                for: request
            )
            status = "Denied a second request while remote control is active"
            return
        }
        if pendingIncomingControlRequest?.id == requestID
            || preparingIncomingControlRequest?.id == requestID {
            return
        }
        guard pendingIncomingControlRequest == nil,
              preparingIncomingControlRequest == nil else {
            sendResponse(kind: .controlDenied, for: request)
            status = "Denied a second control request while another is pending"
            return
        }
        inputSink.refreshPermission()
        guard inputSink.hasAccessibilityPermission else {
            sendResponse(
                kind: .controlDenied,
                for: request
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
                sendResponse(
                    kind: .controlDenied,
                    for: request
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
        pendingIncomingControlRequest = request
        status = "The other Mac requests control — choose Allow or Deny"
        scheduleIncomingRequestTimeout(for: request)
        onIncomingControlRequest?(request)
    }

    private func completeIncomingControlAcceptance(
        _ request: IncomingControlRequest,
        didStart: Bool
    ) {
        guard preparingIncomingControlRequest?.id == request.id else {
            if didStart {
                endTransientRemoteInput()
            }
            return
        }
        preparingIncomingControlRequest = nil

        guard didStart else {
            rejectIncomingControlRequest(
                request,
                reason: "Denied remote control: Accessibility permission is missing"
            )
            return
        }
        guard secureSession.connectedPeerID == request.peerID else {
            endTransientRemoteInput()
            status = "Control request expired because the secure session changed"
            return
        }

        activeInboundControlRequest = request
        isReceivingControl = true
        onReceivingStarted?()
        sendResponse(kind: .controlGranted, for: request)
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

    private func connectionChanged(
        _ publication: ControlConnectionPublication
    ) {
        let peerID = publication.peerID
        if let publicationGeneration = publication.admissionGeneration,
           publicationGeneration < inboundAdmission.currentGeneration() {
            return
        }
        let isSamePeer = hasObservedConnectionState
            && observedConnectedPeerID == peerID
        let isNewSessionGeneration = isSamePeer
            && peerID != nil
            && publication.admissionGeneration != nil
            && publication.admissionGeneration != observedAdmissionGeneration
        guard !isSamePeer || isNewSessionGeneration else {
            return
        }
        hasObservedConnectionState = true
        observedConnectedPeerID = peerID
        if peerID == nil {
            inboundAdmission.invalidate(
                ifCurrentGeneration: observedAdmissionGeneration
            )
            observedAdmissionGeneration = nil
        } else {
            // SecureSessionService already applies a byte/packet budget, but
            // keep a second bounded gate at the UI boundary. This prevents a
            // burst of valid messages from creating an unbounded main-queue
            // backlog that could delay consent or teardown actions.
            inboundAdmission.activate()
            observedAdmissionGeneration = publication.admissionGeneration
                ?? inboundAdmission.currentGeneration()
        }
        let wasControlling = state == .controlling
        requestTimeout?.cancel()
        requestTimeout = nil
        incomingRequestTimeout?.cancel()
        incomingRequestTimeout = nil
        activeOutboundRequestID = nil
        pendingIncomingControlRequest = nil
        preparingIncomingControlRequest = nil
        if wasControlling {
            onControllingStopped?()
        }
        if var teardown = receiverTeardown {
            teardown.restoreMonitor = false
            receiverTeardown = teardown
        } else if let request = activeInboundControlRequest,
           isReceivingControl {
            finishReceivingControl(
                request,
                reason: peerID == nil
                    ? "Secure session disconnected; input is local"
                    : "Secure session changed; input is local",
                notifyPeer: false
            )
        } else if !isRemoteInputTearingDown {
            endTransientRemoteInput()
        }
        activeInboundControlRequest = nil
        if peerID == nil {
            inputCapture.stopCapture()
            isReceivingControl = false
            _ = try? machine.handle(.transportDisconnected)
            state = machine.state
            status = "Secure session disconnected; input is local"
        } else {
            if state == .controlling || state == .suspended {
                inputCapture.stopCapture()
            }
            isReceivingControl = false
            _ = try? machine.handle(.transportConnected)
            state = machine.state
            status = "Secure session connected; input is local"
        }
    }

    private func remoteInputSinkFailed(_ failure: ControlInputFailure) {
        guard let request = activeInboundControlRequest,
              isReceivingControl else {
            return
        }
        let reason: String
        switch failure {
        case .accessibilityPermission:
            reason = "Remote control ended because Accessibility is unavailable"
        case .queueOverloaded:
            reason = "Remote control ended because the input queue was overloaded"
        case .keyboardLayoutMismatch:
            reason = "Remote control ended because the keyboard layout changed"
        }
        finishReceivingControl(
            request,
            reason: reason,
            notifyPeer: true
        )
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
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.controlRequestTimeout,
            execute: timeout
        )
    }

    private func scheduleIncomingRequestTimeout(
        for request: IncomingControlRequest
    ) {
        incomingRequestTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.pendingIncomingControlRequest?.id == request.id else {
                return
            }
            self.rejectIncomingControlRequest(
                request,
                reason: "Incoming control request timed out and was denied"
            )
        }
        incomingRequestTimeout = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.controlRequestTimeout,
            execute: timeout
        )
    }

    private func rejectIncomingControlRequest(
        _ request: IncomingControlRequest,
        reason: String
    ) {
        incomingRequestTimeout?.cancel()
        incomingRequestTimeout = nil
        if pendingIncomingControlRequest?.id == request.id {
            pendingIncomingControlRequest = nil
        }
        if preparingIncomingControlRequest?.id == request.id {
            preparingIncomingControlRequest = nil
            endTransientRemoteInput()
        }
        sendResponse(kind: .controlDenied, for: request)
        status = reason
    }

    private func cancelIncomingControlRequest(
        _ request: IncomingControlRequest,
        reason: String
    ) {
        incomingRequestTimeout?.cancel()
        incomingRequestTimeout = nil
        if pendingIncomingControlRequest?.id == request.id {
            pendingIncomingControlRequest = nil
        }
        if preparingIncomingControlRequest?.id == request.id {
            preparingIncomingControlRequest = nil
            endTransientRemoteInput()
        }
        status = reason
    }

    private func finishReceivingControl(
        _ request: IncomingControlRequest,
        reason: String,
        notifyPeer: Bool,
        restoreMonitor: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        guard isReceivingControl,
              activeInboundControlRequest?.id == request.id else {
            return
        }
        isReceivingControl = false
        activeInboundControlRequest = nil
        isRemoteInputTearingDown = true
        receiverTeardown = ReceiverTeardown(
            request: request,
            phase: .releasingInput,
            notifyPeer: notifyPeer,
            restoreMonitor: restoreMonitor,
            completions: completion.map { [$0] } ?? []
        )
        inputSink.endRemoteControl { [weak self] in
            self?.completeReceiverInputRelease(for: request.id)
        }
        status = reason
    }

    private func completeReceiverInputRelease(for requestID: UUID) {
        guard var teardown = receiverTeardown,
              teardown.request.id == requestID,
              teardown.phase == .releasingInput else {
            return
        }
        guard teardown.restoreMonitor, !isStoppingForQuit else {
            completeReceiverTeardown(teardown)
            return
        }
        teardown.phase = .restoringMonitor
        receiverTeardown = teardown
        let routeCompleted: () -> Void = { [weak self] in
            guard let self else { return }
            self.completeReceiverMonitorRestoration(for: requestID)
        }
        if let onReceivingStopped {
            onReceivingStopped(routeCompleted)
        } else {
            routeCompleted()
        }
    }

    private func completeReceiverMonitorRestoration(for requestID: UUID) {
        guard let teardown = receiverTeardown,
              teardown.request.id == requestID,
              teardown.phase == .restoringMonitor else {
            return
        }
        completeReceiverTeardown(teardown)
    }

    private func completeReceiverTeardown(_ teardown: ReceiverTeardown) {
        guard receiverTeardown?.request.id == teardown.request.id else {
            return
        }
        receiverTeardown = nil
        isRemoteInputTearingDown = false
        if teardown.notifyPeer {
            sendResponse(kind: .endControl, for: teardown.request)
        }
        teardown.completions.forEach { $0() }
    }

    /// Cleans up a cancelled incoming acceptance or a connection transition.
    /// A live receiver uses `ReceiverTeardown` above, which also waits for its
    /// monitor route before allowing another session to begin.
    private func endTransientRemoteInput(completion: (() -> Void)? = nil) {
        guard receiverTeardown == nil else { return }
        if let completion {
            transientRemoteInputTeardownCompletions.append(completion)
        }
        guard !isRemoteInputTearingDown else { return }
        isRemoteInputTearingDown = true
        inputSink.endRemoteControl { [weak self] in
            guard let self else { return }
            let completions = transientRemoteInputTeardownCompletions
            transientRemoteInputTeardownCompletions.removeAll()
            isRemoteInputTearingDown = false
            completions.forEach { $0() }
        }
    }

    private func sendResponse(
        kind: ControlMessageKind,
        for request: IncomingControlRequest
    ) {
        guard secureSession.connectedPeerID == request.peerID else {
            return
        }
        send(
            ControlMessage(
                kind: kind,
                requestID: request.id
            )
        )
    }

    private func send(_ message: ControlMessage) {
        do {
            secureSession.send(try ControlMessageCodec.encode(message))
        } catch {
            status = "Could not encode the control message"
        }
    }
}
