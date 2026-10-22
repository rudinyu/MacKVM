import AppKit

/// Persists the Local Network setup acknowledgement and the last app build.
/// The first build recorded by this version and each later build change clear
/// the old acknowledgement so the user can review Local Network settings
/// again. Existing credentials remain untouched and still allow discovery to
/// start while the acknowledgement is incomplete.
enum OnboardingDefaults {
    static let localNetworkAccessReviewedKey =
        "MacKVM.onboarding.localNetworkAccessReviewed"
    static let lastExecutedBuildKey =
        "MacKVM.onboarding.lastExecutedBuild"

    /// Resolves and persists the Local Network acknowledgement. A missing
    /// value is migrated from the device-identity state only after the current
    /// build has already been recorded.
    static func resolveLocalNetworkAccessReviewed(
        defaults: UserDefaults = .standard,
        hadExistingDeviceCredentials: Bool,
        currentBuild: String
    ) -> Bool {
        let previousBuild = defaults.string(forKey: lastExecutedBuildKey)
        let isFirstTrackedBuild = previousBuild == nil
        let buildChanged = previousBuild != currentBuild
        defaults.set(currentBuild, forKey: lastExecutedBuildKey)

        // A first run of build tracking and every later build change require
        // the Local Network prompt/settings review to be revisited. This only
        // resets the acknowledgement; it does not touch device credentials.
        if isFirstTrackedBuild || buildChanged {
            defaults.set(false, forKey: localNetworkAccessReviewedKey)
            return false
        }

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
            return String(localized: "Local Network")
        case .inputMonitoring:
            return String(localized: "Input Monitoring")
        case .accessibility:
            if #available(macOS 27, *) {
                return String(localized: "Device Control and Data Access")
            }
            return String(localized: "Accessibility")
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

enum LocalNetworkSetupStatus: Equatable {
    case working
    case reachable
    case blocked
    case checking
    case unverified
    case unconfirmed
    case busy
    case noPeer
    case unavailable

    /// A live authenticated connection or a successful network probe is
    /// positive operational evidence. This does not represent a persisted
    /// macOS permission grant or review acknowledgement.
    var hasPositiveOperationalEvidence: Bool {
        switch self {
        case .working, .reachable:
            true
        case .blocked, .checking, .unverified, .unconfirmed, .busy,
             .noPeer, .unavailable:
            false
        }
    }

    static func resolve(
        hasCurrentAuthenticatedConnection: Bool,
        isExplicitlyBlocked: Bool,
        isChecking: Bool,
        latestCheckResult: LocalNetworkCheckResult?
    ) -> Self {
        // A DNS-SD denial is authoritative even when an older socket or probe
        // still looks healthy. Do not let those stale results mask a current
        // browser/listener denial.
        if isExplicitlyBlocked {
            return .blocked
        }
        if isChecking {
            return .checking
        }
        if let latestCheckResult {
            switch latestCheckResult {
            case .reachable:
                return .reachable
            case .blocked:
                return .blocked
            case .unconfirmed:
                return .unconfirmed
            case .busy:
                return .busy
            case .noPeer:
                return .noPeer
            case .unavailable:
                return .unavailable
            }
        }
        if hasCurrentAuthenticatedConnection {
            return .working
        }
        return .unverified
    }

    var supportLabel: String {
        switch self {
        case .working:
            "Connection working"
        case .reachable:
            "Network test succeeded"
        case .blocked:
            "Local Network access blocked by macOS"
        case .checking:
            "Checking Local Network access"
        case .unverified:
            "Access not verified"
        case .unconfirmed:
            "Network test could not be confirmed"
        case .busy:
            "Network check waiting for pairing to finish"
        case .noPeer:
            "No peer available to test"
        case .unavailable:
            "Network check unavailable"
        }
    }
}

/// Presents Local Network actions from current operational evidence and the
/// onboarding workflow. The persisted review is history only: it can advance
/// the checklist, but it cannot hide Settings or a manual network check.
struct LocalNetworkSetupActionPresentation: Equatable {
    var showsEnableAction: Bool
    var showsPromptAcknowledgement: Bool
    var showsSettingsAction: Bool
    var showsCheckAction: Bool
    var showsAwaitingPromptHint: Bool

    var hasVisibleActions: Bool {
        showsEnableAction
            || showsPromptAcknowledgement
            || showsSettingsAction
            || showsCheckAction
    }

    static let hidden = Self(
        showsEnableAction: false,
        showsPromptAcknowledgement: false,
        showsSettingsAction: false,
        showsCheckAction: false,
        showsAwaitingPromptHint: false
    )

    static func resolve(
        status: LocalNetworkSetupStatus,
        accessWasReviewed: Bool,
        isAwaitingPromptResponse: Bool,
        canAcknowledgeCurrentPrompt: Bool,
        networkServicesStarted: Bool
    ) -> Self {
        // A working authenticated session or a successful endpoint probe is
        // the only evidence that hides the Local Network setup actions.
        guard !status.hasPositiveOperationalEvidence else { return .hidden }

        // An authoritative denial always offers a way to revisit Settings and
        // re-test. A stale prompt acknowledgement cannot override the denial.
        if status == .blocked {
            return Self(
                showsEnableAction: false,
                showsPromptAcknowledgement: false,
                showsSettingsAction: true,
                showsCheckAction: true,
                showsAwaitingPromptHint: false
            )
        }

        // The acknowledgement is specific to the current, unreviewed
        // first-run prompt workflow. It is not a substitute for checking an
        // existing installation whose services have already started.
        if isAwaitingPromptResponse,
           canAcknowledgeCurrentPrompt,
           !accessWasReviewed {
            return Self(
                showsEnableAction: false,
                showsPromptAcknowledgement: true,
                showsSettingsAction: true,
                showsCheckAction: false,
                showsAwaitingPromptHint: true
            )
        }

        // Bonjour is what triggers the macOS prompt. Offer that action only
        // for a genuinely new, unreviewed setup whose services have not yet
        // started. Existing installations and uncertain test results use the
        // explicit Settings/check path instead of implying that permission is
        // missing.
        if status == .unverified,
           !accessWasReviewed,
           !networkServicesStarted {
            return Self(
                showsEnableAction: true,
                showsPromptAcknowledgement: false,
                showsSettingsAction: true,
                showsCheckAction: false,
                showsAwaitingPromptHint: false
            )
        }

        return Self(
            showsEnableAction: false,
            showsPromptAcknowledgement: false,
            showsSettingsAction: true,
            showsCheckAction: true,
            showsAwaitingPromptHint: false
        )
    }
}

enum LocalNetworkStatusFreshnessPolicy {
    static func hasNewAuthenticatedPeer(
        previousPeerID: UUID?,
        currentPeerID: UUID?
    ) -> Bool {
        guard let currentPeerID else { return false }
        return previousPeerID != currentPeerID
    }
}

/// Shared state for the Local Network prompt and authenticated-session
/// lifecycle. Keeping the last peer beside the prompt flags lets the app
/// publish only meaningful transitions, even if a publisher replays its
/// current value to a replacement observer.
struct LocalNetworkPermissionLifecycleState: Equatable {
    enum ConnectionChange: Equatable {
        case unchanged
        case disconnected
        case connected(UUID)
    }

    private(set) var latestAuthenticatedPeerID: UUID?
    private(set) var isAwaitingResponse = false
    private(set) var canAcknowledgeCurrentPrompt = false

    init(latestAuthenticatedPeerID: UUID? = nil) {
        self.latestAuthenticatedPeerID = latestAuthenticatedPeerID
    }

    @discardableResult
    mutating func beginPermissionRequest(
        networkServicesStarted: Bool
    ) -> Bool {
        guard !networkServicesStarted,
              !isAwaitingResponse || !canAcknowledgeCurrentPrompt else {
            return false
        }
        isAwaitingResponse = true
        canAcknowledgeCurrentPrompt = true
        return true
    }

    @discardableResult
    mutating func completePermissionRequest() -> Bool {
        guard isAwaitingResponse || canAcknowledgeCurrentPrompt else {
            return false
        }
        isAwaitingResponse = false
        canAcknowledgeCurrentPrompt = false
        return true
    }

    @discardableResult
    mutating func authenticatedConnectionDidChange(
        to peerID: UUID?
    ) -> ConnectionChange {
        guard peerID != latestAuthenticatedPeerID else { return .unchanged }
        let previousPeerID = latestAuthenticatedPeerID
        latestAuthenticatedPeerID = peerID

        guard let peerID else { return .disconnected }
        guard LocalNetworkStatusFreshnessPolicy.hasNewAuthenticatedPeer(
            previousPeerID: previousPeerID,
            currentPeerID: peerID
        ) else {
            return .unchanged
        }
        completePermissionRequest()
        return .connected(peerID)
    }
}

/// A successful TCP probe is temporary, peer-specific evidence. It is useful
/// for setup guidance, but it must not outlive the endpoint it tested or be
/// mistaken for an authenticated secure session.
struct LocalNetworkCheckEvidence: Equatable {
    static let reachableEvidenceLifetime: TimeInterval = 60

    private(set) var result: LocalNetworkCheckResult?
    private(set) var checkedAt: Date?
    private(set) var peerID: UUID?

    mutating func record(
        _ result: LocalNetworkCheckResult,
        at checkedAt: Date,
        peerID: UUID?
    ) {
        self.result = result
        self.checkedAt = checkedAt
        self.peerID = result == .reachable ? peerID : nil
    }

    /// The manual check completion omits the peer selected after a discovery
    /// wait. Positive evidence comes from the peer-specific recovery callback;
    /// never replace that evidence with an unassociated completion result.
    @discardableResult
    mutating func recordManualCheckCompletion(
        _ result: LocalNetworkCheckResult,
        at checkedAt: Date
    ) -> Bool {
        guard result != .reachable else { return false }
        record(result, at: checkedAt, peerID: nil)
        return true
    }

    @discardableResult
    mutating func invalidate() -> Bool {
        guard result != nil || peerID != nil else { return false }
        result = nil
        peerID = nil
        return true
    }

    @discardableResult
    mutating func invalidate(
        for connectionChange: LocalNetworkPermissionLifecycleState.ConnectionChange
    ) -> Bool {
        switch connectionChange {
        case .unchanged:
            return false
        case .disconnected, .connected:
            return invalidate()
        }
    }

    @discardableResult
    mutating func invalidateIfPeerUnavailable(
        availablePeerIDs: Set<UUID>
    ) -> Bool {
        guard result == .reachable,
              let peerID,
              !availablePeerIDs.contains(peerID) else {
            return false
        }
        return invalidate()
    }

    @discardableResult
    mutating func expireReachableEvidence(
        now: Date,
        availablePeerIDs: Set<UUID>
    ) -> Bool {
        guard result == .reachable,
              currentResult(
                now: now,
                availablePeerIDs: availablePeerIDs
              ) == nil else {
            return false
        }
        return invalidate()
    }

    func currentResult(
        now: Date,
        availablePeerIDs: Set<UUID>
    ) -> LocalNetworkCheckResult? {
        guard result == .reachable else { return result }
        guard let checkedAt else { return nil }
        let age = now.timeIntervalSince(checkedAt)
        guard age >= 0, age < Self.reachableEvidenceLifetime else {
            return nil
        }
        guard let peerID, availablePeerIDs.contains(peerID) else { return nil }
        return .reachable
    }
}

enum LocalNetworkCheckLifecyclePolicy {
    static let minimumAutomaticCheckInterval: TimeInterval = 5
    static let minimumEventDrivenCheckInterval: TimeInterval = 1.5

    static func canRunManualCheck(
        hasActiveAuthenticatedConnection: Bool,
        hasActivePairing: Bool,
        hasPendingConnectionAttempt: Bool
    ) -> Bool {
        // A manual probe can recover a pending outbound connection, so that
        // state deliberately does not disable the user's Check action.
        _ = hasPendingConnectionAttempt
        return !hasActiveAuthenticatedConnection && !hasActivePairing
    }

    static func shouldStartAutomaticCheck(
        isPolling: Bool,
        networkServicesStarted: Bool,
        checkInProgress: Bool,
        lastStartedAt: Date?,
        now: Date,
        hasActiveAuthenticatedConnection: Bool = false,
        hasActivePairing: Bool = false,
        hasPendingConnectionAttempt: Bool = false,
        hasFreshReachableEvidence: Bool = false,
        eventDriven: Bool = false
    ) -> Bool {
        guard isPolling,
              networkServicesStarted,
              !checkInProgress,
              !hasActiveAuthenticatedConnection,
              !hasActivePairing,
              !hasPendingConnectionAttempt,
              !hasFreshReachableEvidence else {
            return false
        }
        guard let lastStartedAt else { return true }
        let minimumInterval = eventDriven
            ? minimumEventDrivenCheckInterval
            : minimumAutomaticCheckInterval
        return now.timeIntervalSince(lastStartedAt)
            >= minimumInterval
    }
}

@MainActor
protocol PermissionRefreshTimerToken: AnyObject {
    func invalidate()
}

@MainActor
protocol PermissionRefreshScheduling {
    func schedule(
        every interval: TimeInterval,
        action: @escaping () -> Void
    ) -> any PermissionRefreshTimerToken
}

@MainActor
private final class FoundationPermissionRefreshTimerToken:
    PermissionRefreshTimerToken {
    private var timer: Timer?

    init(interval: TimeInterval, action: @escaping () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            action()
        }
        timer.tolerance = min(interval * 0.125, 0.5)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
struct FoundationPermissionRefreshScheduler: PermissionRefreshScheduling {
    func schedule(
        every interval: TimeInterval,
        action: @escaping () -> Void
    ) -> any PermissionRefreshTimerToken {
        FoundationPermissionRefreshTimerToken(
            interval: interval,
            action: action
        )
    }
}

/// Polls preflight permission APIs only while a MacKVM surface is visible.
/// App deactivation does not stop the timer because System Settings may be in
/// front while the MacKVM window remains open.
@MainActor
final class PermissionRefreshMonitor {
    private let scheduler: any PermissionRefreshScheduling
    private let interval: TimeInterval
    private let refresh: () -> Void
    private var timer: (any PermissionRefreshTimerToken)?
    private(set) var visibleSurfaces = Set<UUID>()
    private(set) var applicationIsActive = true
    private(set) var isTerminating = false

    var isPolling: Bool { timer != nil }

    init(
        interval: TimeInterval = 2,
        scheduler: (any PermissionRefreshScheduling)? = nil,
        refresh: @escaping () -> Void
    ) {
        self.interval = interval
        self.scheduler = scheduler ?? FoundationPermissionRefreshScheduler()
        self.refresh = refresh
    }

    func surfaceAppeared(_ id: UUID) {
        setSurfaceVisibility(id, isVisible: true)
    }

    func surfaceDisappeared(_ id: UUID) {
        setSurfaceVisibility(id, isVisible: false)
    }

    func setSurfaceVisibility(_ id: UUID, isVisible: Bool) {
        guard !isTerminating else { return }
        if isVisible {
            visibleSurfaces.insert(id)
        } else {
            visibleSurfaces.remove(id)
        }
        updateTimer()
    }

    func applicationDidBecomeActive() {
        applicationIsActive = true
    }

    func applicationWillResignActive() {
        applicationIsActive = false
    }

    func terminate() {
        isTerminating = true
        visibleSurfaces.removeAll()
        updateTimer()
    }

    private func updateTimer() {
        let shouldPoll = !isTerminating && !visibleSurfaces.isEmpty
        if shouldPoll, timer == nil {
            timer = scheduler.schedule(every: interval) { [weak self] in
                self?.refresh()
            }
        } else if !shouldPoll {
            timer?.invalidate()
            timer = nil
        }
    }
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

    /// Decides whether an in-app request should fall back to the Input
    /// Monitoring Settings pane after the permission status has been refreshed.
    static func shouldOpenInputMonitoringSettingsAfterRequest(
        for permission: MacKVMPermission,
        inputMonitoringGranted: Bool
    ) -> Bool {
        permission == .inputMonitoring && !inputMonitoringGranted
    }

    /// The Accessibility request may also need the separate Core Graphics
    /// event-posting grant. If the effective receiver gate is still closed,
    /// send the user to the privacy pane after the public request APIs return.
    static func shouldOpenAccessibilitySettingsAfterRequest(
        for permission: MacKVMPermission,
        accessibilityGranted: Bool
    ) -> Bool {
        permission == .accessibility && !accessibilityGranted
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
