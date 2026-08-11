import AppKit
import Combine
import MacKVMCore
import SwiftUI

@main
struct MacKVMApp: App {
    @StateObject private var bootstrap = AppBootstrap()

    var body: some Scene {
        MenuBarExtra {
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
                    recoveryMessage: bootstrap.recoveryMessage
                )
            }
        } label: {
            if let control = bootstrap.control {
                MacKVMMenuBarLabel(control: control)
            } else {
                Label("MacKVM", systemImage: "keyboard")
            }
        }
        .menuBarExtraStyle(.window)
    }
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
            Image(systemName: "keyboard")
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
    @Published private(set) var recoveryMessage: String?
    private var controlRequestObservation: AnyCancellable?

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
            self.discovery = discovery
            self.secureSession = secureSession
            self.inputCapture = inputCapture
            self.inputSink = inputSink
            self.control = control
            self.monitor = monitor
            self.controlRequestNotifier = controlRequestNotifier
            errorMessage = nil
            canResetIdentity = false
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
            controlRequestObservation = control.$pendingIncomingControlRequest
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak controlRequestNotifier] request in
                    if request == nil {
                        controlRequestNotifier?.clearActiveRequest()
                    }
                }
            if OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                hadExistingDeviceCredentials: hadExistingDeviceCredentials
            ) {
                startNetworkServices()
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
        }
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
                NSApplication.shared.terminate(nil)
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
    @AppStorage(OnboardingDefaults.localNetworkAccessReviewedKey)
    private var localNetworkAccessReviewed = false
    @State private var awaitingLocalNetworkResponse = false
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

                    topologySection
                    Divider()

                    if !discovery.pendingRequests.isEmpty {
                        pendingSection
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
                    bootstrap.clearControlRequestNotifications()
                    // Latch the final local-route intent first, but do not
                    // resolve a cancelled receiver monitor route until the
                    // coordinator has recorded its quit teardown. Otherwise
                    // that completion could make it release remote input a
                    // second time before `stopForQuit` can observe it.
                    let cancelledMonitorRoutes = monitor.beginTermination()
                    control.stopForQuit {
                        discovery.stop()
                        secureSession.stop()
                        monitor.switchToLocalForTermination {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                    cancelledMonitorRoutes.forEach { $0() }
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
            Text("MacKVM")
                .font(.headline)
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
            } else if awaitingLocalNetworkResponse {
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
                if awaitingLocalNetworkResponse {
                    Button("I handled the macOS prompt") {
                        awaitingLocalNetworkResponse = false
                        localNetworkAccessReviewed = true
                        bootstrap.startNetworkServices()
                        refreshSetupState()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Enable Local Network") {
                        awaitingLocalNetworkResponse = true
                        // Bonjour traffic triggers the macOS Local Network
                        // prompt, so start it before recording the user's
                        // acknowledgement in the next step.
                        bootstrap.startNetworkServices()
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

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pairing requests")
                .font(.subheadline.weight(.semibold))

            ForEach(discovery.pendingRequests) { request in
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.peer.name)
                    Text("Confirm both Macs show \(request.verificationCode)")
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

            if let request = control.pendingIncomingControlRequest {
                incomingControlRequestSection(request)
            } else if control.isReceivingControl {
                VStack(alignment: .leading, spacing: 5) {
                    Text("This Mac is receiving remote control.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Stop remote control") {
                        control.endReceivingControl()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if control.isRemoteInputTearingDown {
                Text("Returning remote input to this Mac…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if control.state == .controlling || control.state == .suspended {
                Button("Return input to this Mac") {
                    control.stopControl()
                }
            } else {
                Button("Request control of other Mac") {
                    control.requestControl()
                }
                .disabled(
                    !inputCapture.hasInputMonitoringPermission
                        || !inputSink.hasAccessibilityPermission
                        || secureSession.connectedPeerID == nil
                        || !inputTopology.allowsLocalControl
                        || control.isReceivingControl
                        || control.isRemoteInputTearingDown
                        || !setupState.isReadyForInputSharing
                )
            }

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

            HStack {
                Button("Show this Mac") {
                    monitor.switchToLocal()
                }
                Button("Show other Mac") {
                    monitor.switchToRemote()
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
