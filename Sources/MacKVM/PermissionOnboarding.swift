import AppKit

enum MacKVMPermission: Equatable {
    case inputMonitoring
    case accessibility

    var displayName: String {
        switch self {
        case .inputMonitoring:
            return "Input Monitoring"
        case .accessibility:
            return "Accessibility"
        }
    }
}

enum PermissionOnboardingPolicy {
    static func missingPermissions(
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool
    ) -> [MacKVMPermission] {
        var missing: [MacKVMPermission] = []
        if !inputMonitoringGranted {
            missing.append(.inputMonitoring)
        }
        if !accessibilityGranted {
            missing.append(.accessibility)
        }
        return missing
    }

    static func refresh(
        inputCapture: InputCaptureService,
        inputSink: RemoteInputSink
    ) {
        inputCapture.refreshPermission()
        inputSink.refreshPermission()
    }
}

enum PrivacySettings {
    private static let inputMonitoringURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )
    private static let accessibilityURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )

    static func open(_ permission: MacKVMPermission) {
        let url: URL?
        switch permission {
        case .inputMonitoring:
            url = inputMonitoringURL
        case .accessibility:
            url = accessibilityURL
        }
        if let url, !NSWorkspace.shared.open(url) {
            NSLog("MacKVM could not open the %@ settings pane", permission.displayName)
        }
    }
}

@MainActor
enum PermissionOnboardingPresenter {
    // Launch onboarding is intentionally process-scoped: macOS permission
    // prompts should be scheduled only once during each app launch.
    private static var didFinishLaunching = false
    private static var hasScheduled = false
    private static var pendingServices:
        (inputCapture: InputCaptureService, inputSink: RemoteInputSink)?

    static func scheduleIfNeeded(
        inputCapture: InputCaptureService,
        inputSink: RemoteInputSink
    ) {
        guard !hasScheduled else { return }
        hasScheduled = true
        if didFinishLaunching {
            presentIfNeeded(
                inputCapture: inputCapture,
                inputSink: inputSink
            )
        } else {
            pendingServices = (inputCapture, inputSink)
        }
    }

    static func applicationDidFinishLaunching() {
        didFinishLaunching = true
        guard let services = pendingServices else { return }
        pendingServices = nil
        presentIfNeeded(
            inputCapture: services.inputCapture,
            inputSink: services.inputSink
        )
    }

    private static func presentIfNeeded(
        inputCapture: InputCaptureService,
        inputSink: RemoteInputSink
    ) {
        PermissionOnboardingPolicy.refresh(
            inputCapture: inputCapture,
            inputSink: inputSink
        )
        let missing = PermissionOnboardingPolicy.missingPermissions(
            inputMonitoringGranted:
                inputCapture.hasInputMonitoringPermission,
            accessibilityGranted:
                inputSink.hasAccessibilityPermission
        )
        guard let nextPermission = missing.first else { return }

        if #available(macOS 14.0, *) {
            NSApplication.shared.activate()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Finish setting up MacKVM"
        let permissionNames = missing
            .map(\.displayName)
            .joined(separator: " and ")
        alert.informativeText = """
        MacKVM needs access to \(permissionNames) to share the keyboard and \
        mouse. macOS will now request \(nextPermission.displayName), one \
        permission at a time. After granting it, reopen MacKVM to continue \
        setup if another permission is still required.
        """
        alert.addButton(withTitle: "Request Permissions")
        alert.addButton(withTitle: "Later")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        switch nextPermission {
        case .inputMonitoring:
            inputCapture.requestPermission()
        case .accessibility:
            inputSink.requestPermission()
        }
    }
}
