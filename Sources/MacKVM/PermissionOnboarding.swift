import AppKit

/// Persists the Local Network setup acknowledgement and migrates installations
/// created before the acknowledgement existed. A persisted MacKVM identity
/// proves this is an upgrade rather than a brand-new installation; its network
/// services retain the prior startup behavior while the recovery shortcut
/// remains available because macOS does not expose a Local Network preflight.
enum OnboardingDefaults {
    static let localNetworkAccessReviewedKey =
        "MacKVM.onboarding.localNetworkAccessReviewed"

    /// Resolves and persists the Local Network acknowledgement. A missing
    /// value is migrated from the device-identity state, then saved so later
    /// calls are a plain read of the user's resolved setup state.
    static func resolveLocalNetworkAccessReviewed(
        defaults: UserDefaults = .standard,
        hadExistingDeviceCredentials: Bool
    ) -> Bool {
        if defaults.object(forKey: localNetworkAccessReviewedKey) != nil {
            return defaults.bool(forKey: localNetworkAccessReviewedKey)
        }
        guard hadExistingDeviceCredentials else {
            // `load()` creates credentials during the first launch. Persisting
            // the incomplete state here ensures a quit or crash before the
            // Local Network step cannot be mistaken for a pre-onboarding
            // installation on the next launch.
            defaults.set(false, forKey: localNetworkAccessReviewedKey)
            return false
        }
        defaults.set(true, forKey: localNetworkAccessReviewedKey)
        return true
    }
}

/// A setup requirement shown in MacKVM's first-run checklist.
///
/// Local Network deliberately means that the person has reviewed the macOS
/// prompt, rather than that MacKVM can prove permission was granted. macOS
/// does not expose a public preflight API for Local Network access; Bonjour
/// activity causes the system prompt instead.
enum MacKVMPermission: CaseIterable, Equatable, Hashable, Identifiable {
    case localNetwork
    case inputMonitoring
    case accessibility

    var id: Self { self }

    var displayName: String {
        switch self {
        case .localNetwork:
            return "Local Network"
        case .inputMonitoring:
            return "Input Monitoring"
        case .accessibility:
            return "Accessibility"
        }
    }

    /// Whether macOS provides an in-app request API for this requirement.
    /// Local Network access is requested by the app's Bonjour traffic, not by
    /// a public permission API, so the checklist offers its Settings link.
    var canRequestInApp: Bool {
        switch self {
        case .localNetwork:
            return false
        case .inputMonitoring, .accessibility:
            return true
        }
    }
}

enum PermissionOnboardingChecklistStatus: Equatable {
    case complete
    case current
    case waiting
}

struct PermissionOnboardingChecklistItem: Identifiable, Equatable {
    let permission: MacKVMPermission
    let status: PermissionOnboardingChecklistStatus

    var id: MacKVMPermission { permission }
}

/// A value-type snapshot for the visible setup checklist.
///
/// It intentionally separates Local Network *awareness* from permissions
/// which macOS lets us preflight. This prevents the UI from incorrectly
/// reporting that Local Network access has been granted when it has only
/// shown the user where to review it.
struct PermissionOnboardingState: Equatable {
    let localNetworkAccessReviewed: Bool
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool

    init(
        localNetworkAccessReviewed: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool
    ) {
        self.localNetworkAccessReviewed = localNetworkAccessReviewed
        self.inputMonitoringGranted = inputMonitoringGranted
        self.accessibilityGranted = accessibilityGranted
    }

    var nextPermission: MacKVMPermission? {
        PermissionOnboardingPolicy.setupOrder.first { !isComplete($0) }
    }

    var isChecklistComplete: Bool {
        nextPermission == nil
    }

    /// Input sharing is safe to enable once its two enforceable permissions
    /// are granted. Pairing/network reachability remains verified separately
    /// by the networking services.
    var isReadyForInputSharing: Bool {
        inputMonitoringGranted && accessibilityGranted
    }

    var checklist: [PermissionOnboardingChecklistItem] {
        let current = nextPermission
        return PermissionOnboardingPolicy.setupOrder.map { permission in
            let status: PermissionOnboardingChecklistStatus
            if isComplete(permission) {
                status = .complete
            } else if permission == current {
                status = .current
            } else {
                status = .waiting
            }
            return PermissionOnboardingChecklistItem(
                permission: permission,
                status: status
            )
        }
    }

    func isComplete(_ permission: MacKVMPermission) -> Bool {
        switch permission {
        case .localNetwork:
            return localNetworkAccessReviewed
        case .inputMonitoring:
            return inputMonitoringGranted
        case .accessibility:
            return accessibilityGranted
        }
    }
}

enum PermissionOnboardingPolicy {
    static let setupOrder: [MacKVMPermission] = [
        .localNetwork,
        .inputMonitoring,
        .accessibility
    ]

    /// Builds a pure setup snapshot. The UI can persist
    /// `localNetworkAccessReviewed` in AppStorage/UserDefaults after the
    /// person has reviewed the system prompt or Settings page.
    static func checklistState(
        localNetworkAccessReviewed: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool
    ) -> PermissionOnboardingState {
        PermissionOnboardingState(
            localNetworkAccessReviewed: localNetworkAccessReviewed,
            inputMonitoringGranted: inputMonitoringGranted,
            accessibilityGranted: accessibilityGranted
        )
    }

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

    /// Refreshes the two permissions macOS lets MacKVM preflight, then returns
    /// a new checklist snapshot. Call when the app becomes active or its menu
    /// is opened after returning from System Settings.
    static func refreshChecklistState(
        localNetworkAccessReviewed: Bool,
        inputCapture: InputCaptureService,
        inputSink: RemoteInputSink
    ) -> PermissionOnboardingState {
        refresh(inputCapture: inputCapture, inputSink: inputSink)
        return checklistState(
            localNetworkAccessReviewed: localNetworkAccessReviewed,
            inputMonitoringGranted: inputCapture.hasInputMonitoringPermission,
            accessibilityGranted: inputSink.hasAccessibilityPermission
        )
    }

    static func refresh(
        inputCapture: InputCaptureService,
        inputSink: RemoteInputSink
    ) {
        inputCapture.refreshPermission()
        inputSink.refreshPermission()
    }

    /// Requests a permission which has a public in-app request API.
    /// Returns `false` for Local Network because that prompt is owned by
    /// macOS/Bonjour; callers should offer `PrivacySettings.open` instead.
    @discardableResult
    static func requestPermission(
        _ permission: MacKVMPermission,
        inputCapture: InputCaptureService,
        inputSink: RemoteInputSink
    ) -> Bool {
        switch permission {
        case .localNetwork:
            return false
        case .inputMonitoring:
            inputCapture.requestPermission()
            return true
        case .accessibility:
            inputSink.requestPermission()
            return true
        }
    }
}

enum PrivacySettings {
    private static let localNetworkURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
    )
    private static let inputMonitoringURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
    )
    private static let accessibilityURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    )

    static func url(for permission: MacKVMPermission) -> URL? {
        switch permission {
        case .localNetwork:
            return localNetworkURL
        case .inputMonitoring:
            return inputMonitoringURL
        case .accessibility:
            return accessibilityURL
        }
    }

    /// Opens the most relevant System Settings privacy pane. The Boolean lets
    /// a SwiftUI checklist surface a useful fallback message when macOS cannot
    /// open the deep link.
    @discardableResult
    static func open(_ permission: MacKVMPermission) -> Bool {
        guard let url = url(for: permission) else {
            NSLog("MacKVM has no settings URL for %@", permission.displayName)
            return false
        }
        let opened = NSWorkspace.shared.open(url)
        if !opened {
            NSLog("MacKVM could not open the %@ settings pane", permission.displayName)
        }
        return opened
    }
}
