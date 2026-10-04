import AppKit
import Combine
import Darwin
import Foundation
import IOKit.pwr_mgt
import MacKVMCore

/// A display returned by the native DDC/CI discovery layer.
///
/// The selector is an opaque, stable identifier made from EDID/CoreGraphics
/// display identity. Numeric display indexes are intentionally not accepted as
/// routing selectors because they can change when a display is reconnected.
struct DDCDisplay: Identifiable, Equatable {
    let index: Int
    let name: String
    let stableIdentifier: String?
    let vendorID: UInt32
    let productID: UInt32

    init(
        index: Int,
        name: String,
        stableIdentifier: String?,
        vendorID: UInt32 = 0,
        productID: UInt32 = 0
    ) {
        self.index = index
        self.name = name
        self.stableIdentifier = stableIdentifier
        self.vendorID = vendorID
        self.productID = productID
    }

    var id: String {
        stableIdentifier ?? "display-\(index)"
    }

    var selector: String {
        stableIdentifier ?? ""
    }

    var displayName: String {
        if let stableIdentifier {
            return "[\(index)] \(name) — \(stableIdentifier)"
        }
        return "[\(index)] \(name)"
    }

    var isDDCCapable: Bool {
        stableIdentifier != nil
    }

    func matches(selector: String) -> Bool {
        let normalizedSelector = selector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let stableIdentifier else { return false }
        return normalizedSelector.caseInsensitiveCompare(stableIdentifier)
            == .orderedSame
    }

}

enum AutomaticDDCSwitchDecision: Equatable {
    case switchNow
    case waitForVerification
    case useManualFallback
}

/// Inject only native DDC operations so route/discovery regression tests can
/// exercise the controller without sending commands to a physical monitor.
struct MonitorDDCOperations {
    var discover: () throws -> [DDCDisplay]
    var currentInputValue: (String) throws -> UInt32
    var switchInput: (String, MonitorInputSource, UInt32?, UInt32?) throws -> Void

    static let native = MonitorDDCOperations(
        discover: NativeDDCService.discover,
        currentInputValue: { try NativeDDCService.currentInputValue(displaySelector: $0) },
        switchInput: {
            try NativeDDCService.switchInput(
                displaySelector: $0,
                input: $1,
                vendorID: $2,
                productID: $3
            )
        }
    )
}

enum DisplayRouteRole: Equatable {
    case local
    case remote
    case unknown
}

struct DisplayRouteConfiguration: Equatable {
    let localInput: MonitorInputSource
    let remoteInput: MonitorInputSource
    let generation: UInt64
}

struct DisplayRouteSwitchRequest: Equatable {
    let role: DisplayRouteRole
    let selector: String
    let input: MonitorInputSource
    let configuration: DisplayRouteConfiguration
}

struct ConfirmedDisplayRoute: Equatable {
    let role: DisplayRouteRole
    let selector: String
    let input: MonitorInputSource?
    let configurationGeneration: UInt64
}

enum DisplayRouteConfirmationOutcome: Equatable {
    case confirmed
    case unknown
}

/// Tracks the last native route outcome without treating a process-local
/// selector cache as proof that the monitor is still physically present.
/// Input preferences are part of the request identity: changing either one
/// invalidates every in-flight completion from the previous configuration.
struct DisplayRouteState: Equatable {
    private(set) var configuration: DisplayRouteConfiguration
    private(set) var confirmedRoute: ConfirmedDisplayRoute?
    private(set) var pendingRequest: DisplayRouteSwitchRequest?

    init(
        localInput: MonitorInputSource = .usbC,
        remoteInput: MonitorInputSource = .hdmi1
    ) {
        configuration = DisplayRouteConfiguration(
            localInput: localInput,
            remoteInput: remoteInput,
            generation: 0
        )
        confirmedRoute = nil
        pendingRequest = nil
    }

    mutating func configurationDidChange(
        localInput: MonitorInputSource,
        remoteInput: MonitorInputSource
    ) {
        configuration = DisplayRouteConfiguration(
            localInput: localInput,
            remoteInput: remoteInput,
            generation: configuration.generation &+ 1
        )
        confirmedRoute = nil
        pendingRequest = nil
    }

    /// Invalidate the route for lifecycle or selector changes. Advancing the
    /// generation also makes a completion queued before the change stale even
    /// if the user later switches back to the same input values.
    mutating func invalidate() {
        configuration = DisplayRouteConfiguration(
            localInput: configuration.localInput,
            remoteInput: configuration.remoteInput,
            generation: configuration.generation &+ 1
        )
        confirmedRoute = nil
        pendingRequest = nil
    }

    /// Records the request identity before native DDC work is enqueued. A
    /// later local/remote request supersedes the previous one, even when both
    /// logical roles happen to use the same VCP value.
    @discardableResult
    mutating func enqueue(_ request: DisplayRouteSwitchRequest) -> Bool {
        guard request.configuration == configuration else { return false }
        switch request.role {
        case .local:
            guard request.input == configuration.localInput else {
                return false
            }
        case .remote:
            guard request.input == configuration.remoteInput else {
                return false
            }
        case .unknown:
            return false
        }
        pendingRequest = request
        return true
    }

    /// Applies only a current request. A selector comparison is intentionally
    /// case-insensitive because native display identity matching is too.
    @discardableResult
    mutating func apply(
        request: DisplayRouteSwitchRequest,
        outcome: DisplayRouteConfirmationOutcome,
        currentSelector: String
    ) -> Bool {
        let normalizedCurrentSelector = currentSelector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard request.configuration == configuration,
              request.selector.caseInsensitiveCompare(
                  normalizedCurrentSelector
              ) == .orderedSame,
              pendingRequest == request else {
            return false
        }
        switch request.role {
        case .local:
            guard request.input == configuration.localInput else {
                return false
            }
        case .remote:
            guard request.input == configuration.remoteInput else {
                return false
            }
        case .unknown:
            return false
        }

        switch outcome {
        case .confirmed:
            confirmedRoute = ConfirmedDisplayRoute(
                role: request.role,
                selector: request.selector,
                input: request.input,
                configurationGeneration: configuration.generation
            )
        case .unknown:
            confirmedRoute = ConfirmedDisplayRoute(
                role: .unknown,
                selector: request.selector,
                input: nil,
                configurationGeneration: configuration.generation
            )
        }
        if pendingRequest == request {
            pendingRequest = nil
        }
        return true
    }
}

private struct RoutePreservationAttempt {
    enum Status {
        case pending
        case selectorPreserved
    }

    let id: UUID
    let request: DisplayRouteSwitchRequest
    /// Keep the display identity alongside the selector. CoreGraphics can
    /// temporarily report no displays after an input switch, but the return
    /// route still needs the EDID model IDs for model-specific VCP values.
    var display: DDCDisplay?
    var deadline: Date
    var status: Status = .pending
    var topologyRefreshStarted = false
    var refreshAfterCurrentDiscovery = false

    var selector: String { request.selector }
}

/// Keeps the external display pipeline awake while automatic DDC/CI routing
/// is enabled. Intel framebuffers can suspend their I2C provider after the
/// normal display-idle deadline even though the Mac itself remains awake;
/// that makes a later VCP write fail until another app (for example
/// `caffeinate -d` or DeskIn) happens to hold the same power assertion.
///
/// The lease is deliberately owned by `MonitorController` and is toggled only
/// after a real native display selector has been verified. Disabling automatic
/// switching, forgetting the display, or terminating the app releases it so
/// the user's normal display-sleep policy is restored.
private final class DisplaySleepAssertionLease {
    private var assertionID: IOPMAssertionID?

    func setEnabled(_ enabled: Bool) {
        if enabled {
            enable()
        } else {
            disable()
        }
    }

    private func enable() {
        guard assertionID == nil else { return }

        var newAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacKVM automatic DDC/CI" as CFString,
            &newAssertionID
        )
        guard result == kIOReturnSuccess else {
            MacKVMLogger.monitor.error(
                "phase=display.sleep-lease.enable-failed return=\(result, privacy: .public)"
            )
            return
        }
        assertionID = newAssertionID
        MacKVMLogger.monitor.info(
            "phase=display.sleep-lease.enabled assertionID=\(newAssertionID, privacy: .public)"
        )
    }

    private func disable() {
        guard let assertionID else { return }
        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess {
            MacKVMLogger.monitor.info(
                "phase=display.sleep-lease.disabled assertionID=\(assertionID, privacy: .public)"
            )
        } else {
            MacKVMLogger.monitor.error(
                "phase=display.sleep-lease.disable-failed assertionID=\(assertionID, privacy: .public) return=\(result, privacy: .public)"
            )
        }
        self.assertionID = nil
    }

    deinit {
        disable()
    }
}

final class MonitorController: ObservableObject {
    @Published var automationEnabled: Bool {
        didSet {
            defaults.set(automationEnabled, forKey: Keys.automationEnabled)
            if oldValue != automationEnabled {
                invalidateDisplayRouteState()
            }
            scheduleDisplaySleepLease()
        }
    }
    @Published var localInput: MonitorInputSource {
        didSet {
            defaults.set(localInput.rawValue, forKey: Keys.localInput)
            if oldValue != localInput {
                invalidateDisplayRouteState(configurationChanged: true)
            }
            scheduleDisplaySleepLease()
        }
    }
    @Published var remoteInput: MonitorInputSource {
        didSet {
            defaults.set(remoteInput.rawValue, forKey: Keys.remoteInput)
            if oldValue != remoteInput {
                invalidateDisplayRouteState(configurationChanged: true)
            }
            scheduleDisplaySleepLease()
        }
    }
    @Published var displaySelector: String {
        didSet {
            defaults.set(displaySelector, forKey: Keys.displaySelector)
            if oldValue.caseInsensitiveCompare(displaySelector)
                    != .orderedSame {
                invalidateDisplayRouteState()
            }
            updateSelectorVerification()
            scheduleDisplaySleepLease()
        }
    }
    @Published private(set) var status = "Monitor switching is ready"
    @Published private(set) var detectedDisplays: [DDCDisplay] = []
    @Published private(set) var isDisplaySelectorVerified = false
    @Published private(set) var diagnostic: String?

    /// Native IOKit DDC/CI is available on both supported architectures.
    var supportsAutomaticDDCSwitching: Bool { true }

    private let defaults: UserDefaults
    private let ddcOperations: MonitorDDCOperations
    private let queue = DispatchQueue(label: "app.mackvm.monitor-control")
    private var displayConfigurationObserver: NSObjectProtocol?
    private var isDiscoveringDisplays = false
    private var hasCompletedDisplayDiscovery = false
    private var routePreservationAttempt: RoutePreservationAttempt?
    /// The most recent verified EDID metadata for the saved selector. This is
    /// intentionally independent of the short topology-refresh deadline: a
    /// control session can last longer than the time CoreGraphics needs to
    /// reconcile the input switch, and the return route still needs the
    /// model-specific VCP mapping.
    private var lastVerifiedDisplay: DDCDisplay?
    private var displayRouteState = DisplayRouteState()
    private var deferredAutomaticSwitchState = DeferredAutomaticSwitchState()
    /// IOPMAssertionDeclareUserActivity returns an expiring activity token.
    /// Reuse the latest token when rapid incoming switches report activity
    /// again, as required by the IOKit API contract.
    private var displayWakeActivityID = IOPMAssertionID(kIOPMNullAssertionID)
    private let displaySleepAssertionLease = DisplaySleepAssertionLease()
    private var displaySleepLeaseGraceWorkItem: DispatchWorkItem?

    init(
        defaults: UserDefaults = .standard,
        ddcOperations: MonitorDDCOperations = .native
    ) {
        self.defaults = defaults
        self.ddcOperations = ddcOperations
        automationEnabled = defaults.object(
            forKey: Keys.automationEnabled
        ) as? Bool ?? false
        let defaultsForArchitecture = Self.defaultInputPreferences(
            isAppleSilicon: Self.isAppleSilicon
        )
        localInput = Self.inputPreference(
            rawValue: defaults.integer(forKey: Keys.localInput),
            fallback: defaultsForArchitecture.local
        )
        remoteInput = Self.inputPreference(
            rawValue: defaults.integer(forKey: Keys.remoteInput),
            fallback: defaultsForArchitecture.remote
        )
        displaySelector = defaults.string(
            forKey: Keys.displaySelector
        ) ?? ""
        displayRouteState = DisplayRouteState(
            localInput: localInput,
            remoteInput: remoteInput
        )
        displayConfigurationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Switching the monitor's input can temporarily remove the
            // inactive input from CoreGraphics. Keep the last verified
            // selector usable for the return-to-local route while the
            // topology notification is being reconciled.
            self?.handleDisplayConfigurationChange()
        }
        scheduleDisplaySleepLease()
    }

    deinit {
        displaySleepLeaseGraceWorkItem?.cancel()
        if let displayConfigurationObserver {
            NotificationCenter.default.removeObserver(
                displayConfigurationObserver
            )
        }
    }

    func applyAppleSiliconUSBPreset() {
        localInput = .usbC
        remoteInput = .hdmi1
        automationEnabled = true
        status = "Preset: this Mac uses USB-C; the other device uses HDMI 1"
    }

    func applyIntelHDMIPreset() {
        localInput = .hdmi1
        remoteInput = .usbC
        automationEnabled = true
        status = "Preset: this Mac uses HDMI 1; native DDC/CI is enabled"
    }

    func refreshDetectedDisplays(
        preserveVerifiedSelector: Bool = false,
        preservationAttemptID: UUID? = nil
    ) {
        guard !isDiscoveringDisplays else { return }
        let selectorAtStart = displaySelector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let shouldPreserveSelector = preserveVerifiedSelector
            && preservationAttemptID != nil
            && routePreservationAttempt?.id == preservationAttemptID
            && routePreservationAttempt?.status == .selectorPreserved
            && routePreservationAttempt?.selector.caseInsensitiveCompare(
                selectorAtStart
            ) == .orderedSame
            && !selectorAtStart.isEmpty
        isDiscoveringDisplays = true
        hasCompletedDisplayDiscovery = false
        if !shouldPreserveSelector {
            detectedDisplays = []
            isDisplaySelectorVerified = false
        }
        status = "Detecting DDC-capable external displays…"
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let displays = try self.ddcOperations.discover()
                let message = displays.count == 1
                    ? "Detected 1 DDC-capable external display"
                    : "Detected \(displays.count) DDC-capable external displays"
                self.publishDiscovery(
                    displays: displays,
                    message: message,
                    diagnostic: nil,
                    preservationAttemptID: preservationAttemptID
                )
            } catch {
                self.publishDiscovery(
                    displays: [],
                    message: "No DDC-capable external display was detected; check the cable and DDC/CI setting",
                    diagnostic: Self.diagnostic(from: error),
                    preservationAttemptID: preservationAttemptID
                )
            }
        }
    }

    private func handleDisplayConfigurationChange() {
        let now = Date()
        if isDiscoveringDisplays,
           Self.shouldDeferRoutePreservationRefresh(
               isDiscoveringDisplays: true,
               attemptDeadline: routePreservationAttempt?.deadline,
               now: now
           ),
           var attempt = routePreservationAttempt {
            // The regular refresh is already in flight. Preserve the
            // topology notification on the active route attempt so the
            // current discovery publication can immediately start the
            // selector-preserving pass instead of dropping this event.
            attempt.topologyRefreshStarted = true
            attempt.refreshAfterCurrentDiscovery = true
            routePreservationAttempt = attempt
            return
        }
        let preservationAttemptID: UUID?
        if var attempt = routePreservationAttempt,
           attempt.deadline > now {
            attempt.topologyRefreshStarted = true
            routePreservationAttempt = attempt
            preservationAttemptID = attempt.id
        } else {
            routePreservationAttempt = nil
            preservationAttemptID = nil
        }
        // A single topology refresh belongs to the app-initiated route that
        // caused it. Later physical disconnects must perform normal
        // verification instead of retaining a stale selector indefinitely.
        refreshDetectedDisplays(
            preserveVerifiedSelector: false,
            preservationAttemptID: preservationAttemptID
        )
    }

    private func completeDisplayRouteSwitch(
        success: Bool,
        preserveSelectorForRecovery: Bool = false,
        request: DisplayRouteSwitchRequest,
        attemptID: UUID?,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            guard self.isCurrentRouteRequest(request),
                  attemptID == nil
                    || self.routePreservationAttempt?.id == attemptID else {
                MacKVMLogger.monitor.debug(
                    "phase=input.switch.completion-ignored stale=true"
                )
                completion(false)
                return
            }
            guard !self.deferredAutomaticSwitchState.isTerminating else {
                self.invalidateDisplayRouteState()
                self.scheduleDisplaySleepLease()
                completion(false)
                return
            }

            let applied = self.displayRouteState.apply(
                request: request,
                outcome: success ? .confirmed : .unknown,
                currentSelector: self.currentCanonicalSelector()
            )
            guard applied else {
                completion(false)
                return
            }

            guard let attemptID else {
                self.scheduleDisplaySleepLease()
                completion(true)
                return
            }
            guard var attempt = self.routePreservationAttempt,
                  attempt.id == attemptID else {
                completion(false)
                return
            }
            guard success || preserveSelectorForRecovery else {
                // A topology refresh may still be in flight, but it carries
                // this attempt ID and will now fail its success gate below.
                self.routePreservationAttempt = nil
                self.scheduleDisplaySleepLease()
                completion(true)
                return
            }
            attempt.status = .selectorPreserved
            // If no topology notification follows the DDC write, do not let
            // an unrelated unplug much later consume the preservation state.
            attempt.deadline = Date().addingTimeInterval(2)
            if attempt.topologyRefreshStarted && self.isDiscoveringDisplays {
                attempt.refreshAfterCurrentDiscovery = true
                self.routePreservationAttempt = attempt
                self.scheduleDisplaySleepLease()
                completion(true)
                return
            }
            self.routePreservationAttempt = attempt
            if attempt.topologyRefreshStarted {
                self.refreshDetectedDisplays(
                    preserveVerifiedSelector: true,
                    preservationAttemptID: attempt.id
                )
            }
            self.scheduleDisplaySleepLease()
            completion(true)
        }
    }

    /// Latches the app's final local-route intent and returns completions for
    /// cancelled normal routes. The caller must first mark any receiver-side
    /// input teardown as quitting, then invoke the returned completions. This
    /// prevents a cancelled monitor route from making that teardown look idle
    /// before it can suppress a second input release.
    func beginTermination() -> [() -> Void] {
        let callbacks = deferredAutomaticSwitchState.beginTermination()
        invalidateDisplayRouteState()
        scheduleDisplaySleepLease()
        return callbacks
    }

    func selectDisplay(_ display: DDCDisplay) {
        displaySelector = display.selector
        guard display.isDDCCapable else {
            status = "\(display.name) has no native DDC/CI selector; automatic switching remains blocked"
            return
        }
        lastVerifiedDisplay = display
        scheduleDisplaySleepLease()
        status = "Selected \(display.name) for native DDC/CI switching"
    }

    func switchToLocal(
        wakeDisplayForKVMSwitch: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        switchInput(
            localInput,
            description: "this Mac",
            role: .local,
            intent: .normal,
            completion: completion,
            shouldWakeDisplayForKVMSwitch: wakeDisplayForKVMSwitch
        )
    }

    func switchToLocalForTermination(completion: @escaping () -> Void) {
        switchInput(
            localInput,
            description: "this Mac",
            role: .local,
            intent: .terminating,
            completion: completion,
            shouldWakeDisplayForKVMSwitch: true
        )
    }

    func switchToRemote(
        wakeDisplayForKVMSwitch: Bool = true,
        completion: (() -> Void)? = nil
    ) {
        switchInput(
            remoteInput,
            description: "the other device",
            role: .remote,
            intent: .normal,
            completion: completion,
            shouldWakeDisplayForKVMSwitch: wakeDisplayForKVMSwitch
        )
    }

    /// Whether a display-first control request can route the monitor
    /// immediately or wait for the current verification pass. Callers that
    /// will suppress local input must not treat a manual-fallback route as a
    /// successful hand-off, but a saved selector may safely queue the request
    /// while discovery is in flight.
    func canStartAutomaticRemoteSwitching() -> Bool {
        guard automationEnabled else { return false }
        return Self.automaticSwitchDecision(
            displaySelector: displaySelector,
            isDisplaySelectorVerified: isDisplaySelectorVerified,
            hasCompletedDisplayDiscovery: hasCompletedDisplayDiscovery
        ) != .useManualFallback
    }

    /// Runs the remote display route and reports whether native DDC actually
    /// succeeded. This is intentionally separate from `switchToRemote`, whose
    /// completion means that the route has resolved (including manual
    /// fallback or a DDC error). Callers that will forward input must use this
    /// result so they never start control while the local Mac is still on
    /// screen.
    func switchToRemoteAndReportSuccess(
        completion: @escaping (Bool) -> Void
    ) {
        guard automationEnabled,
              Self.automaticSwitchDecision(
                  displaySelector: displaySelector,
                  isDisplaySelectorVerified: isDisplaySelectorVerified,
                  hasCompletedDisplayDiscovery: hasCompletedDisplayDiscovery
              ) != .useManualFallback else {
            if automationEnabled {
                invalidateDisplayRouteState()
                scheduleDisplaySleepLease()
            }
            completion(false)
            return
        }
        switchInput(
            remoteInput,
            description: "the other device",
            role: .remote,
            intent: .normal,
            completion: nil,
            result: completion,
            recoveryInputOnFailure: localInput,
            shouldWakeDisplayForKVMSwitch: true
        )
    }

    private func switchInput(
        _ input: MonitorInputSource,
        description: String,
        role: DisplayRouteRole,
        intent: DeferredAutomaticSwitchIntent,
        completion: (() -> Void)?,
        result: ((Bool) -> Void)? = nil,
        recoveryInputOnFailure: MonitorInputSource? = nil,
        shouldWakeDisplayForKVMSwitch: Bool = true,
        requestSnapshot: DisplayRouteSwitchRequest? = nil
    ) {
        let reportResult: (Bool) -> Void = { success in
            guard let result else { return }
            DispatchQueue.main.async {
                result(success)
            }
        }
        guard intent == .terminating
                || !deferredAutomaticSwitchState.isTerminating else {
            completion?()
            reportResult(false)
            return
        }
        guard automationEnabled else {
            status = "Use the monitor OSD to select \(input.name) for \(description)"
            completion?()
            reportResult(false)
            return
        }
        let selector = displaySelector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let currentlyDetectedDisplay = detectedDisplays.first {
            $0.matches(selector: selector)
        }
        let resolvedRouteDisplay = currentlyDetectedDisplay
            ?? lastVerifiedDisplay.flatMap {
                $0.matches(selector: selector) ? $0 : nil
            }
        let routeRequest = requestSnapshot ?? DisplayRouteSwitchRequest(
            role: role,
            selector: resolvedRouteDisplay?.selector ?? selector,
            input: input,
            configuration: displayRouteState.configuration
        )
        guard isCurrentRouteRequest(routeRequest) else {
            completion?()
            reportResult(false)
            return
        }
        var routePreservationAttemptID: UUID?
        switch Self.automaticSwitchDecision(
            displaySelector: selector,
            isDisplaySelectorVerified: isDisplaySelectorVerified,
            hasCompletedDisplayDiscovery: hasCompletedDisplayDiscovery,
            role: role,
            cachedDisplay: lastVerifiedDisplay
        ) {
        case .switchNow:
            guard displayRouteState.enqueue(routeRequest) else {
                completion?()
                reportResult(false)
                return
            }
            // The monitor may briefly disappear from CoreGraphics while the
            // DDC input change is applied. Allow exactly the next topology
            // refresh (within a short bounded window) to retain the verified
            // selector needed for the return route.
            let attemptID = UUID()
            routePreservationAttemptID = attemptID
            let previousDisplay = routePreservationAttempt?.display
                ?? lastVerifiedDisplay.flatMap {
                    $0.matches(selector: selector) ? $0 : nil
                }
            routePreservationAttempt = RoutePreservationAttempt(
                id: attemptID,
                request: routeRequest,
                display: currentlyDetectedDisplay ?? previousDisplay,
                deadline: Date().addingTimeInterval(10)
            )
            scheduleDisplaySleepLease()
            break
        case .waitForVerification:
            guard displayRouteState.enqueue(routeRequest) else {
                completion?()
                reportResult(false)
                return
            }
            let cancelledCompletions = deferredAutomaticSwitchState.deferSwitch(
                input: input,
                description: description,
                intent: intent,
                completion: completion,
                result: result,
                recoveryInputOnFailure: recoveryInputOnFailure,
                shouldWakeDisplayForKVMSwitch: shouldWakeDisplayForKVMSwitch,
                role: role,
                routeRequest: routeRequest
            )
            cancelledCompletions.forEach { $0() }
            status = "Verifying the saved DDC display before switching…"
            if !isDiscoveringDisplays {
                refreshDetectedDisplays()
            }
            return
        case .useManualFallback:
            invalidateDisplayRouteState()
            scheduleDisplaySleepLease()
            status = selector.isEmpty
                ? "Detect and select a DDC-capable display before automatic switching"
                : "The selected DDC display is not currently available; detect it again"
            completion?()
            reportResult(false)
            return
        }

        let routeDisplay = routePreservationAttempt?.display
            ?? resolvedRouteDisplay
        let displayName = routeDisplay?.name ?? "display"
        // Use the canonical selector returned by discovery. This keeps the
        // editable field case-insensitive without passing a user-edited
        // spelling to the native C bridge.
        let nativeSelector = routeDisplay?.selector ?? routeRequest.selector
        let selectorIdentity = MonitorInputMapping.displayIdentity(
            fromNativeSelector: nativeSelector
        )
        let displayVendorID = routeDisplay.flatMap {
            $0.vendorID > 0 ? $0.vendorID : nil
        }
        let displayProductID = routeDisplay.flatMap {
            $0.productID > 0 ? $0.productID : nil
        }
        let effectiveVendorID = displayVendorID ?? selectorIdentity?.vendorID
        let effectiveProductID = displayProductID ?? selectorIdentity?.productID
        let mappingSource = displayVendorID != nil && displayProductID != nil
            ? "display"
            : selectorIdentity == nil ? "none" : "selector"
        let mappedInputValue = MonitorInputMapping.rawValue(
            for: input,
            vendorID: effectiveVendorID,
            productID: effectiveProductID,
            nativeSelector: nativeSelector
        )
        status = "Switching \(displayName) to \(input.name)…"
        MacKVMLogger.monitor.info(
            "phase=input.switch.requested input=\(input.rawValue, privacy: .public) vcpValue=\(mappedInputValue, privacy: .public) mapping=\(mappingSource, privacy: .public) selector=\(nativeSelector, privacy: .public) description=\(description, privacy: .public) wakeDisplay=\(shouldWakeDisplayForKVMSwitch, privacy: .public)"
        )
        queue.async { [weak self] in
            guard let self else { return }
            // A short assertion mirrors `caffeinate -d` for the duration of
            // this DDC transaction. It is deliberately released in `defer`
            // so a failed read/write cannot leave a permanent power assertion
            // behind. The user-activity call below additionally wakes a
            // display that has already entered its idle state.
            let displaySleepAssertionID = shouldWakeDisplayForKVMSwitch
                ? self.beginPreventingDisplaySleep()
                : nil
            defer {
                if let displaySleepAssertionID {
                    self.endPreventingDisplaySleep(displaySleepAssertionID)
                }
            }
            if shouldWakeDisplayForKVMSwitch {
                self.wakeDisplayForKVMSwitch()
                self.waitForDisplayWake()
            }
            do {
                // Read VCP 0x60 first so a route restore does not write the
                // same value again and make the MA270U visibly re-negotiate
                // its input. If Get-VCP is unavailable, the write path is
                // attempted, but the route is not reported as ready for
                // keyboard hand-off unless the monitor can confirm the value.
                let readValue: UInt32?
                do {
                    readValue = try self.ddcOperations.currentInputValue(nativeSelector)
                } catch {
                    readValue = nil
                    MacKVMLogger.monitor.debug(
                        "phase=input.read.failed selector=\(nativeSelector, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                }
                let alreadySelected: Bool
                let decisionSource: String
                if let readValue {
                    alreadySelected = MonitorInputMapping.isInputSelected(
                        currentValue: UInt16(truncatingIfNeeded: readValue),
                        input: input,
                        vendorID: effectiveVendorID,
                        productID: effectiveProductID,
                        nativeSelector: nativeSelector
                    )
                    decisionSource = "readback"
                } else {
                    // A failed read is not evidence that the requested input
                    // is still active. The other device (or the monitor OSD) may
                    // have changed the route since this process last wrote it,
                    // so preserve the safe write fallback instead of trusting
                    // a stale process-local cache.
                    alreadySelected = false
                    decisionSource = "write-fallback"
                }
                if !alreadySelected {
                    MacKVMLogger.monitor.info(
                        "phase=input.write selector=\(nativeSelector, privacy: .public) input=\(input.rawValue, privacy: .public) source=\(decisionSource, privacy: .public)"
                    )
                    try self.writeInputWithRetry(
                        displaySelector: nativeSelector,
                        input: input,
                        vendorID: effectiveVendorID,
                        productID: effectiveProductID,
                        shouldWakeDisplayForKVMSwitch:
                            shouldWakeDisplayForKVMSwitch
                    )
                    try self.verifyInputSelection(
                        displaySelector: nativeSelector,
                        input: input,
                        vendorID: effectiveVendorID,
                        productID: effectiveProductID
                    )
                } else {
                    MacKVMLogger.monitor.info(
                        "phase=input.noop selector=\(nativeSelector, privacy: .public) input=\(input.rawValue, privacy: .public) source=\(decisionSource, privacy: .public)"
                    )
                }
                self.completeDisplayRouteSwitch(
                    success: true,
                    request: routeRequest,
                    attemptID: routePreservationAttemptID
                ) { accepted in
                    guard accepted else {
                        MacKVMLogger.monitor.error(
                            "phase=input.switch.completed success=false stale=true input=\(input.rawValue, privacy: .public) description=\(description, privacy: .public)"
                        )
                        self.publish(
                            "The DDC/CI result was ignored because the monitor configuration changed",
                            completion: completion
                        )
                        reportResult(false)
                        return
                    }
                    let action = alreadySelected
                        ? "is already showing" : "switched to"
                    MacKVMLogger.monitor.info(
                        "phase=input.switch.completed success=true input=\(input.rawValue, privacy: .public) description=\(description, privacy: .public)"
                    )
                    self.publish(
                        "\(displayName) \(action) \(input.name) for \(description)",
                        completion: completion
                    )
                    reportResult(true)
                }
            } catch {
                var recoveryCommandSent = false
                if let recoveryInputOnFailure {
                    do {
                        try self.writeInputWithRetry(
                            displaySelector: nativeSelector,
                            input: recoveryInputOnFailure,
                            vendorID: effectiveVendorID,
                            productID: effectiveProductID,
                            shouldWakeDisplayForKVMSwitch:
                                shouldWakeDisplayForKVMSwitch
                        )
                        recoveryCommandSent = true
                        MacKVMLogger.monitor.info(
                            "phase=input.recovery-command.sent input=\(recoveryInputOnFailure.rawValue, privacy: .public)"
                        )
                    } catch {
                        MacKVMLogger.monitor.error(
                            "phase=input.recovery-command.failed input=\(recoveryInputOnFailure.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
                self.completeDisplayRouteSwitch(
                    success: false,
                    preserveSelectorForRecovery:
                        recoveryInputOnFailure != nil,
                    request: routeRequest,
                    attemptID: routePreservationAttemptID
                ) { _ in
                    MacKVMLogger.monitor.error(
                        "phase=input.switch.completed success=false input=\(input.rawValue, privacy: .public) description=\(description, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    self.publish(
                        recoveryCommandSent
                            ? "DDC/CI could not confirm the switch; a command to restore \(recoveryInputOnFailure?.name ?? "this Mac") was sent"
                            : "Native DDC/CI switch failed; use the monitor OSD to select \(recoveryInputOnFailure?.name ?? input.name)",
                        diagnostic: Self.diagnostic(from: error),
                        completion: completion
                    )
                    reportResult(false)
                }
            }
        }
    }

    /// Reports local user activity immediately before an incoming KVM route
    /// is written to the monitor. macOS documents this API as waking a
    /// powered-down display and postponing display sleep only until the
    /// user's normal display-sleep deadline; it is not a permanent
    /// PreventUserIdleDisplaySleep assertion and needs no root privilege.
    ///
    /// This runs on `queue`, not the main thread, because the IOKit call is an
    /// IPC operation. The returned activity ID is reused for rapid switches;
    /// the system owns its expiry according to the user activity timer.
    private func wakeDisplayForKVMSwitch() {
        MacKVMLogger.monitor.info("phase=display.wake.requested")
        let result = IOPMAssertionDeclareUserActivity(
            "MacKVM Switch" as CFString,
            kIOPMUserActiveLocal,
            &displayWakeActivityID
        )
        guard result == kIOReturnSuccess else {
            displayWakeActivityID = IOPMAssertionID(kIOPMNullAssertionID)
            MacKVMLogger.monitor.error(
                "phase=display.wake.failed return=\(result, privacy: .public)"
            )
            return
        }
        MacKVMLogger.monitor.info(
            "phase=display.wake.succeeded activityID=\(self.displayWakeActivityID, privacy: .public)"
        )
    }

    /// The display power assertion is asynchronous from the framebuffer's
    /// point of view. Give WindowServer and the Intel I2C provider a short,
    /// bounded settle window before the first transaction; this is the part
    /// that a manually running `caffeinate -d` supplies in practice.
    private func waitForDisplayWake() {
        let settleInterval: TimeInterval = 0.15
        MacKVMLogger.monitor.debug(
            "phase=display.wake.settling durationMs=\(Int(settleInterval * 1000), privacy: .public)"
        )
        Thread.sleep(forTimeInterval: settleInterval)
    }

    /// Retries one idempotent Set-VCP operation after re-announcing activity.
    /// Intel framebuffers can report a transient no-device result while their
    /// external output is being resumed. A retry is intentionally limited to
    /// one attempt and remains inside the bounded display-sleep assertion.
    private func writeInputWithRetry(
        displaySelector: String,
        input: MonitorInputSource,
        vendorID: UInt32?,
        productID: UInt32?,
        shouldWakeDisplayForKVMSwitch: Bool
    ) throws {
        do {
            try ddcOperations.switchInput(displaySelector, input, vendorID, productID)
        } catch {
            guard shouldWakeDisplayForKVMSwitch else { throw error }
            MacKVMLogger.monitor.info(
                "phase=input.write.retry selector=\(displaySelector, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            wakeDisplayForKVMSwitch()
            waitForDisplayWake()
            try ddcOperations.switchInput(displaySelector, input, vendorID, productID)
        }
    }

    /// A successful Set-VCP call only confirms that the transport accepted the
    /// packet. Confirm the monitor's actual VCP 0x60 value before a guarded
    /// keyboard hand-off is allowed to proceed. Some monitors briefly stop
    /// answering while they switch inputs, so the readback is bounded and
    /// retried rather than treated as an immediate failure.
    private func verifyInputSelection(
        displaySelector: String,
        input: MonitorInputSource,
        vendorID: UInt32?,
        productID: UInt32?
    ) throws {
        let expected = MonitorInputMapping.rawValue(
            for: input,
            vendorID: vendorID,
            productID: productID,
            nativeSelector: displaySelector
        )
        let attempts = 6
        var lastValue: UInt32?
        var lastError: String?

        for attempt in 1...attempts {
            // Give the display time to apply the route before asking for its
            // current input. The first delay is also useful for monitors that
            // synchronously acknowledge Set-VCP before switching their mux.
            Thread.sleep(forTimeInterval: 0.2)
            do {
                let current = try ddcOperations.currentInputValue(displaySelector)
                lastValue = current
                lastError = nil
                MacKVMLogger.monitor.info(
                    "phase=input.verify attempt=\(attempt, privacy: .public) current=\(current, privacy: .public) expected=\(expected, privacy: .public)"
                )
                if current == expected {
                    return
                }
            } catch {
                lastError = error.localizedDescription
                MacKVMLogger.monitor.debug(
                    "phase=input.verify.read-failed attempt=\(attempt, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        if let lastValue {
            throw NativeDDCServiceError(
                message: "The monitor did not confirm the requested input (VCP 0x60 read back \(lastValue); expected \(expected))"
            )
        }
        throw NativeDDCServiceError(
            message: "The monitor accepted the input command, but VCP 0x60 could not be read back after \(attempts) attempts: \(lastError ?? "unknown readback error")"
        )
    }

    /// Keeps the external display pipeline awake while a native DDC request
    /// is in flight. This is intentionally scoped to one read/write operation
    /// rather than held for the lifetime of the app, so MacKVM does not change
    /// the user's normal display-sleep policy. It is the programmatic
    /// equivalent of running `caffeinate -d` just long enough to route input.
    private func beginPreventingDisplaySleep() -> IOPMAssertionID? {
        var assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "MacKVM DDC switch" as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            MacKVMLogger.monitor.error(
                "phase=display.sleep-assertion.failed return=\(result, privacy: .public)"
            )
            return nil
        }
        MacKVMLogger.monitor.debug(
            "phase=display.sleep-assertion.created assertionID=\(assertionID, privacy: .public)"
        )
        return assertionID
    }

    private func endPreventingDisplaySleep(_ assertionID: IOPMAssertionID) {
        let result = IOPMAssertionRelease(assertionID)
        if result == kIOReturnSuccess {
            MacKVMLogger.monitor.debug(
                "phase=display.sleep-assertion.released assertionID=\(assertionID, privacy: .public)"
            )
        } else {
            MacKVMLogger.monitor.error(
                "phase=display.sleep-assertion.release-failed assertionID=\(assertionID, privacy: .public) return=\(result, privacy: .public)"
            )
        }
    }

    private func publish(
        _ message: String,
        diagnostic: String? = nil,
        completion: (() -> Void)? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.status = message
            self?.diagnostic = diagnostic
            completion?()
        }
    }

    private func publishDiscovery(
        displays: [DDCDisplay],
        message: String,
        diagnostic: String?,
        preservationAttemptID: UUID?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isDiscoveringDisplays = false
            hasCompletedDisplayDiscovery = true
            detectedDisplays = displays
            if let verifiedDisplay = displays.first(where: {
                $0.matches(selector: self.displaySelector)
            }) {
                lastVerifiedDisplay = verifiedDisplay
            }
            if let selector = Self.automaticSelector(
                for: displays,
                existingSelector: displaySelector
            ) {
                // A single native DDC display is unambiguous. Select it as
                // soon as discovery completes so the first-run "Show this
                // Mac" and "Show other device" buttons work without requiring
                // the user to guess that the display row is also a picker.
                displaySelector = selector
                lastVerifiedDisplay = displays.first {
                    $0.matches(selector: selector)
                }
            }
            self.diagnostic = diagnostic
            // Cached EDID metadata permits a native local-return attempt,
            // not proof of presence or permission for a fresh remote route.
            // Keep discovery verification truthful even inside switch grace.
            updateSelectorVerification()
            self.scheduleDisplaySleepLease()

            // Legacy m1ddc selectors were numeric indexes. Native CoreGraphics
            // and IOKit enumeration order is not guaranteed to match that
            // tool, so never migrate a number implicitly: the user must pick
            // the intended display from the verified native list.
            status = message
            resumeDeferredAutomaticSwitch()

            // A topology notification can arrive while an unrelated menu
            // discovery is already running. In that case the notification's
            // refresh call intentionally returned early, so the active
            // attempt has to request its preserving refresh after *any*
            // discovery completes, not only after a publication carrying the
            // notification's optional ID.
            if var attempt = routePreservationAttempt,
               attempt.refreshAfterCurrentDiscovery,
               attempt.deadline > Date() {
                attempt.refreshAfterCurrentDiscovery = false
                routePreservationAttempt = attempt
                refreshDetectedDisplays(
                    preserveVerifiedSelector: true,
                    preservationAttemptID: attempt.id
                )
            } else if let preservationAttemptID,
                      var attempt = routePreservationAttempt,
                      attempt.id == preservationAttemptID,
                      attempt.refreshAfterCurrentDiscovery {
                // Expired attempts are normally discarded by the topology
                // handler, but keep this defensive branch for a completion
                // already queued before the deadline elapsed.
                attempt.refreshAfterCurrentDiscovery = false
                routePreservationAttempt = attempt
            }
        }
    }

    private func resumeDeferredAutomaticSwitch() {
        guard let deferredAutomaticSwitch =
            deferredAutomaticSwitchState.takeDeferredSwitch() else {
            return
        }
        let resumedRequest = deferredAutomaticSwitch.routeRequest.map {
            DisplayRouteSwitchRequest(
                role: $0.role,
                selector: currentCanonicalSelector(),
                input: $0.input,
                configuration: $0.configuration
            )
        }
        switchInput(
            deferredAutomaticSwitch.input,
            description: deferredAutomaticSwitch.description,
            role: deferredAutomaticSwitch.role,
            intent: deferredAutomaticSwitch.intent,
            completion: deferredAutomaticSwitch.completeCompletions,
            result: deferredAutomaticSwitch.result,
            recoveryInputOnFailure:
                deferredAutomaticSwitch.recoveryInputOnFailure,
            shouldWakeDisplayForKVMSwitch:
                deferredAutomaticSwitch.shouldWakeDisplayForKVMSwitch,
            requestSnapshot: resumedRequest
        )
    }

    private func updateSelectorVerification() {
        let selector = displaySelector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        isDisplaySelectorVerified = !selector.isEmpty
            && detectedDisplays.contains {
                $0.matches(selector: selector) && $0.isDDCCapable
            }
    }

    private func currentCanonicalSelector() -> String {
        let selector = displaySelector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let detectedDisplay = detectedDisplays.first(where: {
            $0.matches(selector: selector)
        }) {
            return detectedDisplay.selector
        }
        if let cachedDisplay = lastVerifiedDisplay,
           cachedDisplay.matches(selector: selector) {
            return cachedDisplay.selector
        }
        return selector
    }

    private func isCurrentRouteRequest(
        _ request: DisplayRouteSwitchRequest
    ) -> Bool {
        guard request.configuration == displayRouteState.configuration,
              request.selector.caseInsensitiveCompare(
                  currentCanonicalSelector()
              ) == .orderedSame else {
            return false
        }
        switch request.role {
        case .local:
            return request.input == localInput
        case .remote:
            return request.input == remoteInput
        case .unknown:
            return false
        }
    }

    private func invalidateDisplayRouteState(
        configurationChanged: Bool = false
    ) {
        if configurationChanged {
            displayRouteState.configurationDidChange(
                localInput: localInput,
                remoteInput: remoteInput
            )
        } else {
            displayRouteState.invalidate()
        }
        routePreservationAttempt = nil
    }

    static func shouldKeepDisplayAwake(
        automationEnabled: Bool,
        displaySelector: String,
        detectedDisplays: [DDCDisplay],
        confirmedRoute: ConfirmedDisplayRoute?,
        configurationGeneration: UInt64,
        transitionGraceActive: Bool
    ) -> Bool {
        let selector = displaySelector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard automationEnabled,
              hasStableDisplaySelector(selector) else {
            return false
        }

        // The discovery list is the only physical-presence signal used by
        // the persistent lease. `isDisplaySelectorVerified` may intentionally
        // stay true during the short input-switch reconciliation window.
        if detectedDisplays.contains(where: {
            $0.isDDCCapable && $0.matches(selector: selector)
        }) {
            return true
        }

        guard let confirmedRoute,
              confirmedRoute.configurationGeneration == configurationGeneration,
              confirmedRoute.selector.caseInsensitiveCompare(selector)
                  == .orderedSame else {
            return transitionGraceActive
        }
        switch confirmedRoute.role {
        case .remote:
            // CoreGraphics can omit the inactive monitor input while the
            // remote route is active. A VCP-confirmed remote route is the
            // bounded-cache exception needed for Intel between-switch use.
            return true
        case .local, .unknown:
            return transitionGraceActive
        }
    }

    /// Schedules the persistent display-sleep lease on the same serial queue
    /// as native DDC transactions. This keeps assertion creation/release
    /// ordered with a switch and avoids touching IOPM from SwiftUI callbacks.
    private func scheduleDisplaySleepLease() {
        displaySleepLeaseGraceWorkItem?.cancel()
        displaySleepLeaseGraceWorkItem = nil
        let selector = displaySelector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let now = Date()
        let transitionGraceDeadline = routePreservationAttempt?.deadline
        let transitionGraceActive = transitionGraceDeadline.map {
            $0 > now
        } ?? false
        let isTerminating = deferredAutomaticSwitchState.isTerminating
        let shouldKeepDisplayAwake = Self.shouldKeepDisplayAwake(
            automationEnabled: automationEnabled && !isTerminating,
            displaySelector: selector,
            detectedDisplays: detectedDisplays,
            confirmedRoute: displayRouteState.confirmedRoute,
            configurationGeneration: displayRouteState.configuration.generation,
            transitionGraceActive: !isTerminating && transitionGraceActive
        )
        queue.async { [weak self] in
            self?.displaySleepAssertionLease.setEnabled(shouldKeepDisplayAwake)
        }
        guard !isTerminating,
              let transitionGraceDeadline,
              transitionGraceActive else {
            return
        }
        let delay = max(0, transitionGraceDeadline.timeIntervalSinceNow)
        let attemptID = routePreservationAttempt?.id
        let configurationGeneration = displayRouteState.configuration.generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.routePreservationAttempt?.id == attemptID,
                  self.routePreservationAttempt?.deadline
                      == transitionGraceDeadline,
                  self.displayRouteState.configuration.generation
                      == configurationGeneration else {
                return
            }
            self.displaySleepLeaseGraceWorkItem = nil
            self.scheduleDisplaySleepLease()
        }
        displaySleepLeaseGraceWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    static func canUseAutomaticDDCSwitching(
        displaySelector: String,
        isDisplaySelectorVerified: Bool
    ) -> Bool {
        hasStableDisplaySelector(displaySelector) && isDisplaySelectorVerified
    }

    static func shouldDeferRoutePreservationRefresh(
        isDiscoveringDisplays: Bool,
        attemptDeadline: Date?,
        now: Date
    ) -> Bool {
        guard isDiscoveringDisplays, let attemptDeadline else { return false }
        return attemptDeadline > now
    }

    static func automaticSwitchDecision(
        displaySelector: String,
        isDisplaySelectorVerified: Bool,
        hasCompletedDisplayDiscovery: Bool,
        role: DisplayRouteRole = .remote,
        cachedDisplay: DDCDisplay? = nil
    ) -> AutomaticDDCSwitchDecision {
        let selector = displaySelector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !selector.isEmpty else {
            return .useManualFallback
        }
        guard hasStableDisplaySelector(selector) else {
            return hasCompletedDisplayDiscovery
                ? .useManualFallback : .waitForVerification
        }
        if isDisplaySelectorVerified {
            return .switchNow
        }
        // CoreGraphics can omit the inactive input for an entire remote
        // session. Returning locally may use the matching previously verified
        // native identity: IOKit re-resolves it and still fails closed when
        // disconnected. A cache never authorizes switching away from local.
        if role == .local,
           let cachedDisplay,
           cachedDisplay.isDDCCapable,
           cachedDisplay.matches(selector: selector) {
            return .switchNow
        }
        return hasCompletedDisplayDiscovery
            ? .useManualFallback : .waitForVerification
    }

    private static func hasStableDisplaySelector(_ displaySelector: String) -> Bool {
        let selector = displaySelector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let prefix = "native-ddc:"
        return selector.count >= prefix.count
            && selector.prefix(prefix.count)
                .caseInsensitiveCompare(prefix) == .orderedSame
            && selector.count <= 255
            && Int(selector) == nil
    }

    /// Returns the only safe implicit selection: exactly one native DDC
    /// display, with no saved selector. Multiple displays and stale saved
    /// selectors remain explicit choices so a route can never be sent to an
    /// unintended monitor.
    static func automaticSelector(
        for displays: [DDCDisplay],
        existingSelector: String
    ) -> String? {
        guard existingSelector.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return nil
        }
        let candidates = displays.filter { $0.isDDCCapable }
        guard candidates.count == 1 else { return nil }
        return candidates[0].selector
    }

    private static func diagnostic(from error: Error) -> String {
        String(error.localizedDescription.prefix(600))
    }

    private static func inputPreference(
        rawValue: Int,
        fallback: MonitorInputSource
    ) -> MonitorInputSource {
        // Builds before the model-specific mapping stored MA270U USB-C as
        // 19. Treat that value as the logical USB-C preference so upgrading
        // does not silently turn it into an invalid/default input.
        if rawValue == 19 {
            return .usbC
        }
        return MonitorInputSource(rawValue: rawValue) ?? fallback
    }

    /// The first-run route must match the physical port used by the build's
    /// host. Previously both architectures defaulted to USB-C, so an Intel
    /// installation could route the local action to the M5 Pro input until
    /// the user manually selected the Intel preset.
    static func defaultInputPreferences(
        isAppleSilicon: Bool
    ) -> (local: MonitorInputSource, remote: MonitorInputSource) {
        isAppleSilicon
            ? (local: .usbC, remote: .hdmi1)
            : (local: .hdmi1, remote: .usbC)
    }

    private static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        // A universal bundle can be launched through Rosetta on Apple
        // Silicon. In that case the process architecture is x86_64 even
        // though the physical Mac still uses the USB-C local route. Query
        // the hardware capability rather than relying on the compile-time
        // process architecture.
        var arm64Capability: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname(
            "hw.optional.arm64",
            &arm64Capability,
            &size,
            nil,
            0
        )
        return result == 0 && arm64Capability == 1
        #endif
    }

    private enum Keys {
        static let automationEnabled = "MacKVM.monitor.automationEnabled"
        static let localInput = "MacKVM.monitor.localInput"
        static let remoteInput = "MacKVM.monitor.remoteInput"
        static let displaySelector = "MacKVM.monitor.displaySelector"
    }
}

enum DeferredAutomaticSwitchIntent: Equatable {
    case normal
    case terminating
}

struct DeferredAutomaticSwitch {
    let input: MonitorInputSource
    let description: String
    let intent: DeferredAutomaticSwitchIntent
    let role: DisplayRouteRole
    let routeRequest: DisplayRouteSwitchRequest?
    let shouldWakeDisplayForKVMSwitch: Bool
    let recoveryInputOnFailure: MonitorInputSource?
    let completions: [() -> Void]
    let result: ((Bool) -> Void)?

    init(
        input: MonitorInputSource,
        description: String,
        intent: DeferredAutomaticSwitchIntent,
        completion: (() -> Void)?,
        result: ((Bool) -> Void)?,
        recoveryInputOnFailure: MonitorInputSource? = nil,
        shouldWakeDisplayForKVMSwitch: Bool = true,
        role: DisplayRouteRole = .unknown,
        routeRequest: DisplayRouteSwitchRequest? = nil
    ) {
        self.input = input
        self.description = description
        self.intent = intent
        self.role = role
        self.routeRequest = routeRequest
        self.shouldWakeDisplayForKVMSwitch = shouldWakeDisplayForKVMSwitch
        self.recoveryInputOnFailure = recoveryInputOnFailure
        completions = completion.map { [$0] } ?? []
        self.result = result
    }

    func complete(success: Bool = true) {
        completeCompletions()
        result?(success)
    }

    /// Completes the ordinary route callback without resolving a result
    /// callback that is being passed separately to `switchInput`. This keeps
    /// a deferred display-first request from reporting success before native
    /// DDC has actually completed.
    func completeCompletions() {
        completions.forEach { $0() }
    }

    func resolveCallbacks(success: Bool) -> [() -> Void] {
        guard !completions.isEmpty || result != nil else { return [] }
        return [{ complete(success: success) }]
    }
}

struct DeferredAutomaticSwitchState {
    private(set) var isTerminating = false
    private var deferredAutomaticSwitch: DeferredAutomaticSwitch?

    /// Cancels a normal deferred route before the terminating local route is
    /// queued. Its completion means the request has resolved, not that DDC
    /// succeeded, so it must still run when the route is superseded.
    mutating func beginTermination() -> [() -> Void] {
        guard !isTerminating else { return [] }
        isTerminating = true
        let callbacks = deferredAutomaticSwitch?.resolveCallbacks(success: false)
            ?? []
        deferredAutomaticSwitch = nil
        return callbacks
    }

    /// Keeps the newest normal route while resolving every superseded request.
    /// Once termination starts, normal routes are ignored and their completion
    /// is resolved immediately; they cannot replace the final local route.
    mutating func deferSwitch(
        input: MonitorInputSource,
        description: String,
        intent: DeferredAutomaticSwitchIntent,
        completion: (() -> Void)?,
        result: ((Bool) -> Void)? = nil,
        recoveryInputOnFailure: MonitorInputSource? = nil,
        shouldWakeDisplayForKVMSwitch: Bool = true,
        role: DisplayRouteRole = .unknown,
        routeRequest: DisplayRouteSwitchRequest? = nil
    ) -> [() -> Void] {
        guard intent == .terminating || !isTerminating else {
            return DeferredAutomaticSwitch(
                input: input,
                description: description,
                intent: intent,
                completion: completion,
                result: result,
                recoveryInputOnFailure: recoveryInputOnFailure,
                shouldWakeDisplayForKVMSwitch: shouldWakeDisplayForKVMSwitch,
                role: role,
                routeRequest: routeRequest
            ).resolveCallbacks(success: false)
        }
        let supersededCompletions = deferredAutomaticSwitch?.resolveCallbacks(
            success: false
        ) ?? []
        deferredAutomaticSwitch = DeferredAutomaticSwitch(
            input: input,
            description: description,
            intent: intent,
            completion: completion,
            result: result,
            recoveryInputOnFailure: recoveryInputOnFailure,
            shouldWakeDisplayForKVMSwitch: shouldWakeDisplayForKVMSwitch,
            role: role,
            routeRequest: routeRequest
        )
        return supersededCompletions
    }

    mutating func takeDeferredSwitch() -> DeferredAutomaticSwitch? {
        defer { deferredAutomaticSwitch = nil }
        return deferredAutomaticSwitch
    }
}
