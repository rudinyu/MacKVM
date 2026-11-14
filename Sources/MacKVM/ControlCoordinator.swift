import Combine
import Foundation
import MacKVMCore

struct IncomingControlRequest: Identifiable, Equatable {
    let id: UUID
    let peerID: UUID
    let managesDisplayRoute: Bool
    let supportsClipboard: Bool?
    let clipboardEnabled: Bool?

    init(
        id: UUID,
        peerID: UUID,
        managesDisplayRoute: Bool = true,
        supportsClipboard: Bool? = nil,
        clipboardEnabled: Bool? = nil
    ) {
        self.id = id
        self.peerID = peerID
        self.managesDisplayRoute = managesDisplayRoute
        self.supportsClipboard = supportsClipboard
        self.clipboardEnabled = clipboardEnabled
    }
}

enum ControlOwnershipTransition: Equatable {
    case outboundControl(peerID: UUID)
    case inboundControl(peerID: UUID)
    case returnedLocally
}

enum ControlInputFailure {
    case accessibilityPermission
    case queueOverloaded
    case keyboardLayoutMismatch
    case eventInjectionFailed
}

struct ControlConnectionPublication: Equatable {
    let peerID: UUID?
    let admissionGeneration: UInt64?
}

struct SecureSessionPeerPublication: Equatable {
    let peerID: UUID
    let isConnected: Bool
    let admissionGeneration: UInt64?
}

private struct ControlPeerSession: Equatable {
    let peerID: UUID
    let generation: UInt64
}

private struct IncomingRequestSessionKey: Hashable {
    let requestID: UUID
    let peerID: UUID
}

/// Narrow abstractions keep the consent coordinator testable without changing
/// the production secure-session or input-service implementations.
protocol ControlSessionTransport: AnyObject {
    var connectedPeerID: UUID? { get }
    var connectedPeerIDs: Set<UUID> { get }
    var connectedPeerIDPublisher: AnyPublisher<UUID?, Never> { get }
    var connectionPublicationPublisher:
        AnyPublisher<ControlConnectionPublication, Never> { get }
    var peerConnectionPublicationPublisher:
        AnyPublisher<SecureSessionPeerPublication, Never> { get }
    var onPayload: ((UUID, UInt64, Data) -> Void)? { get set }
    var onAuthenticated: ((UUID) -> UInt64)? { get set }
    var onHeartbeat: ((UUID, UInt64, SecureSessionHeartbeatAcknowledgement) -> Void)? {
        get set
    }

    func isConnected(to peerID: UUID) -> Bool
    func selectPeer(_ peerID: UUID)
    func send(_ payload: Data, to peerID: UUID)
    func disconnect()
    func disconnect(_ peerID: UUID)
}

protocol ControlInputCapture: AnyObject {
    var hasInputMonitoringPermission: Bool { get }
    var isCapturing: Bool { get }
    var onEvent: ((RemoteInputEvent) -> Void)? { get set }
    var onPermissionRevoked: (() -> Void)? { get set }
    var onEmergencyStop: (() -> Void)? { get set }
    var onSwitchControl: (() -> Void)? { get set }
    var onSwitchMonitor: (() -> Void)? { get set }
    var onCycleInputTarget: (() -> Void)? { get set }
    var onSelectInputTarget: ((Int) -> Void)? { get set }

    func refreshPermission()
    func startCapture(suppressingLocalEvents: Bool)
    func stopCapture()
}

protocol ControlInputSink: AnyObject {
    var hasAccessibilityPermission: Bool { get }
    var requiresFunctionalPermissionProbe: Bool { get }
    var permissionFailureStatus: String { get }
    var permissionDenialReason: String { get }
    var permissionFailureEndReason: String { get }
    var onControlFailure: ((ControlInputFailure) -> Void)? { get set }

    func refreshPermission()
    func beginRemoteControl(completion: @escaping (Bool) -> Void)
    func beginRemoteControl(
        stalePostingPermissionValidated: Bool,
        completion: @escaping (Bool) -> Void
    )
    func endRemoteControl(completion: @escaping () -> Void)
    func receive(_ input: RemoteInputEvent)
    /// Calls the completion after all input already queued for injection has
    /// run. The result is false when the sink is no longer accepting input.
    func awaitInputProcessing(completion: @escaping (Bool) -> Void)
}

extension ControlInputSink {
    var requiresFunctionalPermissionProbe: Bool { false }

    func beginRemoteControl(
        stalePostingPermissionValidated: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        beginRemoteControl(completion: completion)
    }

    var permissionFailureStatus: String {
        "Accessibility permission is required to control another device"
    }

    var permissionDenialReason: String {
        "Denied remote control: Accessibility permission is missing"
    }

    var permissionFailureEndReason: String {
        "Remote control ended because Accessibility is unavailable"
    }
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
    /// Fires only after input capture or injection has actually started, and
    /// when an active session has returned input locally.
    var onOwnershipTransition: ((ControlOwnershipTransition) -> Void)?
    /// Called synchronously when a pending incoming request is resolved or
    /// invalidated. Keeping the exact request here lets notification cleanup
    /// use request identity instead of inferring ownership from delayed
    /// @Published nil emissions.
    var onIncomingControlRequestResolved: ((IncomingControlRequest) -> Void)?

    private static let controlRequestTimeout: TimeInterval = 15
    private let localID: UUID
    private let secureSession: any ControlSessionTransport
    private let inputCapture: any ControlInputCapture
    private let inputSink: any ControlInputSink
    private let localControlAllowed: () -> Bool
    private let keyboardLayoutIdentifier: () -> String?
    private let seamlessControlAuthorized: (UUID) -> Bool
    private let clipboardSyncEnabled: (UUID) -> Bool
    private let clipboardSync: any ClipboardSyncManaging
    private let remoteInputPermissionProbe: any RuntimePermissionProbing
    private var machine = ControlSessionStateMachine()
    private var connectionObservation: AnyCancellable?
    private var peerConnectionObservation: AnyCancellable?
    private var requestTimeout: DispatchWorkItem?
    private var incomingRequestTimeout: DispatchWorkItem?
    private var activeOutboundRequestID: UUID?
    private var clipboardSyncIsActive = false
    private(set) var ownershipTransitionRevision: UInt64 = 0
    private var activeControlRequestCompletion: ((Bool) -> Void)?
    private var activeControlDisplayAlreadyRemote = false
    /// Whether MacKVM owns the display route for the active outbound session.
    /// Plain requests and the combined display-first flow switch the monitor
    /// themselves and must restore it when control ends. The manual-monitor
    /// hotkey (K) starts control after the user routed the display by hand,
    /// so its session must never trigger a DDC switch in either direction.
    private var activeControlManagesDisplayRoute = true
    private var activeInboundControlRequest: IncomingControlRequest?
    /// Published separately from `pendingIncomingControlRequest` because the
    /// request is cleared before Accessibility setup completes. Views must not
    /// treat that short preparation window as an idle, display-only state.
    @Published private(set) var isPreparingIncomingControl = false
    private var preparingIncomingControlRequest: IncomingControlRequest? {
        didSet {
            isPreparingIncomingControl = preparingIncomingControlRequest != nil
        }
    }
    private var incomingAuthorizationGeneration: UInt64 = 0
    private var preparingIncomingAuthorizationGeneration: UInt64?
    private var pendingRemoteInputPermissionProbe:
        (generation: UInt64, operation: any RuntimePermissionProbeResource)?
    private var receiverTeardown: ReceiverTeardown?
    private var transientRemoteInputTeardownCompletions: [() -> Void] = []
    private struct PendingHeartbeatAcknowledgement {
        let session: ControlPeerSession
        let acknowledgement: SecureSessionHeartbeatAcknowledgement
    }
    private var pendingHeartbeatAcknowledgements:
        [PendingHeartbeatAcknowledgement] = []
    private var isStoppingForQuit = false
    private var observedSelectedPeerID: UUID?
    private var observedSelectedAdmissionGeneration: UInt64?
    private let peerAdmissionLock = NSLock()
    private var inboundAdmissions: [UUID: BoundedAdmissionGate] = [:]
    private var incomingRequestSessions: [IncomingRequestSessionKey: ControlPeerSession] = [:]
    private var activeOutboundSession: ControlPeerSession?
    private var activeInboundSession: ControlPeerSession?

    deinit {
        pendingRemoteInputPermissionProbe?.operation.cancel()
    }

    /// Captures the app-owned display route that should be restored before
    /// termination. The caller must read this before `stopForQuit` clears the
    /// active session state. Manual routes and idle sessions are not owned by
    /// MacKVM, so they deliberately produce no termination route.
    var displayRouteRoleForTermination: DisplayRouteRole? {
        if let request = activeInboundControlRequest,
           isReceivingControl,
           request.managesDisplayRoute {
            return .remote
        }
        if let teardown = receiverTeardown,
           teardown.request.managesDisplayRoute || teardown.restoreMonitor {
            return .remote
        }
        guard activeControlManagesDisplayRoute else { return nil }
        if state == .controlling
            || (state == .suspended && activeControlDisplayAlreadyRemote) {
            return .local
        }
        return nil
    }

    init(
        localID: UUID,
        secureSession: any ControlSessionTransport,
        inputCapture: any ControlInputCapture,
        inputSink: any ControlInputSink,
        localControlAllowed: @escaping () -> Bool = { true },
        keyboardLayoutIdentifier: @escaping () -> String? = { nil },
        seamlessControlAuthorized: @escaping (UUID) -> Bool = { _ in false },
        clipboardSyncEnabled: @escaping (UUID) -> Bool = { _ in false },
        clipboardSync: any ClipboardSyncManaging = PasteboardClipboardSyncService(),
        remoteInputPermissionProbe: any RuntimePermissionProbing =
            CoreGraphicsRemoteInputPermissionProbe()
    ) {
        self.localID = localID
        self.secureSession = secureSession
        self.inputCapture = inputCapture
        self.inputSink = inputSink
        self.localControlAllowed = localControlAllowed
        self.keyboardLayoutIdentifier = keyboardLayoutIdentifier
        self.seamlessControlAuthorized = seamlessControlAuthorized
        self.clipboardSyncEnabled = clipboardSyncEnabled
        self.clipboardSync = clipboardSync
        self.remoteInputPermissionProbe = remoteInputPermissionProbe
        inputCapture.onEvent = { [weak self] event in
            guard let self,
                  state == .controlling,
                  let requestID = activeOutboundRequestID,
                  let session = activeOutboundSession else {
                return
            }
            send(
                .input(event, requestID: requestID),
                to: session,
                requiringSelection: true
            )
        }
        clipboardSync.onLocalTextChange = { [weak self] text in
            self?.sendClipboardText(text)
        }
        inputCapture.onEmergencyStop = { [weak self] in
            self?.stopControl(reason: "Emergency shortcut returned input locally")
        }
        inputCapture.onPermissionRevoked = { [weak self] in
            guard let self,
                  state == .controlling || state == .suspended else {
                return
            }
            stopControl(
                reason: "Control ended because required system-reported input access was lost"
            )
        }
        inputCapture.onSwitchControl = { [weak self] in
            self?.toggleControlFromManualMonitorHotKey()
        }
        inputSink.onControlFailure = { [weak self] failure in
            self?.remoteInputSinkFailed(failure)
        }
        secureSession.onPayload = { [weak self] peerID, generation, data in
            self?.receive(data, from: ControlPeerSession(
                peerID: peerID,
                generation: generation
            ))
        }
        secureSession.onHeartbeat = { [weak self] peerID, generation, acknowledgement in
            guard let self else {
                acknowledgement.complete()
                return
            }
            self.acknowledgeHeartbeatAfterControlPathProgress(
                acknowledgement,
                from: ControlPeerSession(
                    peerID: peerID,
                    generation: generation
                )
            )
        }
        secureSession.onAuthenticated = { [weak self] peerID in
            guard let self else { return 0 }
            return self.beginInboundSession(for: peerID)
        }
        connectionObservation = secureSession.connectionPublicationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] publication in
                self?.connectionChanged(publication)
            }
        peerConnectionObservation = secureSession.peerConnectionPublicationPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] publication in
                self?.peerConnectionChanged(publication)
            }
    }

    private func admissionGate(for peerID: UUID) -> BoundedAdmissionGate {
        peerAdmissionLock.lock()
        defer { peerAdmissionLock.unlock() }
        if let gate = inboundAdmissions[peerID] {
            return gate
        }
        // A session may deliver its first authenticated payload before the
        // main-queue connection publication. Keep that narrow race open, then
        // let the authentication callback advance the peer's generation.
        let gate = BoundedAdmissionGate(
            capacity: BoundedAdmissionGate.defaultCapacity,
            initiallyEnabled: true
        )
        inboundAdmissions[peerID] = gate
        return gate
    }

    private func beginInboundSession(for peerID: UUID) -> UInt64 {
        let gate = admissionGate(for: peerID)
        gate.begin()
        return gate.currentGeneration()
    }

    private func currentSession(for peerID: UUID) -> ControlPeerSession {
        ControlPeerSession(
            peerID: peerID,
            generation: admissionGate(for: peerID).currentGeneration()
        )
    }

    private func isCurrentSession(
        _ session: ControlPeerSession,
        requiringSelection: Bool = false
    ) -> Bool {
        guard admissionGate(for: session.peerID).currentGeneration()
                == session.generation,
              secureSession.isConnected(to: session.peerID) else {
            return false
        }
        return !requiringSelection
            || secureSession.connectedPeerID == session.peerID
    }

    /// Performs the same side-effect-free admission checks used immediately
    /// before sending a control request. App-level routes (including the
    /// display-first global shortcut) call this before changing the monitor,
    /// so a disconnected or permission-blocked request cannot move the
    /// physical display and then fail.
    @discardableResult
    func canRequestControl() -> Bool {
        guard !isStoppingForQuit else {
            return false
        }
        guard localControlAllowed() else {
            status = "Local input sharing is disabled in the selected topology"
            return false
        }
        guard !isRemoteInputTearingDown else {
            status = "Wait for remote input to finish returning locally"
            return false
        }
        guard let peerID = secureSession.connectedPeerID,
              secureSession.isConnected(to: peerID) else {
            status = "Connect to a paired Mac first"
            return false
        }
        guard pendingIncomingControlRequest == nil,
              preparingIncomingControlRequest == nil else {
            status = "Respond to the incoming control request first"
            return false
        }
        guard !isReceivingControl else {
            status = "This Mac is currently being controlled"
            return false
        }
        guard state == .connected else {
            status = "Control can only start from the connected state"
            return false
        }
        inputCapture.refreshPermission()
        guard inputCapture.hasInputMonitoringPermission else {
            status = "Input Monitoring permission is required"
            return false
        }
        // The controlling Mac uses an active CGEvent tap so local events can
        // be suppressed while they are forwarded. macOS requires
        // Accessibility for that active filter in addition to Input
        // Monitoring. The receiving Mac checks Accessibility and functionally
        // validates event posting when its preflight looks stale.
        inputSink.refreshPermission()
        guard inputSink.hasAccessibilityPermission else {
            status = inputSink.permissionFailureStatus
            return false
        }
        return true
    }

    @discardableResult
    func requestControl(
        displayAlreadyRemote: Bool = false,
        managesDisplayRoute: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard canRequestControl() else {
            completion?(false)
            return false
        }
        guard let peerID = secureSession.connectedPeerID,
              secureSession.isConnected(to: peerID) else {
            completion?(false)
            return false
        }
        let session = currentSession(for: peerID)
        guard isCurrentSession(session, requiringSelection: true) else {
            status = "Connect to a paired Mac first"
            completion?(false)
            return false
        }
        do {
            let requestID = UUID()
            state = try machine.handle(.requestControl)
            activeOutboundRequestID = requestID
            activeOutboundSession = session
            activeControlRequestCompletion = completion
            activeControlDisplayAlreadyRemote = displayAlreadyRemote
            activeControlManagesDisplayRoute = managesDisplayRoute
            status = "Waiting for the other device to grant control…"
            send(
                ControlMessage.requestControl(
                    requestID: requestID,
                    keyboardLayoutIdentifier: keyboardLayoutIdentifier(),
                    managesDisplayRoute: managesDisplayRoute,
                    clipboardEnabled: clipboardSyncEnabled(peerID)
                ),
                to: session
            )
            scheduleRequestTimeout()
            return true
        } catch {
            status = "Control can only start from the connected state"
            completion?(false)
            return false
        }
    }

    /// Toggles the keyboard/mouse route from a normal control action. This
    /// variant may start the display lifecycle callback when the caller has
    /// not selected the monitor route in advance.
    func toggleControlFromHotKey() {
        toggleControlFromHotKey(displayAlreadyRemote: false)
    }

    /// Toggles keyboard/mouse ownership after the user has manually selected
    /// the monitor input. Marking the request as pre-routed prevents the grant
    /// callback from starting the automatic DDC display route, which belongs
    /// to the O/Show other device flow.
    func toggleControlFromManualMonitorHotKey() {
        toggleControlFromHotKey(displayAlreadyRemote: true)
    }

    private func toggleControlFromHotKey(displayAlreadyRemote: Bool) {
        if isReceivingControl {
            endReceivingControl(
                reason: "Hotkey returned keyboard, mouse, and trackpad locally"
            )
            return
        }
        if state == .controlling || state == .suspended {
            stopControl(reason: "Hotkey returned keyboard, mouse, and trackpad locally")
            return
        }
        // The manual-monitor variant starts control on a display the user
        // routed by hand; that session never owns the DDC route.
        _ = requestControl(
            displayAlreadyRemote: displayAlreadyRemote,
            managesDisplayRoute: !displayAlreadyRemote
        )
    }

    private func completeActiveControlRequest(_ succeeded: Bool) {
        guard let completion = activeControlRequestCompletion else { return }
        activeControlRequestCompletion = nil
        completion(succeeded)
    }

    /// Normal termination honors the session's display ownership. O is an
    /// explicit display-and-input return even if K started the session.
    func stopControl(
        reason: String = "Control returned locally",
        returnDisplayLocally: Bool = false,
        preserveDisplayRoute: Bool = false
    ) {
        if isReceivingControl {
            endReceivingControl(reason: reason)
            return
        }
        // Escape can be pressed while the receiver's Accessibility setup is
        // still completing. Clear that request before the asynchronous
        // beginRemoteControl callback returns, otherwise the callback could
        // grant remote input after the user explicitly asked to stop.
        if let incomingRequest = preparingIncomingControlRequest
            ?? pendingIncomingControlRequest {
            rejectIncomingControlRequest(
                incomingRequest,
                reason: reason
            )
        }
        let wasControlling = state == .controlling
        let wasWaitingForControlGrant = state == .suspended
        stopClipboardSync()
        // A combined request has already switched the monitor before it
        // enters the suspended state. Its request completion owns the local
        // DDC restoration when that request is cancelled or times out. Keep
        // the normal stop callback for requests that have not been
        // pre-routed, but do not enqueue a second restoration operation.
        let displayWasAlreadyRemote = activeControlDisplayAlreadyRemote
        let sessionManagedDisplayRoute = activeControlManagesDisplayRoute
        requestTimeout?.cancel()
        requestTimeout = nil
        inputCapture.stopCapture()
        if state == .controlling || state == .suspended {
            let requestID = activeOutboundRequestID
            let session = activeOutboundSession
            _ = try? machine.handle(.stopControl)
            state = machine.state
            activeOutboundRequestID = nil
            activeOutboundSession = nil
            activeControlDisplayAlreadyRemote = false
            activeControlManagesDisplayRoute = true
            if let requestID, let session {
                send(
                    ControlMessage(
                        kind: .endControl,
                        requestID: requestID
                    ),
                    to: session
                )
            }
        }
        if wasWaitingForControlGrant {
            completeActiveControlRequest(false)
        }
        // A live manual-monitor (K) session must end input without touching
        // the display the user routed by hand; the plain and combined routes
        // still restore the local display here.
        if !preserveDisplayRoute
            && ((wasControlling
                    && (sessionManagedDisplayRoute || returnDisplayLocally))
                || (wasWaitingForControlGrant
                    && ((sessionManagedDisplayRoute
                            && !displayWasAlreadyRemote)
                        || returnDisplayLocally))) {
            onControllingStopped?()
        }
        if wasControlling {
            notifyOwnershipTransition(.returnedLocally)
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
            status = "Control request expired before Allow was selected"
            return
        }
        guard let session = sessionBinding(for: request),
              isCurrentSession(session) else {
            cancelIncomingControlRequest(
                request,
                reason: "Control request expired because the secure session changed"
            )
            return
        }
        incomingRequestTimeout?.cancel()
        incomingRequestTimeout = nil
        resolvePendingIncomingControlRequest(request)

        inputSink.refreshPermission()
        guard inputSink.hasAccessibilityPermission else {
            rejectIncomingControlRequest(
                request,
                reason: inputSink.permissionDenialReason
            )
            return
        }
        let authorizationGeneration = beginIncomingAuthorizationGeneration()
        preparingIncomingControlRequest = request
        preparingIncomingAuthorizationGeneration = authorizationGeneration
        status = "Preparing to receive remote control…"
        if inputSink.requiresFunctionalPermissionProbe {
            let operation = remoteInputPermissionProbe.start {
                [weak self] passed in
                DispatchQueue.main.async {
                    self?.completeIncomingPermissionProbe(
                        for: request,
                        generation: authorizationGeneration,
                        passed: passed
                    )
                }
            }
            pendingRemoteInputPermissionProbe = (
                authorizationGeneration,
                operation
            )
            return
        }
        beginRemoteInput(for: request, generation: authorizationGeneration)
    }

    /// Denies the exact incoming request currently shown by the UI.
    func denyIncomingControlRequest(_ requestID: UUID) {
        guard !isStoppingForQuit else { return }
        guard let request = pendingIncomingControlRequest,
              request.id == requestID else {
            status = "Control request expired before Deny was selected"
            return
        }
        rejectIncomingControlRequest(
            request,
            reason: "The incoming control request was denied"
        )
    }

    /// Fences a pending consent or stale-permission probe synchronously before
    /// trust revocation is queued on the secure-session transport.
    func cancelIncomingControlRequestForRevokedPeer(_ peerID: UUID) {
        guard let request = preparingIncomingControlRequest
                ?? pendingIncomingControlRequest,
              request.peerID == peerID else {
            return
        }
        cancelIncomingControlRequest(
            request,
            reason: "Control request expired because the paired Mac was forgotten"
        )
    }

    /// Ends a remote-control session from the receiving Mac. It immediately
    /// stops accepting new events; held keys and buttons are released before
    /// the peer is notified that control has ended.
    func endReceivingControl(
        reason: String = "Remote control ended locally",
        restoreMonitor: Bool = true,
        forceDisplayRouteRestoration: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard !isStoppingForQuit else { return }
        guard let request = activeInboundControlRequest,
              isReceivingControl else {
            completion?()
            return
        }
        finishReceivingControl(
            request,
            reason: reason,
            notifyPeer: true,
            restoreMonitor: restoreMonitor,
            forceDisplayRouteRestoration: forceDisplayRouteRestoration,
            completion: completion
        )
    }

    /// Queues a local monitor route behind any in-flight input teardown. A
    /// receiver normally restores the controller's display after releasing
    /// input; an emergency local-return request must not race that callback
    /// and leave the monitor on the remote input.
    func requestLocalMonitorReturn(completion: @escaping () -> Void) {
        if var teardown = receiverTeardown {
            teardown.restoreMonitor = false
            teardown.completions.append(completion)
            receiverTeardown = teardown
            return
        }
        if isRemoteInputTearingDown {
            transientRemoteInputTeardownCompletions.append(completion)
            return
        }
        completion()
    }

    /// Stops every local control path before app termination. The app captures
    /// any owned display route before calling this method, waits for input
    /// teardown here, then performs the role-appropriate route itself.
    func stopForQuit(completion: @escaping () -> Void) {
        guard !isStoppingForQuit else { return }
        isStoppingForQuit = true
        stopClipboardSync()
        requestTimeout?.cancel()
        requestTimeout = nil
        incomingRequestTimeout?.cancel()
        incomingRequestTimeout = nil
        inputCapture.stopCapture()

        let wasWaitingForControlGrant = state == .suspended
        if state == .controlling || state == .suspended {
            let requestID = activeOutboundRequestID
            let session = activeOutboundSession
            _ = try? machine.handle(.stopControl)
            state = machine.state
            activeOutboundRequestID = nil
            activeOutboundSession = nil
            activeControlDisplayAlreadyRemote = false
            activeControlManagesDisplayRoute = true
            if let requestID, let session {
                send(
                    ControlMessage(
                        kind: .endControl,
                        requestID: requestID
                    ),
                    to: session
                )
            }
        }
        if wasWaitingForControlGrant {
            completeActiveControlRequest(false)
        }

        if let request = pendingIncomingControlRequest {
            resolvePendingIncomingControlRequest(request)
            sendResponse(kind: .controlDenied, for: request)
        }
        if let request = preparingIncomingControlRequest {
            invalidateIncomingAuthorization()
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

    private func receive(
        _ data: Data,
        from session: ControlPeerSession
    ) {
        let gate = admissionGate(for: session.peerID)
        guard gate.currentGeneration() == session.generation else { return }
        let admission = gate.reserve()
        guard admission.accepted else {
            if admission.shouldSignalFailure {
                // Control messages include state transitions and key/button
                // releases. Once the main queue cannot keep up, terminate
                // only this encrypted session instead of silently losing
                // ordering for one peer while interrupting unrelated peers.
                secureSession.disconnect(session.peerID)
            }
            return
        }
        guard admission.generation == session.generation else {
            gate.release(admission)
            return
        }
        let message: ControlMessage
        do {
            message = try ControlMessageCodec.decode(data)
        } catch {
            DispatchQueue.main.async { [weak self] in
                gate.release(admission)
                guard let self, self.isCurrentSession(session) else { return }
                self.status = "Rejected an invalid control message"
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            defer { gate.release(admission) }
            guard let self else { return }
            guard gate.isCurrent(admission),
                  self.isCurrentSession(session) else { return }
            self.handle(message, from: session)
        }
    }

    /// A secure-session heartbeat must also pass through the same queues that
    /// deliver remote input. Otherwise the transport queue can continue to
    /// acknowledge heartbeats while the main or injection queue is stalled,
    /// leaving the controller with a live lease and no usable control path.
    private func acknowledgeHeartbeatAfterControlPathProgress(
        _ acknowledgement: SecureSessionHeartbeatAcknowledgement,
        from session: ControlPeerSession
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                acknowledgement.complete()
                return
            }
            guard !self.isStoppingForQuit else { return }
            guard self.isCurrentSession(session) else {
                acknowledgement.complete()
                return
            }
            guard !self.isRemoteInputTearingDown else {
                guard self.activeTeardownSession == session else {
                    acknowledgement.complete()
                    return
                }
                // During receiver teardown, deliberately retain this
                // acknowledgement. A stalled release/monitor-restoration path
                // must still let the peer's heartbeat lease expire, but a
                // teardown that completes normally should release the same
                // token below instead of making a healthy session wait for its
                // 15-second timeout.
                self.pendingHeartbeatAcknowledgements.append(
                    PendingHeartbeatAcknowledgement(
                        session: session,
                        acknowledgement: acknowledgement
                    )
                )
                return
            }
            guard self.isReceivingControl,
                  self.activeInboundSession == session else {
                // With no active receiver there is no remote-input queue to
                // prove. The secure session itself is still a valid lease.
                acknowledgement.complete()
                return
            }
            self.inputSink.awaitInputProcessing { [weak self] didProgress in
                DispatchQueue.main.async {
                    guard let self else {
                        acknowledgement.complete()
                        return
                    }
                    guard !self.isStoppingForQuit else { return }
                    guard self.isCurrentSession(session) else {
                        acknowledgement.complete()
                        return
                    }
                    if self.isRemoteInputTearingDown {
                        guard self.activeTeardownSession == session else {
                            acknowledgement.complete()
                            return
                        }
                        // Teardown may begin after the input barrier was
                        // queued but before its callback reaches the main
                        // queue. Re-evaluate this token when teardown finishes.
                        self.pendingHeartbeatAcknowledgements.append(
                            PendingHeartbeatAcknowledgement(
                                session: session,
                                acknowledgement: acknowledgement
                            )
                        )
                        return
                    }
                    if self.activeInboundSession != session
                        || didProgress
                        || !self.isReceivingControl {
                        acknowledgement.complete()
                    }
                }
            }
        }
    }

    private var activeTeardownSession: ControlPeerSession? {
        receiverTeardown.flatMap { sessionBinding(for: $0.request) }
    }

    private func completeDeferredHeartbeatAcknowledgements(
        for session: ControlPeerSession? = nil
    ) {
        guard !isRemoteInputTearingDown else { return }
        let acknowledgements: [PendingHeartbeatAcknowledgement]
        if let session {
            acknowledgements = pendingHeartbeatAcknowledgements.filter {
                $0.session == session
            }
            pendingHeartbeatAcknowledgements.removeAll {
                $0.session == session
            }
        } else {
            acknowledgements = pendingHeartbeatAcknowledgements
            pendingHeartbeatAcknowledgements.removeAll()
        }
        guard !isStoppingForQuit else { return }
        acknowledgements.forEach { $0.acknowledgement.complete() }
    }

    private func handle(
        _ message: ControlMessage,
        from session: ControlPeerSession
    ) {
        guard !isStoppingForQuit,
              isCurrentSession(session) else { return }
        switch message.kind {
        case .requestControl:
            guard let requestID = message.requestID else { return }
            handleControlRequest(
                message: message,
                requestID: requestID,
                session: session
            )
        case .controlGranted:
            guard session == activeOutboundSession,
                  message.requestID == activeOutboundRequestID else { return }
            handleControlGranted(message: message)
        case .controlDenied:
            guard state == .suspended,
                  session == activeOutboundSession,
                  message.requestID == activeOutboundRequestID else {
                return
            }
            requestTimeout?.cancel()
            _ = try? machine.handle(.stopControl)
            state = machine.state
            activeOutboundRequestID = nil
            activeOutboundSession = nil
            stopClipboardSync()
            activeControlDisplayAlreadyRemote = false
            activeControlManagesDisplayRoute = true
            completeActiveControlRequest(false)
            status = "The other device denied control"
        case .endControl:
            if session == activeOutboundSession,
               message.requestID == activeOutboundRequestID,
               (state == .controlling || state == .suspended) {
                let wasControlling = state == .controlling
                let wasWaitingForControlGrant = state == .suspended
                let sessionManagedDisplayRoute = activeControlManagesDisplayRoute
                requestTimeout?.cancel()
                requestTimeout = nil
                inputCapture.stopCapture()
                _ = try? machine.handle(.stopControl)
                state = machine.state
                activeOutboundRequestID = nil
                activeOutboundSession = nil
                stopClipboardSync()
                activeControlDisplayAlreadyRemote = false
                activeControlManagesDisplayRoute = true
                if wasWaitingForControlGrant {
                    completeActiveControlRequest(false)
                }
                // The peer ending a manual-monitor (K) session returns input
                // only; the display stays on the route the user set by hand.
                if wasControlling && sessionManagedDisplayRoute {
                    onControllingStopped?()
                }
                if wasControlling {
                    notifyOwnershipTransition(.returnedLocally)
                }
                status = "The other device ended control; input is local"
            }
            if let request = pendingIncomingControlRequest,
               message.requestID == request.id,
               sessionBinding(for: request) == session {
                cancelIncomingControlRequest(
                    request,
                    reason: "The other device cancelled its control request"
                )
            }
            if let request = preparingIncomingControlRequest,
               message.requestID == request.id,
               sessionBinding(for: request) == session {
                cancelIncomingControlRequest(
                    request,
                    reason: "The other device cancelled its control request"
                )
            }
            if let request = activeInboundControlRequest,
               message.requestID == request.id,
               activeInboundSession == session,
               isReceivingControl {
                finishReceivingControl(
                    request,
                    reason: "The other device returned control",
                    notifyPeer: false
                )
            }
        case .input:
            if let input = message.input,
               message.requestID == activeInboundControlRequest?.id,
               activeInboundSession == session,
               isReceivingControl {
                inputSink.receive(input)
            }
        case .clipboard:
            let matchesActiveRequest =
                (session == activeOutboundSession
                    && message.requestID == activeOutboundRequestID)
                    || (session == activeInboundSession
                        && message.requestID == activeInboundControlRequest?.id)
            if let text = message.clipboardText,
               clipboardSyncIsActive,
               matchesActiveRequest,
               (state == .controlling || isReceivingControl) {
                clipboardSync.receive(text)
            }
        }
    }

    private func handleControlRequest(
        message: ControlMessage,
        requestID: UUID,
        session: ControlPeerSession
    ) {
        let request = IncomingControlRequest(
            id: requestID,
            peerID: session.peerID,
            managesDisplayRoute: message.managesDisplayRoute ?? true,
            supportsClipboard: message.supportsClipboard,
            clipboardEnabled: message.clipboardEnabled
        )
        if let existing = preparingIncomingControlRequest
            ?? pendingIncomingControlRequest
            ?? activeInboundControlRequest,
           existing.id == requestID,
           existing.peerID == session.peerID {
            guard sessionBinding(for: existing) != session else { return }
            // A peer can reconnect and replay a request ID while its previous
            // consent prompt is still visible. Preserve the old prompt's
            // generation binding and reject the replayed request directly to
            // the new session so the old UI action cannot authorize it.
            send(
                ControlMessage(kind: .controlDenied, requestID: requestID),
                to: session
            )
            return
        }
        bind(request, to: session)
        guard ControlProtocolCompatibility.isCompatible(
            remoteVersion: message.protocolVersion,
            remoteMinimumVersion: message.minimumProtocolVersion
        ) else {
            sendResponse(kind: .controlDenied, for: request)
            removeSessionBinding(for: request)
            status = "Denied control: the other device uses an incompatible protocol"
            return
        }
        // A differing keyboard layout no longer denies the request outright:
        // RemoteInputSink resolves each remappable key to its equivalent on
        // this layout, and ends control only if a specific key turns out to
        // have no equivalent here. That resolution needs the character field
        // a v1 peer never sends, so a v1 peer would otherwise be granted
        // control only to have it end on its first remappable keystroke.
        // Denying it here, before the consent prompt, is strictly better for
        // that one case; a v2 peer with a differing layout is unaffected.
        if let remoteLayout = message.keyboardLayoutIdentifier,
           let localLayout = keyboardLayoutIdentifier(),
           remoteLayout != localLayout,
           (message.protocolVersion ?? 1) < 2 {
            sendResponse(kind: .controlDenied, for: request)
            removeSessionBinding(for: request)
            status = "Denied control: the other device's keyboard layout differs and its MacKVM version cannot remap it"
            return
        }
        guard !isRemoteInputTearingDown else {
            sendResponse(kind: .controlDenied, for: request)
            removeSessionBinding(for: request)
            status = "Denied a control request while remote input is returning locally"
            return
        }
        guard !isReceivingControl else {
            sendResponse(
                kind: .controlDenied,
                for: request
            )
            removeSessionBinding(for: request)
            status = "Denied a second request while remote control is active"
            return
        }
        guard pendingIncomingControlRequest == nil,
              preparingIncomingControlRequest == nil else {
            sendResponse(kind: .controlDenied, for: request)
            removeSessionBinding(for: request)
            status = "Denied a second control request while another is pending"
            return
        }
        inputSink.refreshPermission()
        guard inputSink.hasAccessibilityPermission else {
            sendResponse(
                kind: .controlDenied,
                for: request
            )
            removeSessionBinding(for: request)
            status = inputSink.permissionDenialReason
            return
        }
        if state == .controlling || state == .suspended {
            let localWins = PeerArbitration.localIDWins(
                localID: localID,
                remoteID: session.peerID
            )
            if localWins {
                sendResponse(
                    kind: .controlDenied,
                    for: request
                )
                removeSessionBinding(for: request)
                status = "Kept local control after a simultaneous request"
                return
            }
            if state == .suspended {
                cancelPendingRequestForSimultaneousControl()
            } else {
                stopControl(
                    reason: "Yielded control to a request from the other device"
                )
            }
        }
        pendingIncomingControlRequest = request
        if seamlessControlAuthorized(session.peerID) {
            // This is a local, receiver-side one-time authorization for the
            // already authenticated pinned peer. Keep the same acceptance
            // path so Accessibility checks, session freshness, teardown, and
            // the grant response remain identical to a user click.
            status = "Automatically allowing control for this paired Mac"
            acceptIncomingControlRequest(requestID)
            return
        }
        status = "The other device requests control — choose Allow or Deny"
        scheduleIncomingRequestTimeout(for: request)
        onIncomingControlRequest?(request)
    }

    private func completeIncomingControlAcceptance(
        _ request: IncomingControlRequest,
        generation: UInt64,
        stalePostingPermissionValidated: Bool,
        didStart: Bool
    ) {
        guard isLiveIncomingAuthorization(
            request,
            generation: generation
        ) else {
            if didStart {
                endTransientRemoteInput()
            }
            return
        }
        preparingIncomingControlRequest = nil
        preparingIncomingAuthorizationGeneration = nil

        guard didStart else {
            rejectIncomingControlRequest(
                request,
                reason: inputSink.requiresFunctionalPermissionProbe
                    ? inputSink.permissionFailureStatus
                    : inputSink.permissionDenialReason
            )
            return
        }
        inputSink.refreshPermission()
        guard inputSink.hasAccessibilityPermission else {
            endTransientRemoteInput()
            rejectIncomingControlRequest(
                request,
                reason: inputSink.permissionDenialReason
            )
            return
        }
        guard !inputSink.requiresFunctionalPermissionProbe
                || stalePostingPermissionValidated else {
            endTransientRemoteInput()
            rejectIncomingControlRequest(
                request,
                reason: inputSink.permissionFailureStatus
            )
            return
        }
        guard let session = sessionBinding(for: request),
              isCurrentSession(session) else {
            endTransientRemoteInput()
            status = "Control request expired because the secure session changed"
            removeSessionBinding(for: request)
            return
        }

        activeInboundControlRequest = request
        activeInboundSession = session
        isReceivingControl = true
        let clipboardIsMutuallyEnabled = clipboardSyncEnabled(request.peerID)
            && request.supportsClipboard == true
            && request.clipboardEnabled == true
        if clipboardIsMutuallyEnabled {
            startClipboardSync()
        }
        if request.managesDisplayRoute {
            onReceivingStarted?()
        }
        sendResponse(
            kind: .controlGranted,
            for: request,
            clipboardEnabled: request.supportsClipboard == true
                ? clipboardSyncEnabled(request.peerID) : nil
        )
        notifyOwnershipTransition(.inboundControl(peerID: request.peerID))
        status = "Remote control granted to the other device"
    }

    private func beginIncomingAuthorizationGeneration() -> UInt64 {
        pendingRemoteInputPermissionProbe?.operation.cancel()
        pendingRemoteInputPermissionProbe = nil
        incomingAuthorizationGeneration &+= 1
        return incomingAuthorizationGeneration
    }

    private func invalidateIncomingAuthorization() {
        incomingAuthorizationGeneration &+= 1
        preparingIncomingAuthorizationGeneration = nil
        pendingRemoteInputPermissionProbe?.operation.cancel()
        pendingRemoteInputPermissionProbe = nil
    }

    private func isLiveIncomingAuthorization(
        _ request: IncomingControlRequest,
        generation: UInt64
    ) -> Bool {
        !isStoppingForQuit
            && !isRemoteInputTearingDown
            && incomingAuthorizationGeneration == generation
            && preparingIncomingAuthorizationGeneration == generation
            && preparingIncomingControlRequest == request
            && sessionBinding(for: request).map {
                isCurrentSession($0)
            } == true
    }

    private func completeIncomingPermissionProbe(
        for request: IncomingControlRequest,
        generation: UInt64,
        passed: Bool
    ) {
        guard isLiveIncomingAuthorization(request, generation: generation) else {
            if pendingRemoteInputPermissionProbe?.generation == generation {
                pendingRemoteInputPermissionProbe?.operation.cancel()
                pendingRemoteInputPermissionProbe = nil
            }
            return
        }
        if pendingRemoteInputPermissionProbe?.generation == generation {
            pendingRemoteInputPermissionProbe = nil
        }

        inputSink.refreshPermission()
        guard inputSink.hasAccessibilityPermission else {
            rejectIncomingControlRequest(
                request,
                reason: inputSink.permissionDenialReason
            )
            return
        }
        let stalePostingStillReported = inputSink.requiresFunctionalPermissionProbe
        guard !stalePostingStillReported || passed else {
            rejectIncomingControlRequest(
                request,
                reason: inputSink.permissionFailureStatus
            )
            return
        }
        beginRemoteInput(
            for: request,
            generation: generation,
            stalePostingPermissionValidated: stalePostingStillReported && passed
        )
    }

    private func beginRemoteInput(
        for request: IncomingControlRequest,
        generation: UInt64,
        stalePostingPermissionValidated: Bool = false
    ) {
        guard isLiveIncomingAuthorization(request, generation: generation) else {
            return
        }
        inputSink.beginRemoteControl(
            stalePostingPermissionValidated: stalePostingPermissionValidated
        ) { [weak self] didStart in
            self?.completeIncomingControlAcceptance(
                request,
                generation: generation,
                stalePostingPermissionValidated:
                    stalePostingPermissionValidated,
                didStart: didStart
            )
        }
    }

    private func handleControlGranted(message: ControlMessage) {
        guard state == .suspended else { return }
        requestTimeout?.cancel()
        requestTimeout = nil
        let grantedRequestID = activeOutboundRequestID
        let grantedSession = activeOutboundSession
        do {
            state = try machine.handle(.controlGranted)
            inputCapture.startCapture(suppressingLocalEvents: true)
            let grantIsStillCurrent = {
                grantedRequestID != nil
                    && grantedSession != nil
                    && self.state == .controlling
                    && self.activeOutboundRequestID == grantedRequestID
                    && self.activeOutboundSession == grantedSession
                    && grantedSession.map {
                        self.isCurrentSession($0, requiringSelection: true)
                    } == true
            }
            guard grantIsStillCurrent() else {
                rejectStaleControlGrant(
                    requestID: grantedRequestID,
                    session: grantedSession
                )
                return
            }

            // Starting a suppressing event tap crosses a system-permission
            // boundary. Re-read both required grants after creation so a
            // revocation during startup cannot be treated as a live session.
            inputCapture.refreshPermission()
            inputSink.refreshPermission()
            guard grantIsStillCurrent() else {
                rejectStaleControlGrant(
                    requestID: grantedRequestID,
                    session: grantedSession
                )
                return
            }
            guard inputCapture.isCapturing,
                  inputCapture.hasInputMonitoringPermission,
                  inputSink.hasAccessibilityPermission else {
                inputCapture.stopCapture()
                let requestID = grantedRequestID
                _ = try? machine.handle(.stopControl)
                state = machine.state
                activeOutboundRequestID = nil
                activeOutboundSession = nil
                activeControlDisplayAlreadyRemote = false
                activeControlManagesDisplayRoute = true
                if let requestID, let grantedSession {
                    send(
                        ControlMessage(
                            kind: .endControl,
                            requestID: requestID
                        ),
                        to: grantedSession
                    )
                }
                completeActiveControlRequest(false)
                status = "Could not capture input; control stayed local"
                return
            }
            let displayAlreadyRemote = activeControlDisplayAlreadyRemote
            activeControlDisplayAlreadyRemote = false
            if !displayAlreadyRemote && activeControlManagesDisplayRoute {
                onControllingStarted?()
            }
            if let peerID = grantedSession?.peerID {
                if clipboardSyncEnabled(peerID),
                   message.supportsClipboard == true,
                   message.clipboardEnabled == true {
                    startClipboardSync()
                }
                notifyOwnershipTransition(.outboundControl(peerID: peerID))
            }
            completeActiveControlRequest(true)
            status = "Controlling the other device — ⌃⌥⌘Esc returns locally"
        } catch {
            if let requestID = activeOutboundRequestID,
               let session = activeOutboundSession {
                send(
                    ControlMessage(
                        kind: .endControl,
                        requestID: requestID
                    ),
                    to: session
                )
            }
            activeOutboundRequestID = nil
            activeOutboundSession = nil
            activeControlDisplayAlreadyRemote = false
            activeControlManagesDisplayRoute = true
            completeActiveControlRequest(false)
            status = "Ignored an unexpected control grant"
        }
    }

    private func rejectStaleControlGrant(
        requestID: UUID?,
        session: ControlPeerSession?
    ) {
        inputCapture.stopCapture()
        guard let requestID,
              let session,
              activeOutboundRequestID == requestID,
              activeOutboundSession == session else {
            completeActiveControlRequest(false)
            return
        }
        send(
            ControlMessage(kind: .endControl, requestID: requestID),
            to: session
        )
        _ = try? machine.handle(.stopControl)
        state = machine.state
        activeOutboundRequestID = nil
        activeOutboundSession = nil
        stopClipboardSync()
        activeControlDisplayAlreadyRemote = false
        activeControlManagesDisplayRoute = true
        completeActiveControlRequest(false)
    }

    private func connectionChanged(
        _ publication: ControlConnectionPublication
    ) {
        let peerID = publication.peerID
        if let peerID,
           let generation = publication.admissionGeneration,
           admissionGate(for: peerID).currentGeneration() != generation {
            return
        }
        if peerID == nil,
           let generation = publication.admissionGeneration,
           observedSelectedPeerID != nil,
           generation != observedSelectedAdmissionGeneration {
            // A delayed nil publication from an older selected session must
            // not reset a peer that has already authenticated again.
            return
        }

        let isSameSelection = observedSelectedPeerID == peerID
            && observedSelectedAdmissionGeneration == publication.admissionGeneration
        guard !isSameSelection else { return }

        let previousPeerID = observedSelectedPeerID
        let previousGeneration = observedSelectedAdmissionGeneration
        observedSelectedPeerID = peerID
        if let peerID {
            observedSelectedAdmissionGeneration =
                publication.admissionGeneration
                    ?? admissionGate(for: peerID).currentGeneration()
        } else {
            observedSelectedAdmissionGeneration = nil
        }

        let selectedSession = peerID.map { currentSession(for: $0) }
        let selectedSessionChanged = previousPeerID != peerID
            || (peerID != nil
                && publication.admissionGeneration != previousGeneration)
        if selectedSessionChanged,
           let outboundSession = activeOutboundSession,
           outboundSession != selectedSession {
            if isCurrentSession(outboundSession) {
                stopControl(
                    reason: peerID == nil
                        ? "Secure session disconnected; input is local"
                        : "Input returned locally while changing targets",
                    preserveDisplayRoute: peerID != nil
                )
            } else {
                finishDisconnectedOutboundSession(outboundSession)
            }
        }
        if selectedSessionChanged,
           activeInboundSession != nil,
           activeInboundSession != selectedSession {
            endReceivingControl(
                reason: peerID == nil
                    ? "Secure session disconnected; input is local"
                    : "Input returned locally while changing targets"
            )
        }

        if let peerID {
            guard secureSession.isConnected(to: peerID) else { return }
            if state != .controlling && state != .suspended {
                _ = try? machine.handle(.transportConnected)
                state = machine.state
                if !isReceivingControl {
                    status = "Secure session connected; input is local"
                }
            }
        } else if peerID == nil {
            if state != .disconnected {
                _ = try? machine.handle(.transportDisconnected)
                state = machine.state
                if !isReceivingControl && !isRemoteInputTearingDown {
                    status = "Secure session disconnected; input is local"
                }
            }
        }
    }

    private func peerConnectionChanged(
        _ publication: SecureSessionPeerPublication
    ) {
        let gate = admissionGate(for: publication.peerID)
        if publication.isConnected {
            if let generation = publication.admissionGeneration {
                guard gate.currentGeneration() == generation else { return }
            } else {
                gate.activate()
            }
            return
        }

        let generation = publication.admissionGeneration
            ?? gate.currentGeneration()
        guard gate.currentGeneration() == generation else { return }
        gate.invalidate(ifCurrentGeneration: generation)
        let disconnectedSession = ControlPeerSession(
            peerID: publication.peerID,
            generation: generation
        )

        let completedAcknowledgements = pendingHeartbeatAcknowledgements.filter {
            $0.session == disconnectedSession
        }
        pendingHeartbeatAcknowledgements.removeAll {
            $0.session == disconnectedSession
        }
        completedAcknowledgements.forEach { $0.acknowledgement.complete() }

        if let request = pendingIncomingControlRequest,
           sessionBinding(for: request) == disconnectedSession {
            cancelIncomingControlRequest(
                request,
                reason: "Secure session disconnected; input is local"
            )
        }
        if let request = preparingIncomingControlRequest,
           sessionBinding(for: request) == disconnectedSession {
            cancelIncomingControlRequest(
                request,
                reason: "Secure session disconnected; input is local"
            )
        }
        if let request = activeInboundControlRequest,
           activeInboundSession == disconnectedSession,
           isReceivingControl {
            finishReceivingControl(
                request,
                reason: "Secure session disconnected; input is local",
                notifyPeer: false
            )
        }
        if let outboundSession = activeOutboundSession,
           outboundSession == disconnectedSession,
           state == .controlling || state == .suspended {
            finishDisconnectedOutboundSession(outboundSession)
        }
    }

    private func finishDisconnectedOutboundSession(
        _ session: ControlPeerSession
    ) {
        guard activeOutboundSession == session else { return }
        let wasControlling = state == .controlling
        let wasWaitingForControlGrant = state == .suspended
        let managesDisplayRoute = activeControlManagesDisplayRoute
        requestTimeout?.cancel()
        requestTimeout = nil
        inputCapture.stopCapture()
        stopClipboardSync()
        if state == .controlling || state == .suspended {
            _ = try? machine.handle(.stopControl)
            state = machine.state
        }
        activeOutboundRequestID = nil
        activeOutboundSession = nil
        activeControlDisplayAlreadyRemote = false
        activeControlManagesDisplayRoute = true
        if wasWaitingForControlGrant {
            completeActiveControlRequest(false)
        }
        if wasControlling && managesDisplayRoute {
            onControllingStopped?()
        }
        if wasControlling {
            notifyOwnershipTransition(.returnedLocally)
        }
        if secureSession.connectedPeerID == session.peerID {
            _ = try? machine.handle(.transportDisconnected)
            state = machine.state
        }
        if !isReceivingControl {
            status = "Secure session disconnected; input is local"
        }
    }

    private func remoteInputSinkFailed(_ failure: ControlInputFailure) {
        guard let request = activeInboundControlRequest,
              isReceivingControl else {
            if case .accessibilityPermission = failure,
               let request = preparingIncomingControlRequest {
                rejectIncomingControlRequest(
                    request,
                    reason: inputSink.permissionDenialReason
                )
            }
            return
        }
        let reason: String
        switch failure {
        case .accessibilityPermission:
            reason = inputSink.permissionFailureEndReason
        case .queueOverloaded:
            reason = "Remote control ended because the input queue was overloaded"
        case .keyboardLayoutMismatch:
            reason = "Remote control ended because the keyboard layout changed"
        case .eventInjectionFailed:
            reason = "Remote control ended because macOS rejected an input event"
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
        activeOutboundSession = nil
        activeControlDisplayAlreadyRemote = false
        activeControlManagesDisplayRoute = true
        completeActiveControlRequest(false)
        status = "Yielded a simultaneous request to the other device"
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
        resolvePendingIncomingControlRequest(request)
        if preparingIncomingControlRequest?.id == request.id {
            invalidateIncomingAuthorization()
            preparingIncomingControlRequest = nil
            endTransientRemoteInput()
        }
        sendResponse(kind: .controlDenied, for: request)
        removeSessionBinding(for: request)
        status = reason
    }

    private func requestSessionKey(
        for request: IncomingControlRequest
    ) -> IncomingRequestSessionKey {
        IncomingRequestSessionKey(
            requestID: request.id,
            peerID: request.peerID
        )
    }

    private func bind(
        _ request: IncomingControlRequest,
        to session: ControlPeerSession
    ) {
        incomingRequestSessions[requestSessionKey(for: request)] = session
    }

    private func sessionBinding(
        for request: IncomingControlRequest
    ) -> ControlPeerSession? {
        incomingRequestSessions[requestSessionKey(for: request)]
    }

    private func removeSessionBinding(
        for request: IncomingControlRequest
    ) {
        incomingRequestSessions.removeValue(
            forKey: requestSessionKey(for: request)
        )
    }

    /// Clears a pending request only when the exact request is still active,
    /// then immediately reports that identity to observers that own
    /// request-scoped side effects such as native notifications.
    @discardableResult
    private func resolvePendingIncomingControlRequest(
        _ request: IncomingControlRequest
    ) -> Bool {
        guard pendingIncomingControlRequest == request else {
            return false
        }
        pendingIncomingControlRequest = nil
        onIncomingControlRequestResolved?(request)
        return true
    }

    private func cancelIncomingControlRequest(
        _ request: IncomingControlRequest,
        reason: String
    ) {
        incomingRequestTimeout?.cancel()
        incomingRequestTimeout = nil
        resolvePendingIncomingControlRequest(request)
        if preparingIncomingControlRequest?.id == request.id {
            invalidateIncomingAuthorization()
            preparingIncomingControlRequest = nil
            endTransientRemoteInput()
        }
        removeSessionBinding(for: request)
        status = reason
    }

    private func finishReceivingControl(
        _ request: IncomingControlRequest,
        reason: String,
        notifyPeer: Bool,
        restoreMonitor: Bool = true,
        forceDisplayRouteRestoration: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        guard isReceivingControl,
              activeInboundControlRequest?.id == request.id else {
            return
        }
        isReceivingControl = false
        activeInboundControlRequest = nil
        activeInboundSession = nil
        stopClipboardSync()
        isRemoteInputTearingDown = true
        receiverTeardown = ReceiverTeardown(
            request: request,
            phase: .releasingInput,
            notifyPeer: notifyPeer,
            restoreMonitor: restoreMonitor
                && (request.managesDisplayRoute || forceDisplayRouteRestoration),
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
        let session = sessionBinding(for: teardown.request)
        receiverTeardown = nil
        isRemoteInputTearingDown = false
        if !isStoppingForQuit {
            notifyOwnershipTransition(.returnedLocally)
        }
        if teardown.notifyPeer {
            sendResponse(kind: .endControl, for: teardown.request)
        }
        removeSessionBinding(for: teardown.request)
        teardown.completions.forEach { $0() }
        if let session {
            completeDeferredHeartbeatAcknowledgements(for: session)
        }
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
            completeDeferredHeartbeatAcknowledgements()
        }
    }

    private func sendResponse(
        kind: ControlMessageKind,
        for request: IncomingControlRequest,
        clipboardEnabled: Bool? = nil
    ) {
        guard let session = sessionBinding(for: request),
              isCurrentSession(session) else {
            return
        }
        let message: ControlMessage
        if kind == .controlGranted {
            message = .controlGranted(
                requestID: request.id,
                clipboardEnabled: clipboardEnabled
            )
        } else {
            message = ControlMessage(kind: kind, requestID: request.id)
        }
        send(message, to: session)
    }

    /// A live control session was negotiated with the prior per-peer
    /// preference. End it when that preference changes so the remote side
    /// stops reading or sending clipboard content immediately and the next
    /// session renegotiates both sides' consent.
    func clipboardSyncPreferenceChanged(for peerID: UUID) {
        guard isReceivingControl && activeInboundSession?.peerID == peerID
                || (state == .controlling || state == .suspended)
                    && activeOutboundSession?.peerID == peerID else {
            return
        }
        if isReceivingControl,
           activeInboundControlRequest?.peerID == peerID {
            endReceivingControl(
                reason: "Clipboard sync setting changed; control ended"
            )
        } else if activeOutboundRequestID != nil,
                  (state == .controlling || state == .suspended) {
            stopControl(
                reason: "Clipboard sync setting changed; control ended"
            )
        }
    }

    private func startClipboardSync() {
        guard !clipboardSyncIsActive else { return }
        clipboardSyncIsActive = true
        clipboardSync.start()
    }

    private func notifyOwnershipTransition(
        _ transition: ControlOwnershipTransition
    ) {
        ownershipTransitionRevision &+= 1
        onOwnershipTransition?(transition)
    }

    private func stopClipboardSync() {
        guard clipboardSyncIsActive else { return }
        clipboardSyncIsActive = false
        clipboardSync.stop()
    }

    private func sendClipboardText(_ text: String) {
        guard clipboardSyncIsActive,
              (state == .controlling || isReceivingControl) else {
            return
        }
        let session: ControlPeerSession
        let requestID: UUID
        let requiresSelection: Bool
        if state == .controlling {
            guard let outboundSession = activeOutboundSession,
                  let outboundRequestID = activeOutboundRequestID else {
                return
            }
            session = outboundSession
            requestID = outboundRequestID
            requiresSelection = true
        } else {
            guard let inboundSession = activeInboundSession,
                  let inboundRequestID = activeInboundControlRequest?.id else {
                return
            }
            session = inboundSession
            requestID = inboundRequestID
            requiresSelection = false
        }
        do {
            let payload = try ControlMessageCodec.encode(
                .clipboard(text, requestID: requestID)
            )
            guard isCurrentSession(
                session,
                requiringSelection: requiresSelection
            ) else {
                return
            }
            secureSession.send(payload, to: session.peerID)
        } catch {
            // Clipboard size/encoding failures are intentionally silent. The
            // text itself must never appear in a status, diagnostic, or log.
        }
    }

    private func send(
        _ message: ControlMessage,
        to session: ControlPeerSession,
        requiringSelection: Bool = false
    ) {
        do {
            let payload = try ControlMessageCodec.encode(message)
            guard isCurrentSession(
                session,
                requiringSelection: requiringSelection
            ) else {
                return
            }
            secureSession.send(payload, to: session.peerID)
        } catch {
            status = "Could not encode the control message"
        }
    }
}
