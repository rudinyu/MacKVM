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
    private var isDiscoveringDisplays = false
    private var hasCompletedDisplayDiscovery = false
    private var deferredAutomaticSwitchState = DeferredAutomaticSwitchState()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automationEnabled = defaults.object(
            forKey: Keys.automationEnabled
        ) as? Bool ?? false
        localInput = MonitorInputSource(
            rawValue: defaults.integer(forKey: Keys.localInput)
        ) ?? .usbC
        remoteInput = MonitorInputSource(
            rawValue: defaults.integer(forKey: Keys.remoteInput)
        ) ?? .hdmi1
        displaySelector = defaults.string(
            forKey: Keys.displaySelector
        ) ?? ""
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

    func refreshDetectedDisplays() {
        guard !isDiscoveringDisplays else { return }
        isDiscoveringDisplays = true
        hasCompletedDisplayDiscovery = false
        detectedDisplays = []
        isDisplaySelectorVerified = false
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
                    diagnostic: nil
                )
            } catch {
                self.publishDiscovery(
                    displays: [],
                    message: "No DDC-capable external display was detected; check the cable and DDC/CI setting",
                    diagnostic: Self.diagnostic(from: error)
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
                  hasCompletedDisplayDiscovery: true
              ) == .switchNow else {
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
        switch Self.automaticSwitchDecision(
            displaySelector: selector,
            isDisplaySelectorVerified: isDisplaySelectorVerified,
            hasCompletedDisplayDiscovery: hasCompletedDisplayDiscovery
        ) {
        case .switchNow:
            break
        case .waitForVerification:
            let cancelledCompletions = deferredAutomaticSwitchState.deferSwitch(
                input: input,
                description: description,
                intent: intent,
                completion: completion
            )
            cancelledCompletions.forEach { $0() }
            reportResult(false)
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

        let selectedDisplay = detectedDisplays.first {
            $0.matches(selector: selector)
        }
        let displayName = selectedDisplay?.name ?? "display"
        // Use the canonical selector returned by discovery. This keeps the
        // editable field case-insensitive without passing a user-edited
        // spelling to the native C bridge.
        let nativeSelector = selectedDisplay?.selector ?? selector
        status = "Switching \(displayName) to \(input.name)…"
        queue.async { [weak self] in
            do {
                try NativeDDCService.switchInput(
                    displaySelector: nativeSelector,
                    input: input
                )
                self?.publish(
                    "\(displayName) switched to \(input.name) for \(description)",
                    completion: completion
                )
                reportResult(true)
            } catch {
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
        diagnostic: String?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isDiscoveringDisplays = false
            hasCompletedDisplayDiscovery = true
            detectedDisplays = displays
            self.diagnostic = diagnostic
            updateSelectorVerification()

            // Legacy m1ddc selectors were numeric indexes. Native CoreGraphics
            // and IOKit enumeration order is not guaranteed to match that
            // tool, so never migrate a number implicitly: the user must pick
            // the intended display from the verified native list.
            status = message
            resumeDeferredAutomaticSwitch()
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
            completion: deferredAutomaticSwitch.complete
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

    private static func diagnostic(from error: Error) -> String {
        String(error.localizedDescription.prefix(600))
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

    init(
        input: MonitorInputSource,
        description: String,
        intent: DeferredAutomaticSwitchIntent,
        completion: (() -> Void)?
    ) {
        self.input = input
        self.description = description
        self.intent = intent
        completions = completion.map { [$0] } ?? []
    }

    func complete() {
        completions.forEach { $0() }
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
        let completions = deferredAutomaticSwitch?.completions ?? []
        deferredAutomaticSwitch = nil
        return completions
    }

    /// Keeps the newest normal route while resolving every superseded request.
    /// Once termination starts, normal routes are ignored and their completion
    /// is resolved immediately; they cannot replace the final local route.
    mutating func deferSwitch(
        input: MonitorInputSource,
        description: String,
        intent: DeferredAutomaticSwitchIntent,
        completion: (() -> Void)?
    ) -> [() -> Void] {
        guard intent == .terminating || !isTerminating else {
            return completion.map { [$0] } ?? []
        }
        let supersededCompletions = deferredAutomaticSwitch?.completions ?? []
        deferredAutomaticSwitch = DeferredAutomaticSwitch(
            input: input,
            description: description,
            intent: intent,
            completion: completion
        )
        return supersededCompletions
    }

    mutating func takeDeferredSwitch() -> DeferredAutomaticSwitch? {
        defer { deferredAutomaticSwitch = nil }
        return deferredAutomaticSwitch
    }
}
