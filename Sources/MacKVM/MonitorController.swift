import AppKit
import Combine
import Foundation
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

private struct RoutePreservationAttempt {
    enum Status {
        case pending
        case succeeded
    }

    let id: UUID
    let selector: String
    /// Keep the display identity alongside the selector. CoreGraphics can
    /// temporarily report no displays after an input switch, but the return
    /// route still needs the EDID model IDs for model-specific VCP values.
    var display: DDCDisplay?
    var deadline: Date
    var status: Status = .pending
    var topologyRefreshStarted = false
    var refreshAfterCurrentDiscovery = false
}

final class MonitorController: ObservableObject {
    @Published var automationEnabled: Bool {
        didSet { defaults.set(automationEnabled, forKey: Keys.automationEnabled) }
    }
    @Published var localInput: MonitorInputSource {
        didSet { defaults.set(localInput.rawValue, forKey: Keys.localInput) }
    }
    @Published var remoteInput: MonitorInputSource {
        didSet { defaults.set(remoteInput.rawValue, forKey: Keys.remoteInput) }
    }
    @Published var displaySelector: String {
        didSet {
            defaults.set(displaySelector, forKey: Keys.displaySelector)
            updateSelectorVerification()
        }
    }
    @Published private(set) var status = "Monitor switching is ready"
    @Published private(set) var detectedDisplays: [DDCDisplay] = []
    @Published private(set) var isDisplaySelectorVerified = false
    @Published private(set) var diagnostic: String?

    /// Native IOKit DDC/CI is available on both supported architectures.
    var supportsAutomaticDDCSwitching: Bool { true }

    private let defaults: UserDefaults
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
    private var deferredAutomaticSwitchState = DeferredAutomaticSwitchState()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automationEnabled = defaults.object(
            forKey: Keys.automationEnabled
        ) as? Bool ?? false
        localInput = Self.inputPreference(
            rawValue: defaults.integer(forKey: Keys.localInput),
            fallback: .usbC
        )
        remoteInput = Self.inputPreference(
            rawValue: defaults.integer(forKey: Keys.remoteInput),
            fallback: .hdmi1
        )
        displaySelector = defaults.string(
            forKey: Keys.displaySelector
        ) ?? ""
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
    }

    deinit {
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
        status = "Preset: this Mac uses USB-C; the other Mac uses HDMI 1"
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
            && routePreservationAttempt?.status == .succeeded
            && routePreservationAttempt?.selector.caseInsensitiveCompare(
                selectorAtStart
            ) == .orderedSame
            && !selectorAtStart.isEmpty
        // A successful remote route can outlive the short topology-notification
        // window above. Keep the last verified selector usable during routine
        // menu-triggered discovery; CoreGraphics may briefly report an empty
        // display list while the monitor is showing the other input. The
        // native bridge still re-resolves the selector and fails closed if the
        // display is genuinely gone.
        let hasCachedVerifiedSelector = lastVerifiedDisplay?.matches(
            selector: selectorAtStart
        ) == true
        isDiscoveringDisplays = true
        hasCompletedDisplayDiscovery = false
        if !shouldPreserveSelector && !hasCachedVerifiedSelector {
            detectedDisplays = []
            isDisplaySelectorVerified = false
        }
        status = "Detecting DDC-capable external displays…"
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let displays = try NativeDDCService.discover()
                let message = displays.count == 1
                    ? "Detected 1 DDC-capable external display"
                    : "Detected \(displays.count) DDC-capable external displays"
                self.publishDiscovery(
                    displays: displays,
                    message: message,
                    diagnostic: nil,
                    preservationAttemptID: preservationAttemptID,
                    preservedSelector: preservationAttemptID == nil
                        ? nil : selectorAtStart
                )
            } catch {
                self.publishDiscovery(
                    displays: [],
                    message: "No DDC-capable external display was detected; check the cable and DDC/CI setting",
                    diagnostic: Self.diagnostic(from: error),
                    preservationAttemptID: preservationAttemptID,
                    preservedSelector: preservationAttemptID == nil
                        ? nil : selectorAtStart
                )
            }
        }
    }

    private func handleDisplayConfigurationChange() {
        let now = Date()
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
        attemptID: UUID?
    ) {
        guard let attemptID else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard var attempt = routePreservationAttempt,
                  attempt.id == attemptID else {
                return
            }
            guard success else {
                // A topology refresh may still be in flight, but it carries
                // this attempt ID and will now fail its success gate below.
                routePreservationAttempt = nil
                return
            }
            attempt.status = .succeeded
            // If no topology notification follows the DDC write, do not let
            // an unrelated unplug much later consume the preservation state.
            attempt.deadline = Date().addingTimeInterval(2)
            if attempt.topologyRefreshStarted && isDiscoveringDisplays {
                attempt.refreshAfterCurrentDiscovery = true
                routePreservationAttempt = attempt
                return
            }
            routePreservationAttempt = attempt
            if attempt.topologyRefreshStarted {
                refreshDetectedDisplays(
                    preserveVerifiedSelector: true,
                    preservationAttemptID: attempt.id
                )
            }
        }
    }

    /// Latches the app's final local-route intent and returns completions for
    /// cancelled normal routes. The caller must first mark any receiver-side
    /// input teardown as quitting, then invoke the returned completions. This
    /// prevents a cancelled monitor route from making that teardown look idle
    /// before it can suppress a second input release.
    func beginTermination() -> [() -> Void] {
        deferredAutomaticSwitchState.beginTermination()
    }

    func selectDisplay(_ display: DDCDisplay) {
        displaySelector = display.selector
        guard display.isDDCCapable else {
            status = "\(display.name) has no native DDC/CI selector; automatic switching remains blocked"
            return
        }
        lastVerifiedDisplay = display
        status = "Selected \(display.name) for native DDC/CI switching"
    }

    func switchToLocal(completion: (() -> Void)? = nil) {
        switchInput(
            localInput,
            description: "this Mac",
            intent: .normal,
            completion: completion
        )
    }

    func switchToLocalForTermination(completion: @escaping () -> Void) {
        switchInput(
            localInput,
            description: "this Mac",
            intent: .terminating,
            completion: completion
        )
    }

    func switchToRemote(completion: (() -> Void)? = nil) {
        switchInput(
            remoteInput,
            description: "the other Mac",
            intent: .normal,
            completion: completion
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
            completion(false)
            return
        }
        switchInput(
            remoteInput,
            description: "the other Mac",
            intent: .normal,
            completion: nil,
            result: completion
        )
    }

    private func switchInput(
        _ input: MonitorInputSource,
        description: String,
        intent: DeferredAutomaticSwitchIntent,
        completion: (() -> Void)?,
        result: ((Bool) -> Void)? = nil
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
        var routePreservationAttemptID: UUID?
        switch Self.automaticSwitchDecision(
            displaySelector: selector,
            isDisplaySelectorVerified: isDisplaySelectorVerified,
            hasCompletedDisplayDiscovery: hasCompletedDisplayDiscovery
        ) {
        case .switchNow:
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
                selector: selector,
                display: currentlyDetectedDisplay ?? previousDisplay,
                deadline: Date().addingTimeInterval(10)
            )
            break
        case .waitForVerification:
            let cancelledCompletions = deferredAutomaticSwitchState.deferSwitch(
                input: input,
                description: description,
                intent: intent,
                completion: completion,
                result: result
            )
            cancelledCompletions.forEach { $0() }
            status = "Verifying the saved DDC display before switching…"
            if !isDiscoveringDisplays {
                refreshDetectedDisplays()
            }
            return
        case .useManualFallback:
            status = selector.isEmpty
                ? "Detect and select a DDC-capable display before automatic switching"
                : "The selected DDC display is not currently available; detect it again"
            completion?()
            reportResult(false)
            return
        }

        let routeDisplay = routePreservationAttempt?.display
            ?? currentlyDetectedDisplay
            ?? lastVerifiedDisplay.flatMap {
                $0.matches(selector: selector) ? $0 : nil
            }
        let displayName = routeDisplay?.name ?? "display"
        // Use the canonical selector returned by discovery. This keeps the
        // editable field case-insensitive without passing a user-edited
        // spelling to the native C bridge.
        let nativeSelector = routeDisplay?.selector ?? selector
        status = "Switching \(displayName) to \(input.name)…"
        queue.async { [weak self] in
            do {
                try NativeDDCService.switchInput(
                    displaySelector: nativeSelector,
                    input: input,
                    vendorID: routeDisplay?.vendorID,
                    productID: routeDisplay?.productID
                )
                self?.completeDisplayRouteSwitch(
                    success: true,
                    attemptID: routePreservationAttemptID
                )
                self?.publish(
                    "\(displayName) switched to \(input.name) for \(description)",
                    completion: completion
                )
                reportResult(true)
            } catch {
                self?.completeDisplayRouteSwitch(
                    success: false,
                    attemptID: routePreservationAttemptID
                )
                self?.publish(
                    "Native DDC/CI switch failed; use the monitor OSD to select \(input.name)",
                    diagnostic: Self.diagnostic(from: error),
                    completion: completion
                )
                reportResult(false)
            }
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
        preservationAttemptID: UUID?,
        preservedSelector: String? = nil
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
                // Mac" and "Show other Mac" buttons work without requiring
                // the user to guess that the display row is also a picker.
                displaySelector = selector
                lastVerifiedDisplay = displays.first {
                    $0.matches(selector: selector)
                }
            }
            self.diagnostic = diagnostic
            let canPreserveSelector: String? = preservationAttemptID.flatMap {
                attemptID in
                guard let attempt = self.routePreservationAttempt,
                      attempt.id == attemptID,
                      attempt.status == .succeeded,
                      attempt.deadline > Date(),
                      let preservedSelector,
                      self.displaySelector.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).caseInsensitiveCompare(preservedSelector)
                          == .orderedSame else {
                    return nil
                }
                return preservedSelector
            }
            if let canPreserveSelector,
               displaySelector.trimmingCharacters(
                   in: .whitespacesAndNewlines
               ).caseInsensitiveCompare(canPreserveSelector) == .orderedSame,
               !displays.contains(where: {
                   $0.matches(selector: canPreserveSelector)
               }) {
                // CoreGraphics can report no external displays while the
                // monitor is showing the other input. The saved selector is
                // still the only safe route for restoring the local input.
                isDisplaySelectorVerified = true
            } else {
                updateSelectorVerification()
            }

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
        switchInput(
            deferredAutomaticSwitch.input,
            description: deferredAutomaticSwitch.description,
            intent: deferredAutomaticSwitch.intent,
            completion: deferredAutomaticSwitch.completeCompletions,
            result: deferredAutomaticSwitch.result
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

    static func canUseAutomaticDDCSwitching(
        displaySelector: String,
        isDisplaySelectorVerified: Bool
    ) -> Bool {
        hasStableDisplaySelector(displaySelector) && isDisplaySelectorVerified
    }

    static func automaticSwitchDecision(
        displaySelector: String,
        isDisplaySelectorVerified: Bool,
        hasCompletedDisplayDiscovery: Bool
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
    let completions: [() -> Void]
    let result: ((Bool) -> Void)?

    init(
        input: MonitorInputSource,
        description: String,
        intent: DeferredAutomaticSwitchIntent,
        completion: (() -> Void)?,
        result: ((Bool) -> Void)?
    ) {
        self.input = input
        self.description = description
        self.intent = intent
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
        result: ((Bool) -> Void)? = nil
    ) -> [() -> Void] {
        guard intent == .terminating || !isTerminating else {
            return DeferredAutomaticSwitch(
                input: input,
                description: description,
                intent: intent,
                completion: completion,
                result: result
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
            result: result
        )
        return supersededCompletions
    }

    mutating func takeDeferredSwitch() -> DeferredAutomaticSwitch? {
        defer { deferredAutomaticSwitch = nil }
        return deferredAutomaticSwitch
    }
}
