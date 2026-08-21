import AppKit
import Carbon
import MacKVMCore
import SwiftUI

@main
struct MacKVMApp: App {
    @NSApplicationDelegateAdaptor(MacKVMApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var bootstrap = AppBootstrap()

    var body: some Scene {
        MenuBarExtra {
            appContent
        } label: {
            if let control = bootstrap.control {
                MacKVMMenuBarLabel(control: control)
            } else {
                Label("MacKVM", systemImage: MacKVMBranding.menuBarSymbolName)
            }
        }
        .menuBarExtraStyle(.window)

        // Pairing and remote input do not require a monitor. Keep a normal
        // window and Dock entry available instead of forcing every action
        // through the menu-bar item.
        Window("MacKVM", id: "main") {
            appContent
        }
        .defaultSize(width: 440, height: 760)
    }

    @ViewBuilder
    private var appContent: some View {
        if let discovery = bootstrap.discovery,
           let secureSession = bootstrap.secureSession,
           let inputCapture = bootstrap.inputCapture,
           let inputSink = bootstrap.inputSink,
           let control = bootstrap.control,
           let monitor = bootstrap.monitor {
            MacKVMMenuView(
                discovery: discovery,
                secureSession: secureSession,
                inputCapture: inputCapture,
                inputSink: inputSink,
                control: control,
                monitor: monitor,
                inputTopology: bootstrap.inputTopology,
                launchAtLogin: bootstrap.launchAtLogin,
                bootstrap: bootstrap
            )
        } else {
            BootstrapErrorView(
                message: bootstrap.errorMessage
                    ?? "MacKVM could not load its device key.",
                onResetIdentity: bootstrap.canResetIdentity
                    ? { bootstrap.resetIdentity() } : nil,
                recoveryMessage: bootstrap.recoveryMessage,
                onQuit: { bootstrap.requestTermination() }
            )
        }
    }
}

/// SwiftUI's default termination handling does not know about the control
/// teardown sequence. Keep the delegate deliberately small and let the
/// bootstrap object own the ordering of input release, network shutdown, and
/// the final local monitor route.
private final class MacKVMApplicationDelegate: NSObject, NSApplicationDelegate {
    private var terminationInProgress = false
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Login Items deliver the initial kAEOpenApplication event before a
        // newly registered handler can observe it. Read the event currently
        // being processed instead of installing a late handler.
        launchedAsLoginItem = NSAppleEventManager.shared()
            .currentAppleEvent?
            .paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard launchedAsLoginItem else { return }
        // Login-item startup should restore the background service without
        // stealing focus or opening a full control window. The menu-bar item
        // remains available, and a Dock activation can reopen the window.
        DispatchQueue.main.async { [weak self] in
            guard self?.launchedAsLoginItem == true else { return }
            self?.mainWindow()?.orderOut(nil)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !flag else { return true }
        DispatchQueue.main.async { [weak self, weak sender] in
            guard let window = self?.mainWindow() else { return }
            window.makeKeyAndOrderFront(nil)
            sender?.activate(ignoringOtherApps: true)
        }
        return true
    }

    private func mainWindow() -> NSWindow? {
        NSApplication.shared.windows.first {
            $0.identifier?.rawValue == "main"
                || ($0.title == "MacKVM" && $0.canBecomeKey)
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        guard !terminationInProgress else { return .terminateLater }
        guard let handler = MacKVMApplicationTermination.handler else {
            return .terminateNow
        }

        terminationInProgress = true
        handler { [weak self, weak sender] in
            // The bootstrap-error handler completes synchronously. Defer the
            // reply until after this delegate returns `.terminateLater`, or
            // AppKit may treat the reply as occurring before deferred
            // termination was registered and leave the app running.
            DispatchQueue.main.async {
                self?.terminationInProgress = false
                sender?.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

private enum MacKVMApplicationTermination {
    static var handler: ((@escaping () -> Void) -> Void)?
}

private enum MacKVMBranding {
    // Paired rectangles communicate KVM/display sharing without implying
    // that MacKVM is a keyboard utility.
    static let menuBarSymbolName = "rectangle.on.rectangle"
}

/// The menu-bar state remains visible even when macOS notification alerts are
/// disabled. `ControlCoordinator` owns the canonical pending-request state;
/// this value only defines how that state is presented in the status item.
enum ControlRequestMenuBarStatus: Equatable {
    case ready
    case pendingControlRequest

    init(pendingIncomingControlRequest: IncomingControlRequest?) {
        self = pendingIncomingControlRequest == nil
            ? .ready : .pendingControlRequest
    }

    var pendingIndicatorSystemImage: String? {
        switch self {
        case .ready:
            nil
        case .pendingControlRequest:
            "exclamationmark.circle.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .ready:
            "MacKVM"
        case .pendingControlRequest:
            "MacKVM: incoming control request pending"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .ready:
            "Open MacKVM."
        case .pendingControlRequest:
            "Open this menu bar item to allow or deny the control request."
        }
    }
}

/// Observing the coordinator directly is important: `AppBootstrap` does not
/// relay `ControlCoordinator.objectWillChange`, and the indicator must update
/// while the MacKVM menu is closed.
private struct MacKVMMenuBarLabel: View {
    @ObservedObject var control: ControlCoordinator

    var body: some View {
        let status = ControlRequestMenuBarStatus(
            pendingIncomingControlRequest: control.pendingIncomingControlRequest
        )
        HStack(spacing: 2) {
            Image(systemName: MacKVMBranding.menuBarSymbolName)
            if let image = status.pendingIndicatorSystemImage {
                Image(systemName: image)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.accessibilityLabel)
        .accessibilityHint(status.accessibilityHint)
        .help(status.accessibilityHint)
    }
}

private func peerDisplayName(
    for peerID: UUID,
    from discovery: PeerDiscoveryService?
) -> String {
    let candidateName = discovery?.peers.first { $0.identity.id == peerID }?.name
        ?? "Mac \(peerID.uuidString.prefix(8))"
    let trimmedName = candidateName.trimmingCharacters(
        in: .whitespacesAndNewlines
    )
    // Bonjour and the signed protocols already bound this value. Keep a
    // defensive UI bound as well because notification/alert text is rendered
    // outside the normal menu layout.
    let boundedName = PeerIdentity.boundedDisplayName(trimmedName)
    return boundedName.isEmpty ? "Mac" : boundedName
}

@MainActor
private final class AppBootstrap: ObservableObject {
    let discovery: PeerDiscoveryService?
    let secureSession: SecureSessionService?
    let inputCapture: InputCaptureService?
    let inputSink: RemoteInputSink?
    let control: ControlCoordinator?
    let monitor: MonitorController?
    let controlRequestNotifier: ControlRequestNotifier?
    let inputTopology = InputTopologyController()
    let launchAtLogin = LaunchAtLoginController()
    let errorMessage: String?
    let canResetIdentity: Bool
    @Published private(set) var networkServicesStarted = false
    /// Shared by the menu-bar scene and the normal window so the Local
    /// Network acknowledgement step cannot diverge between two surfaces.
    @Published private(set) var awaitingLocalNetworkResponse = false
    @Published private(set) var recoveryMessage: String?
    /// Shared by the menu-bar scene and the normal window. Both surfaces can
    /// invoke the combined DDC-and-control action, so a view-local `@State`
    /// would not prevent cross-scene double activation.
    @Published private(set) var combinedControlRequestInFlight = false
    @Published private(set) var combinedControlStatus: String?
    private var combinedControlRequestGeneration: UInt64 = 0
    private var terminationCleanupStarted = false

    init() {
        do {
            let credentials = try DeviceCredentialsStore.load()
            let hadExistingDeviceCredentials =
                credentials.wasLoadedFromStorage
            let registry = PairingRegistry()
            let discovery = PeerDiscoveryService(
                credentials: credentials,
                registry: registry
            )
            let secureSession = SecureSessionService(
                credentials: credentials,
                registry: registry
            )
            let inputCapture = InputCaptureService()
            let inputSink = RemoteInputSink()
            let monitor = MonitorController()
            let control = ControlCoordinator(
                localID: credentials.identity.id,
                secureSession: secureSession,
                inputCapture: inputCapture,
                inputSink: inputSink,
                localControlAllowed: { [weak inputTopology] in
                    inputTopology?.allowsLocalControl ?? false
                },
                keyboardLayoutIdentifier: { [weak inputCapture] in
                    inputCapture?.keyboardLayoutIdentifier
                },
                seamlessControlAuthorized: { [weak discovery] peerID in
                    discovery?.seamlessControlAuthorized(for: peerID) ?? false
                }
            )
            control.onControllingStarted = { monitor.switchToRemote() }
            control.onControllingStopped = { monitor.switchToLocal() }
            control.onReceivingStarted = { monitor.switchToLocal() }
            control.onReceivingStopped = { completion in
                monitor.switchToRemote(completion: completion)
            }
            let controlRequestNotifier = ControlRequestNotifier()
            control.onIncomingControlRequest = {
                [weak discovery, weak controlRequestNotifier] request in
                let peerName = peerDisplayName(
                    for: request.peerID,
                    from: discovery
                )
                controlRequestNotifier?.present(
                    request: request,
                    peerName: peerName
                )
            }
            control.onIncomingControlRequestResolved = {
                [weak controlRequestNotifier] request in
                controlRequestNotifier?.clearActiveRequest(
                    requestID: request.id
                )
            }
            self.discovery = discovery
            self.secureSession = secureSession
            self.inputCapture = inputCapture
            self.inputSink = inputSink
            self.control = control
            self.monitor = monitor
            self.controlRequestNotifier = controlRequestNotifier
            // Keep the dedicated switch shortcut available even when the
            // menu-bar window is closed. The active capture tap handles it
            // while sharing; an event tap or Carbon registered hot key handles
            // the idle and receiving sides without leaking it to other apps.
            errorMessage = nil
            canResetIdentity = false
            // Escape is also the local-return path after a display-only
            // remote route. Invalidate a display-first request before tearing
            // down control so its asynchronous completion cannot start input
            // capture after the user has already asked to return locally.
            inputCapture.onEmergencyStop = { [weak self, weak control, weak monitor] in
                guard let control else { return }
                let hadCombinedRequest = self?.combinedControlRequestInFlight ?? false
                let wasReceivingControl = control.isReceivingControl
                let wasRemoteInputTearingDown = control.isRemoteInputTearingDown
                let shouldRestoreIdleRoute =
                    !wasReceivingControl
                        && !wasRemoteInputTearingDown
                        && (control.state == .idle
                            || control.state == .connected
                            || control.state == .disconnected)
                self?.cancelCombinedControlRequest()
                control.stopControl(
                    reason: "Emergency shortcut returned input locally"
                )
                if wasReceivingControl || wasRemoteInputTearingDown {
                    control.requestLocalMonitorReturn {
                        monitor?.switchToLocal()
                    }
                } else if hadCombinedRequest || shouldRestoreIdleRoute {
                    monitor?.switchToLocal()
                }
            }
            inputCapture.onSwitchControl = { [weak self] in
                guard let self else { return }
                if self.combinedControlRequestInFlight {
                    // The combined action may already have routed the monitor
                    // remotely while its control request is still suspended
                    // waiting for the peer's grant. Let the same global
                    // shortcut cancel that pending request and restore the
                    // local display instead of silently ignoring the user's
                    // only active return path.
                    self.cancelCombinedControlRequest()
                    if self.control?.state == .suspended
                        || self.control?.state == .controlling {
                        self.control?.stopControl(
                            reason: "Hotkey cancelled keyboard and mouse sharing"
                        )
                    }
                    self.monitor?.switchToLocal()
                    return
                }
                guard let control = self.control else { return }
                if control.isReceivingControl
                    || control.state == .controlling
                    || control.state == .suspended {
                    control.toggleControlFromHotKey()
                } else if let monitor = self.monitor,
                          monitor.automationEnabled,
                          monitor.isDisplaySelectorVerified {
                    // An idle shortcut follows the same display-first route
                    // as the primary Share button. Otherwise the suppressing
                    // input tap could start before native DDC has moved the
                    // monitor to the remote Mac.
                    self.startCombinedControlRequest()
                } else {
                    control.toggleControlFromHotKey()
                }
            }
            inputCapture.onSwitchMonitor = { [weak self] in
                self?.switchToOtherMonitorFromHotKey()
            }
            inputCapture.startHotKeyMonitoring()
            discovery.onPairingCompleted = { [weak secureSession] peerID in
                // Pairing pins trust; immediately establish the encrypted
                // session so the user can request keyboard/mouse control
                // without a second manual Connect action. New pairings also
                // enable the receiver's local seamless-control authorization;
                // the per-peer setting can restore explicit Allow prompts.
                secureSession?.connect(to: peerID)
            }
            // A notification action can arrive before the menu is opened.
            // Start native DDC/CI discovery here so the saved selector is
            // verified for that headless control path as well.
            monitor.refreshDetectedDisplays()
            controlRequestNotifier.onAction = { [weak self] action, requestID in
                switch action {
                case .allow:
                    self?.control?.acceptIncomingControlRequest(requestID)
                case .deny:
                    self?.control?.denyIncomingControlRequest(requestID)
                case .review:
                    self?.reviewIncomingControlRequest(requestID)
                }
            }
            if OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                hadExistingDeviceCredentials: hadExistingDeviceCredentials
            ) {
                startNetworkServices()
            }
            MacKVMApplicationTermination.handler = { [weak self] completion in
                self?.shutdownForTermination(completion: completion)
                    ?? completion()
            }
        } catch {
            discovery = nil
            secureSession = nil
            inputCapture = nil
            inputSink = nil
            control = nil
            monitor = nil
            controlRequestNotifier = nil
            errorMessage = "Could not access the device key: \(error.localizedDescription)"
            canResetIdentity = error is DeviceCredentialError
            MacKVMApplicationTermination.handler = { completion in
                completion()
            }
        }
    }

    func requestTermination() {
        NSApplication.shared.terminate(nil)
    }

    func beginCombinedControlRequest() -> UInt64? {
        guard !combinedControlRequestInFlight else { return nil }
        combinedControlRequestGeneration &+= 1
        combinedControlRequestInFlight = true
        return combinedControlRequestGeneration
    }

    func isCurrentCombinedControlRequest(_ generation: UInt64) -> Bool {
        combinedControlRequestInFlight
            && combinedControlRequestGeneration == generation
    }

    func endCombinedControlRequest(_ generation: UInt64) {
        guard combinedControlRequestGeneration == generation else { return }
        combinedControlRequestInFlight = false
    }

    /// Invalidates an asynchronous display route before starting a competing
    /// local/remote route. Its completion must not start keyboard sharing
    /// after the user has changed the requested display destination.
    func cancelCombinedControlRequest() {
        guard combinedControlRequestInFlight else { return }
        combinedControlRequestGeneration &+= 1
        combinedControlRequestInFlight = false
    }

    /// Routes only the physical display to the other Mac. Keyboard/mouse
    /// sharing remains on the K shortcut, so this emergency-safe monitor
    /// shortcut can be used without changing the current input owner.
    func switchToOtherMonitorFromHotKey() {
        let shouldCancelWaitingControl =
            combinedControlRequestInFlight
                && (control?.state == .suspended
                    || control?.state == .controlling)
        cancelCombinedControlRequest()
        if shouldCancelWaitingControl {
            control?.stopControl(
                reason: "Monitor route changed; input stayed local"
            )
        }
        monitor?.switchToRemote()
    }

    /// Starts the display-first share flow used by both the main button and
    /// the global shortcut. Input capture is not allowed to begin until native
    /// DDC reports that the remote input has been selected.
    @discardableResult
    func startCombinedControlRequest() -> Bool {
        guard let monitor, let control else {
            combinedControlStatus =
                "Keyboard and mouse sharing is unavailable while MacKVM is starting."
            return false
        }
        guard control.canRequestControl() else {
            combinedControlStatus =
                "Connect to the other Mac and complete the control setup before sharing keyboard and mouse."
            return false
        }
        guard monitor.canStartAutomaticRemoteSwitching() else {
            combinedControlStatus =
                "Detect and select a DDC-capable display before sharing keyboard and mouse."
            return false
        }
        guard let requestGeneration = beginCombinedControlRequest() else {
            combinedControlStatus =
                "Keyboard and mouse sharing is already in progress."
            return false
        }
        combinedControlStatus = nil
        monitor.switchToRemoteAndReportSuccess { [weak self] switched in
            guard let self else { return }
            guard self.isCurrentCombinedControlRequest(requestGeneration) else {
                return
            }
            guard switched else {
                self.endCombinedControlRequest(requestGeneration)
                self.combinedControlStatus =
                    "The display could not be switched; keyboard and mouse remain local."
                return
            }

            var rejectionCompletionCalled = false
            let requestStarted = control.requestControl(
                displayAlreadyRemote: true
            ) { [weak self, weak monitor] granted in
                rejectionCompletionCalled = true
                guard let self else { return }
                let ownsRoute = self.isCurrentCombinedControlRequest(
                    requestGeneration
                )
                self.endCombinedControlRequest(requestGeneration)
                if !granted && ownsRoute {
                    self.combinedControlStatus =
                        "The other Mac did not accept keyboard and mouse control."
                    monitor?.switchToLocal()
                }
            }
            if !requestStarted && !rejectionCompletionCalled {
                // Keep a safe fallback if a future guard returns false without
                // invoking the request completion.
                self.endCombinedControlRequest(requestGeneration)
                self.combinedControlStatus =
                    "The control request could not be started; keyboard and mouse remain local."
                monitor.switchToLocal()
            }
        }
        return true
    }

    /// Performs the same ordered shutdown for every app-level termination
    /// path, including Cmd-Q, the Dock, and the application menu.
    func shutdownForTermination(completion: @escaping () -> Void) {
        guard !terminationCleanupStarted else {
            // NSApplication normally asks only once. If a second request does
            // arrive while cleanup is in progress, do not start a second
            // monitor route; the first request owns the final reply.
            return
        }
        terminationCleanupStarted = true
        controlRequestNotifier?.clearAllControlRequestNotifications()

        guard let control, let monitor else {
            discovery?.stop()
            secureSession?.stop()
            completion()
            return
        }

        let cancelledMonitorRoutes = monitor.beginTermination()
        control.stopForQuit { [weak self] in
            guard let self else {
                completion()
                return
            }
            self.discovery?.stop()
            self.secureSession?.stop()
            monitor.switchToLocalForTermination {
                completion()
            }
        }
        cancelledMonitorRoutes.forEach { $0() }
    }

    func resetIdentity() {
        guard canResetIdentity else { return }
        do {
            try DeviceCredentialsStore.reset()
            PairingRegistry().removeAll()
            recoveryMessage = "Local identity reset. Quit and relaunch MacKVM, then pair both Macs again."
        } catch {
            recoveryMessage = "Identity reset failed: \(error.localizedDescription)"
        }
    }

    func startNetworkServices() {
        guard !networkServicesStarted,
              let discovery,
              let secureSession else {
            return
        }
        discovery.start()
        secureSession.start()
        networkServicesStarted = true
    }

    func beginLocalNetworkPermissionRequest() {
        awaitingLocalNetworkResponse = true
        startNetworkServices()
    }

    func completeLocalNetworkPermissionRequest() {
        awaitingLocalNetworkResponse = false
    }

    func forget(peerID: UUID) {
        guard let discovery, let secureSession else { return }
        // Discovery performs the synchronous registry revoke. Secure-session
        // cleanup is then queued without bumping the same generation twice.
        discovery.forget(peerID)
        secureSession.revoke(peerID, trustAlreadyRevoked: true)
    }

    func requestControlRequestNotifications() {
        controlRequestNotifier?.requestAuthorization()
    }

    func clearControlRequestNotifications() {
        controlRequestNotifier?.clearAllControlRequestNotifications()
    }

    func reviewIncomingControlRequest(_ requestID: UUID) {
        guard let control,
              let request = control.pendingIncomingControlRequest,
              request.id == requestID else {
            return
        }

        activateMacKVM()
        let peerName = peerDisplayName(
            for: request.peerID,
            from: discovery
        )
        let alert = NSAlert()
        alert.messageText = "MacKVM control request"
        alert.informativeText = "\(peerName) wants to control this Mac. Allow only if you expect to use that Mac's keyboard and mouse."
        alert.addButton(withTitle: "Review later")
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            control.acceptIncomingControlRequest(request.id)
        case .alertThirdButtonReturn:
            control.denyIncomingControlRequest(request.id)
        default:
            break
        }
    }
}

@MainActor
private func activateMacKVM() {
    if #available(macOS 14.0, *) {
        NSApplication.shared.activate()
    } else {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct BootstrapErrorView: View {
    let message: String
    let onResetIdentity: (() -> Void)?
    let recoveryMessage: String?
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacKVM is unavailable")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let recoveryMessage {
                Text(recoveryMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let onResetIdentity {
                Button("Reset this Mac identity", role: .destructive) {
                    onResetIdentity()
                }
                Text("This removes local pairings. You will need to confirm pairing again after relaunch.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Quit") {
                onQuit()
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct MacKVMMenuView: View {
    private static let menuWidth: CGFloat = 400
    private static let menuHeight: CGFloat = 700
    @ObservedObject var discovery: PeerDiscoveryService
    @ObservedObject var secureSession: SecureSessionService
    @ObservedObject var inputCapture: InputCaptureService
    @ObservedObject var inputSink: RemoteInputSink
    @ObservedObject var control: ControlCoordinator
    @ObservedObject var monitor: MonitorController
    @ObservedObject var inputTopology: InputTopologyController
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var bootstrap: AppBootstrap
    @Environment(\.openWindow) private var openWindow
    @AppStorage(OnboardingDefaults.localNetworkAccessReviewedKey)
    private var localNetworkAccessReviewed = false
    @State private var supportCopyStatus: String?
    @State private var editingFriendlyNames: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    Divider()

                    setupSection
                    Divider()

                    if discovery.pairingActivity.isActive {
                        pairingProgressSection
                        Divider()
                    }

                    topologySection
                    Divider()

                    if !discovery.pendingRequests.isEmpty {
                        pendingSection
                        Divider()
                    }

                    if let confirmation = discovery.pendingPairingConfirmation {
                        pairingConfirmationSection(confirmation)
                        Divider()
                    }

                    peerSection
                    Divider()
                    supportSection
                    Divider()
                    inputSection
                    Divider()
                    monitorSection
                    Divider()
                    startupSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()

            HStack {
                Text(discovery.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Quit") {
                    bootstrap.requestTermination()
                }
            }
            .padding(16)
        }
        // Keep every section reachable on shorter MacBook displays while
        // leaving the return-to-local/quit control pinned at the bottom.
        .frame(width: Self.menuWidth, height: Self.menuHeight)
        .onAppear {
            refreshSetupState()
            monitor.refreshDetectedDisplays()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            refreshSetupState()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("MacKVM")
                    .font(.headline)
                Spacer()
                Button("Open window") {
                    openWindow(id: "main")
                }
                .font(.caption)
            }
            Text("This Mac: \(discovery.identity.name)")
                .font(.subheadline)
            Text(String(discovery.identity.id.uuidString.prefix(8)))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let code = discovery.activeVerificationCode {
                Text("Security code: \(code)")
                    .font(.title3.monospacedDigit().weight(.semibold))
            }
        }
    }

    private var setupState: PermissionOnboardingState {
        PermissionOnboardingPolicy.checklistState(
            localNetworkAccessReviewed: localNetworkAccessReviewed,
            inputMonitoringGranted: inputCapture.hasInputMonitoringPermission,
            accessibilityGranted: inputSink.hasAccessibilityPermission
        )
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set up this Mac")
                .font(.subheadline.weight(.semibold))

            ForEach(setupState.checklist) { item in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(item.permission.displayName)
                        Spacer()
                        setupStatus(for: item)
                    }
                    if item.status == .current {
                        setupAction(for: item.permission)
                    }
                }
            }

            if localNetworkAccessReviewed {
                Button("Review Local Network Settings") {
                    PrivacySettings.open(.localNetwork)
                }
                .font(.caption)
                Text("If nearby Macs are not found, confirm MacKVM is allowed in Local Network settings. macOS does not let MacKVM verify that choice itself.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if setupState.isReadyForInputSharing {
                Label("Input permissions ready", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if setupState.isChecklistComplete {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Control request notifications")
                        Spacer()
                        Button("Enable") {
                            bootstrap.requestControlRequestNotifications()
                        }
                    }
                    Text("Optional but recommended: enable this before the first request so Allow/Deny alerts are ready while the menu is closed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if bootstrap.awaitingLocalNetworkResponse {
                Text("Respond to the macOS Local Network prompt before continuing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("Refresh setup status") {
                refreshSetupState()
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func setupStatus(
        for item: PermissionOnboardingChecklistItem
    ) -> some View {
        if item.permission == .localNetwork, item.status == .complete {
            Label("Reviewed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            switch item.status {
            case .complete:
                Label("Complete", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .current:
                Label("Action needed", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .waiting:
                Label("Waiting", systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func setupAction(for permission: MacKVMPermission) -> some View {
        switch permission {
        case .localNetwork:
            HStack {
                if bootstrap.awaitingLocalNetworkResponse {
                    Button("I handled the macOS prompt") {
                        bootstrap.completeLocalNetworkPermissionRequest()
                        localNetworkAccessReviewed = true
                        bootstrap.startNetworkServices()
                        refreshSetupState()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Enable Local Network") {
                        // Bonjour traffic triggers the macOS Local Network
                        // prompt, so start it before recording the user's
                        // acknowledgement in the next step.
                        bootstrap.beginLocalNetworkPermissionRequest()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Settings") {
                    PrivacySettings.open(.localNetwork)
                }
            }
        case .inputMonitoring, .accessibility:
            HStack {
                Button(permissionRequestTitle(for: permission)) {
                    _ = PermissionOnboardingPolicy.requestPermission(
                        permission,
                        inputCapture: inputCapture,
                        inputSink: inputSink
                    )
                    refreshSetupState()
                }
                .buttonStyle(.borderedProminent)
                Button("Settings") {
                    PrivacySettings.open(permission)
                }
            }
        }
    }

    private func permissionRequestTitle(for permission: MacKVMPermission) -> String {
        switch permission {
        case .localNetwork:
            String(localized: "Request Local Network")
        case .inputMonitoring:
            String(localized: "Request Input Monitoring")
        case .accessibility:
            String(localized: "Request Accessibility")
        }
    }

    private func refreshSetupState() {
        PermissionOnboardingPolicy.refresh(
            inputCapture: inputCapture,
            inputSink: inputSink
        )
        if localNetworkAccessReviewed {
            bootstrap.startNetworkServices()
        }
    }

    @ViewBuilder
    private var pairingProgressSection: some View {
        switch discovery.pairingActivity {
        case .idle:
            EmptyView()
        case let .connecting(peerID, peerName):
            pairingProgressSectionView(
                peerID: peerID,
                peerName: peerName,
                canCancel: true
            )
        case let .awaitingConfirmation(peerID, peerName):
            pairingProgressSectionView(
                peerID: peerID,
                peerName: peerName,
                canCancel: true
            )
        case let .retryAvailable(peerID, peerName):
            pairingProgressSectionView(
                peerID: peerID,
                peerName: peerName,
                canCancel: false
            )
        }
    }

    private func pairingProgressSectionView(
        peerID: UUID,
        peerName: String,
        canCancel: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pairing with \(peerName)…")
                .font(.subheadline.weight(.semibold))
            Text(
                "If macOS asks about the firewall, allow incoming connections "
                    + "on the receiving Mac, then retry pairing."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if canCancel {
                    Button("Cancel pairing") {
                        discovery.cancelPairing()
                    }
                }
                let retryPeer = discovery.pairingRetryPeer
                    ?? discovery.peers.first(where: {
                        $0.identity.id == peerID
                    })
                if let peer = retryPeer {
                    Button("Retry pairing") {
                        discovery.retryPairing(with: peer)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pairing requests")
                .font(.subheadline.weight(.semibold))

            ForEach(discovery.pendingRequests) { request in
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.peer.name)
                    Text("Verify this code matches the initiating Mac: \(request.verificationCode)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Accept") {
                            discovery.respond(to: request, accepted: true)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Decline") {
                            discovery.respond(to: request, accepted: false)
                        }
                    }
                }
            }
        }
    }

    private func pairingConfirmationSection(
        _ confirmation: PendingPairingConfirmation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Confirm pairing")
                .font(.subheadline.weight(.semibold))
            Text(
                "Compare this code with \(confirmation.peer.name) before confirming:"
            )
                .font(.caption)
            Text(confirmation.verificationCode)
                .font(.title2.monospacedDigit().weight(.semibold))
            HStack {
                Button("Confirm code") {
                    discovery.confirmPairing(requestID: confirmation.id)
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") {
                    discovery.declinePairing(requestID: confirmation.id)
                }
            }
        }
    }

    private var peerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nearby Macs")
                .font(.subheadline.weight(.semibold))

            if !bootstrap.networkServicesStarted {
                Text("Complete the Local Network step above to discover nearby Macs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if discovery.peers.isEmpty {
                Text("Searching on the local network…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(discovery.peers) { peer in
                    HStack {
                        Image(systemName: "laptopcomputer")
                        Text(displayName(for: peer))
                        Spacer()
                        switch discovery.trustState(for: peer) {
                        case .paired:
                            Label("Paired", systemImage: "checkmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            if secureSession.connectedPeerID == peer.identity.id {
                                Button("Disconnect") {
                                    secureSession.disconnect()
                                }
                            } else {
                                Button("Connect") {
                                    secureSession.connect(to: peer.identity.id)
                                }
                            }
                            Button("Forget", role: .destructive) {
                                bootstrap.forget(peerID: peer.identity.id)
                            }
                        case .changedKey:
                            Label("Key changed", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button("Forget old key", role: .destructive) {
                                bootstrap.forget(peerID: peer.identity.id)
                            }
                        case .unpaired:
                            Button("Pair") {
                                discovery.requestPairing(with: peer)
                            }
                        }
                    }
                }
            }
            if !unavailablePairedPeerIDs.isEmpty {
                Text("Unavailable paired Macs")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(unavailablePairedPeerIDs, id: \.self) { peerID in
                    HStack {
                        Image(systemName: "laptopcomputer.slash")
                        Text(
                            discovery.pairedPeerProfile(for: peerID)?.friendlyName
                                ?? "Mac \(peerID.uuidString.prefix(8))"
                        )
                            .font(.caption.monospaced())
                        Spacer()
                        if secureSession.connectedPeerID == peerID {
                            Button("Disconnect") {
                                secureSession.disconnect()
                            }
                        }
                        Button("Forget", role: .destructive) {
                            bootstrap.forget(peerID: peerID)
                        }
                    }
                }
            }
            Text(secureSession.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paired device information")
                .font(.subheadline.weight(.semibold))

            Text("This Mac: \(discovery.localModel)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if pairedProfiles.isEmpty {
                Text("No paired devices yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(pairedProfiles) { profile in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: "laptopcomputer")
                            TextField(
                                "Friendly name",
                                text: friendlyNameBinding(for: profile)
                            )
                            .textFieldStyle(.roundedBorder)
                            Button("Save") {
                                saveFriendlyName(for: profile)
                            }
                            .disabled(
                                (editingFriendlyNames[profile.peerID]
                                    ?? profile.friendlyName)
                                    .trimmingCharacters(
                                        in: .whitespacesAndNewlines
                                    ).isEmpty
                            )
                        }
                        Text("Model: \(profile.model)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(
                            "Last connected: \(displayDate(profile.lastConnectedAt))"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        Text("Key fingerprint: \(profile.keyFingerprint)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Toggle(
                            "Automatically allow control from this Mac",
                            isOn: seamlessControlAuthorizationBinding(
                                for: profile
                            )
                        )
                        .font(.caption)
                        Text(
                            "This is a one-time local authorization for this pinned Mac."
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            Button("Copy support information") {
                copySupportInformation()
            }
            if let supportCopyStatus {
                Text(supportCopyStatus)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pairedProfiles: [PairedPeerProfile] {
        let persistedProfiles = discovery.pairedPeerProfiles
        let profiles = discovery.pairedPeerIDs.compactMap { peerID -> PairedPeerProfile? in
            if let profile = persistedProfiles[peerID] {
                return profile
            }
            guard let publicKey = discovery.pairedPublicKey(for: peerID) else {
                return nil
            }
            // Pairings created by older releases predate profile storage. Do
            // not use Bonjour TXT as a default here: it is unsigned and the
            // user could save it unchanged. A signed pairing or secure
            // handshake will replace this fallback with the peer's name.
            return PairedPeerProfile(
                peerID: peerID,
                friendlyName: "Mac \(peerID.uuidString.prefix(8))",
                model: nil,
                signingPublicKey: publicKey
            )
        }
        return profiles.sorted {
            let nameComparison = $0.friendlyName.localizedStandardCompare(
                $1.friendlyName
            )
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return $0.peerID.uuidString < $1.peerID.uuidString
        }
    }

    private func displayName(for peer: DiscoveredPeer) -> String {
        discovery.pairedPeerProfile(for: peer.identity.id)?.friendlyName
            ?? peer.name
    }

    private func friendlyNameBinding(
        for profile: PairedPeerProfile
    ) -> Binding<String> {
        Binding(
            get: {
                editingFriendlyNames[profile.peerID] ?? profile.friendlyName
            },
            set: { editingFriendlyNames[profile.peerID] = $0 }
        )
    }

    private func saveFriendlyName(for profile: PairedPeerProfile) {
        let candidate = editingFriendlyNames[profile.peerID]
            ?? profile.friendlyName
        if discovery.updateFriendlyName(
            for: profile.peerID,
            friendlyName: candidate
        ) {
            editingFriendlyNames.removeValue(forKey: profile.peerID)
        }
    }

    private func seamlessControlAuthorizationBinding(
        for profile: PairedPeerProfile
    ) -> Binding<Bool> {
        Binding(
            get: {
                discovery.pairedPeerProfile(
                    for: profile.peerID
                )?.seamlessControlAuthorized ?? false
            },
            set: { authorized in
                _ = discovery.updateSeamlessControlAuthorization(
                    for: profile.peerID,
                    authorized: authorized
                )
            }
        )
    }

    private func displayDate(_ date: Date?) -> String {
        guard let date else { return String(localized: "Never") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func copySupportInformation() {
        let peerInfo = pairedProfiles.map { profile in
            SupportPeerInfo(
                peerID: profile.peerID,
                friendlyName: profile.friendlyName,
                model: profile.model,
                lastConnectedAt: profile.lastConnectedAt,
                keyFingerprint: profile.keyFingerprint
            )
        }
        let localFingerprint = PeerKeyFingerprint.string(
            for: discovery.identity.signingPublicKey
        )
        let info = SupportInformationFormatter.make(
            appVersion: appVersion,
            appBuild: appBuild,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            localFriendlyName: discovery.identity.name,
            localModel: discovery.localModel,
            localKeyFingerprint: localFingerprint,
            peers: peerInfo,
            connectionStatus: secureSession.status,
            connectedPeerID: secureSession.connectedPeerID
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if pasteboard.setString(info, forType: .string) {
            supportCopyStatus = String(localized: "Support information copied")
        } else {
            supportCopyStatus = String(localized: "Could not copy support information")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "Unknown"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "Unknown"
    }

    private var unavailablePairedPeerIDs: [UUID] {
        let visiblePeerIDs = Set(discovery.peers.map(\.identity.id))
        var unavailable = discovery.pairedPeerIDs.subtracting(visiblePeerIDs)
        if let connectedPeerID = secureSession.connectedPeerID,
           !visiblePeerIDs.contains(connectedPeerID) {
            unavailable.insert(connectedPeerID)
        }
        return unavailable.sorted {
            $0.uuidString.localizedStandardCompare($1.uuidString)
                == .orderedAscending
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Keyboard and mouse")
                .font(.subheadline.weight(.semibold))

            permissionStatusRow(
                title: "Input Monitoring",
                granted: inputCapture.hasInputMonitoringPermission
            )
            permissionStatusRow(
                title: "Accessibility",
                granted: inputSink.hasAccessibilityPermission
            )
            Text("The controlling Mac needs Input Monitoring and Accessibility; the receiving Mac needs Accessibility.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if let request = control.pendingIncomingControlRequest {
                incomingControlRequestSection(request)
            } else if control.isReceivingControl {
                VStack(alignment: .leading, spacing: 5) {
                    Text("This Mac is receiving remote control.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(returnKeyboardAndMouseTitle) {
                        control.endReceivingControl()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if control.isRemoteInputTearingDown {
                Text("Returning remote input to this Mac…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if control.state == .controlling || control.state == .suspended {
                Button("Return keyboard and mouse to this Mac") {
                    control.stopControl()
                }
            } else {
                Button("Request keyboard and mouse control") {
                    control.requestControl()
                }
                .disabled(
                    !inputCapture.hasInputMonitoringPermission
                        || !inputSink.hasAccessibilityPermission
                        || secureSession.connectedPeerID == nil
                        || !inputTopology.allowsLocalControl
                        || control.isReceivingControl
                        || control.isRemoteInputTearingDown
                        || bootstrap.combinedControlRequestInFlight
                )
            }

            if control.state == .controlling {
                Label(
                    "Press Control-Option-Command-Escape to interrupt sharing and return the keyboard and mouse to this Mac.",
                    systemImage: "escape"
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text("Control-Option-Command-O switches the display to the other Mac. Control-Option-Command-K toggles keyboard and mouse sharing. Escape is the emergency local-return shortcut.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("State: \(control.state.rawValue)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text(control.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(inputSink.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var topologySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Physical input path")
                .font(.subheadline.weight(.semibold))

            Picker("Keyboard and mouse", selection: $inputTopology.mode) {
                ForEach(InputTopologyMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }

            Text(inputTopology.mode.hardwareSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(inputTopology.statusMessage)
                .font(.caption2)
                .foregroundStyle(
                    inputTopology.allowsLocalControl
                        ? Color.secondary
                        : Color.orange
                )

            if !inputTopology.allowsLocalControl {
                Label(
                    "Control requests are disabled on this Mac until the physical input path is changed.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
            }
        }
    }

    private func incomingControlRequestSection(
        _ request: IncomingControlRequest
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(
                "\(peerDisplayName(for: request.peerID, from: discovery)) requests control of this Mac."
            )
                .font(.caption)
            Text("Allow only if you expect to use the other Mac's keyboard and mouse.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("Allow") {
                    control.acceptIncomingControlRequest(request.id)
                }
                .buttonStyle(.borderedProminent)
                Button("Deny") {
                    control.denyIncomingControlRequest(request.id)
                }
            }
        }
    }

    private var monitorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Monitor input")
                .font(.subheadline.weight(.semibold))

            Text("External display switching is optional; pairing and remote control work without an external display.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Automatic DDC/CI switching", isOn: $monitor.automationEnabled)
                .disabled(!monitor.supportsAutomaticDDCSwitching)

            if !monitor.supportsAutomaticDDCSwitching {
                Text("This Mac does not expose a native DDC/CI transport; use the monitor OSD input menu.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("M5 / USB-C preset") {
                    monitor.applyAppleSiliconUSBPreset()
                }
                Button("Intel / HDMI preset") {
                    monitor.applyIntelHDMIPreset()
                }
            }

            Picker("This Mac", selection: $monitor.localInput) {
                ForEach(MonitorInputSource.allCases, id: \.self) { input in
                    Text(input.name).tag(input)
                }
            }
            Picker("Other Mac", selection: $monitor.remoteInput) {
                ForEach(MonitorInputSource.allCases, id: \.self) { input in
                    Text(input.name).tag(input)
                }
            }

            Button("Detect DDC-capable displays") {
                monitor.refreshDetectedDisplays()
            }

            if monitor.detectedDisplays.isEmpty {
                Text("No DDC-capable display detected yet. Connect an external display, then detect it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(monitor.detectedDisplays) { display in
                    Button {
                        monitor.selectDisplay(display)
                    } label: {
                        HStack {
                            Image(
                                systemName: display.matches(
                                    selector: monitor.displaySelector
                                ) ? "checkmark.circle.fill" : "display"
                            )
                            Text(display.displayName)
                                .lineLimit(1)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        display.matches(selector: monitor.displaySelector)
                            ? Color.green : Color.primary
                    )
                }
            }

            if monitor.isDisplaySelectorVerified {
                Label("Selected DDC display verified", systemImage: "checkmark.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else {
                Text("Only a detected DDC-capable display can enable automatic switching.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            TextField("Native DDC display selector", text: $monitor.displaySelector)

            Button("Show other Mac") {
                let hadCombinedRequest =
                    bootstrap.combinedControlRequestInFlight
                let shouldCancelWaitingControl =
                    hadCombinedRequest
                        && control.state == .suspended
                bootstrap.cancelCombinedControlRequest()
                if shouldCancelWaitingControl {
                    // Stop the stale request before selecting the remote
                    // route; its invalidated completion cannot switch the
                    // display back to this Mac afterward.
                    control.stopControl(
                        reason: "Display route changed; input stayed local"
                    )
                }
                if control.isReceivingControl {
                    // The receiver's normal teardown restores the
                    // controller's display route and returns the shared
                    // keyboard/mouse to the controller.
                    control.endReceivingControl(
                        reason: "Returned input to the other Mac"
                    )
                } else if hadCombinedRequest {
                    // A second click while the display-first request is
                    // still resolving cancels that request and leaves the
                    // display on the explicitly selected remote route.
                    monitor.switchToRemote()
                } else if control.state == .connected
                    && inputTopology.allowsLocalControl {
                    // On the physical-input Mac (normally the M5 Pro), use
                    // the guarded display-first request so capture starts
                    // only after native DDC confirms the remote input. The
                    // guard is evaluated inside AppBootstrap, which refreshes
                    // live macOS permissions before it starts capture.
                    if !bootstrap.startCombinedControlRequest() {
                        monitor.switchToRemote()
                    }
                } else {
                    monitor.switchToRemote()
                }
            }

            // Keep a local display-only recovery action in the window. The
            // emergency shortcut is the preferred global path, but macOS may
            // refuse its Carbon registration when another app owns the same
            // key combination; users must still be able to restore the local
            // monitor without opening the OSD.
            if !control.isReceivingControl,
               control.state != .controlling,
               control.state != .suspended,
               !bootstrap.combinedControlRequestInFlight {
                Button("Return display to this Mac") {
                    bootstrap.cancelCombinedControlRequest()
                    control.requestLocalMonitorReturn {
                        monitor.switchToLocal()
                    }
                }
            }

            if inputTopology.allowsLocalControl {
                Button(shareKeyboardAndMouseTitle) {
                    _ = bootstrap.startCombinedControlRequest()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !canRequestControl
                        || bootstrap.combinedControlRequestInFlight
                )
                Text(
                    "This switches the display, then shares the keyboard and mouse. Control-Option-Command-O switches only the display; Control-Option-Command-K toggles sharing; Control-Option-Command-Escape interrupts and returns them to this Mac."
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let combinedControlStatus = bootstrap.combinedControlStatus {
                    Text(combinedControlStatus)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Text(monitor.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let diagnostic = monitor.diagnostic {
                Text("DDC diagnostic: \(diagnostic)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Text("If DDC fails, use the monitor OSD input menu.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Do not switch the monitor before the request guards can succeed. A
    /// disconnected or permission-blocked controller should remain on its
    /// current display while it fixes setup, rather than switching away with
    /// no control request sent.
    private var canRequestControl: Bool {
        inputTopology.allowsLocalControl
            && monitor.automationEnabled
            && monitor.isDisplaySelectorVerified
            && inputCapture.hasInputMonitoringPermission
            && inputSink.hasAccessibilityPermission
            && secureSession.connectedPeerID != nil
            && control.state == .connected
            && control.pendingIncomingControlRequest == nil
            && !control.isReceivingControl
            && !control.isRemoteInputTearingDown
    }

    private var connectedPeerName: String {
        guard let peerID = secureSession.connectedPeerID else {
            return "the other Mac"
        }
        return peerDisplayName(for: peerID, from: discovery)
    }

    private var shareKeyboardAndMouseTitle: String {
        String(
            format: String(localized: "Share keyboard and mouse with %@"),
            connectedPeerName
        )
    }

    private var returnKeyboardAndMouseTitle: String {
        String(
            format: String(localized: "Return keyboard and mouse to %@"),
            connectedPeerName
        )
    }

    private var startupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                "Launch MacKVM at Login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: launchAtLogin.setEnabled
                )
            )
            .disabled(launchAtLogin.isUpdating)
            if let status = launchAtLogin.status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if launchAtLogin.isAwaitingApproval {
                Button("Remove pending Login Item") {
                    launchAtLogin.setEnabled(false)
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
        .onAppear {
            // Reflect changes made directly in System Settings while MacKVM
            // remains running.
            if !launchAtLogin.isUpdating {
                launchAtLogin.refresh()
            }
        }
    }

    private func permissionStatusRow(
        title: String,
        granted: Bool
    ) -> some View {
        HStack {
            Text(title)
            Spacer()
            Label(
                granted ? "Granted" : "Required",
                systemImage: granted
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(granted ? .green : .orange)
        }
    }
}
