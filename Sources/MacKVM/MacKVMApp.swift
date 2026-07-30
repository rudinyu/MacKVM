import AppKit
import MacKVMCore
import SwiftUI

@MainActor
private final class MacKVMApplicationDelegate:
    NSObject,
    NSApplicationDelegate
{
    func applicationDidFinishLaunching(_ notification: Notification) {
        PermissionOnboardingPresenter.applicationDidFinishLaunching()
    }
}

@main
struct MacKVMApp: App {
    @NSApplicationDelegateAdaptor(MacKVMApplicationDelegate.self)
    private var applicationDelegate
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
                    launchAtLogin: bootstrap.launchAtLogin
                )
            } else {
                BootstrapErrorView(
                    message: bootstrap.errorMessage
                        ?? "MacKVM could not load its device key."
                )
            }
        } label: {
            Label("MacKVM", systemImage: "display.2")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private final class AppBootstrap: ObservableObject {
    let discovery: PeerDiscoveryService?
    let secureSession: SecureSessionService?
    let inputCapture: InputCaptureService?
    let inputSink: RemoteInputSink?
    let control: ControlCoordinator?
    let monitor: MonitorController?
    let launchAtLogin = LaunchAtLoginController()
    let errorMessage: String?

    init() {
        do {
            let credentials = try DeviceCredentialsStore.load()
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
                inputSink: inputSink
            )
            control.onControllingStarted = monitor.switchToRemote
            control.onControllingStopped = { monitor.switchToLocal() }
            control.onReceivingStarted = { monitor.switchToLocal() }
            control.onReceivingStopped = monitor.switchToRemote
            discovery.start()
            secureSession.start()
            self.discovery = discovery
            self.secureSession = secureSession
            self.inputCapture = inputCapture
            self.inputSink = inputSink
            self.control = control
            self.monitor = monitor
            errorMessage = nil
            PermissionOnboardingPresenter.scheduleIfNeeded(
                inputCapture: inputCapture,
                inputSink: inputSink
            )
        } catch {
            discovery = nil
            secureSession = nil
            inputCapture = nil
            inputSink = nil
            control = nil
            monitor = nil
            errorMessage = "Could not access the device key: \(error.localizedDescription)"
        }
    }
}

private struct BootstrapErrorView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacKVM is unavailable")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct MacKVMMenuView: View {
    @ObservedObject var discovery: PeerDiscoveryService
    @ObservedObject var secureSession: SecureSessionService
    @ObservedObject var inputCapture: InputCaptureService
    @ObservedObject var inputSink: RemoteInputSink
    @ObservedObject var control: ControlCoordinator
    @ObservedObject var monitor: MonitorController
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            if !discovery.pendingRequests.isEmpty {
                pendingSection
                Divider()
            }

            peerSection
            Divider()
            inputSection
            Divider()
            monitorSection
            Divider()
            startupSection
            Divider()

            HStack {
                Text(discovery.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Quit") {
                    control.stopControl(reason: "MacKVM is quitting")
                    discovery.stop()
                    secureSession.stop()
                    monitor.switchToLocal {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            PermissionOnboardingPolicy.refresh(
                inputCapture: inputCapture,
                inputSink: inputSink
            )
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

            if discovery.peers.isEmpty {
                Text("Searching on the local network…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(discovery.peers) { peer in
                    HStack {
                        Image(systemName: "laptopcomputer")
                        Text(peer.name)
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
                                secureSession.revoke(peer.identity.id)
                                discovery.forget(peer.identity.id)
                            }
                        case .changedKey:
                            Label("Key changed", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button("Forget old key", role: .destructive) {
                                secureSession.revoke(peer.identity.id)
                                discovery.forget(peer.identity.id)
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
                        Text("Mac \(peerID.uuidString.prefix(8))")
                            .font(.caption.monospaced())
                        Spacer()
                        if secureSession.connectedPeerID == peerID {
                            Button("Disconnect") {
                                secureSession.disconnect()
                            }
                        }
                        Button("Forget", role: .destructive) {
                            secureSession.revoke(peerID)
                            discovery.forget(peerID)
                        }
                    }
                }
            }
            Text(secureSession.status)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
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

            permissionRow(
                title: "Input Monitoring",
                granted: inputCapture.hasInputMonitoringPermission,
                requestAction: inputCapture.requestPermission,
                settingsAction: {
                    PrivacySettings.open(.inputMonitoring)
                }
            )
            permissionRow(
                title: "Accessibility",
                granted: inputSink.hasAccessibilityPermission,
                requestAction: inputSink.requestPermission,
                settingsAction: {
                    PrivacySettings.open(.accessibility)
                }
            )

            if control.state == .controlling || control.state == .suspended {
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
                        || control.isReceivingControl
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

    private var monitorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BenQ MA270U input")
                .font(.subheadline.weight(.semibold))

            Toggle("Automatic DDC/CI switching", isOn: $monitor.automationEnabled)

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

            TextField("m1ddc display number or UUID", text: $monitor.displaySelector)
            TextField("m1ddc executable path", text: $monitor.executablePath)

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

    private func permissionRow(
        title: String,
        granted: Bool,
        requestAction: @escaping () -> Void,
        settingsAction: @escaping () -> Void
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
            if !granted {
                Button("Request", action: requestAction)
                Button("Settings", action: settingsAction)
            }
        }
    }
}
