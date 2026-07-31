import Combine
import Foundation
import MacKVMCore

struct M1DDCDisplay: Identifiable, Equatable {
    let index: Int
    let name: String
    let stableIdentifier: String?

    var id: String {
        stableIdentifier ?? "display-\(index)"
    }

    var selector: String {
        // DDC routing is allowed only with m1ddc's stable identifier. A
        // numeric display index can change whenever the display topology does.
        stableIdentifier ?? ""
    }

    var displayName: String {
        if let stableIdentifier {
            return "[\(index)] \(name) — \(stableIdentifier)"
        }
        return "[\(index)] \(name)"
    }

    var isLikelyMA270U: Bool {
        // This is an EDID-provided model-name hint, not hardware attestation.
        // The stable m1ddc identifier below is still required before DDC/CI is
        // allowed, and a person must confirm the chosen display in the UI.
        let normalizedName = name.lowercased()
        return normalizedName.contains("ma270u")
    }

    func matches(selector: String) -> Bool {
        let normalizedSelector = selector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let stableIdentifier else { return false }
        return normalizedSelector.caseInsensitiveCompare(stableIdentifier)
            == .orderedSame
    }

    /// Replaces an older numeric display index with this display's stable
    /// m1ddc identifier. A different stable identifier is deliberately kept:
    /// discovery must never retarget DDC/CI to another display by itself.
    func stableSelectorReplacing(_ currentSelector: String) -> String? {
        guard let stableIdentifier else { return nil }
        let normalizedSelector = currentSelector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard Int(normalizedSelector) == index else {
            return nil
        }
        return stableIdentifier
    }
}

enum M1DDCDisplayListParser {
    static func displays(from output: String) -> [M1DDCDisplay] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            parse(String(line))
        }
    }

    static func recommendedDisplay(
        from displays: [M1DDCDisplay]
    ) -> M1DDCDisplay? {
        let ma270UDisplays = displays.filter {
            $0.isLikelyMA270U && $0.stableIdentifier != nil
        }
        if ma270UDisplays.count == 1 {
            return ma270UDisplays[0]
        }
        return nil
    }

    private static func parse(_ line: String) -> M1DDCDisplay? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "[",
              let closingBracket = trimmed.firstIndex(of: "]") else {
            return nil
        }
        let indexStart = trimmed.index(after: trimmed.startIndex)
        guard let index = Int(trimmed[indexStart..<closingBracket]) else {
            return nil
        }
        let afterIndex = trimmed[trimmed.index(after: closingBracket)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !afterIndex.isEmpty else { return nil }

        guard let closingParenthesis = afterIndex.lastIndex(of: ")"),
              let openingParenthesis = afterIndex[..<closingParenthesis]
                .lastIndex(of: "(") else {
            return M1DDCDisplay(
                index: index,
                name: afterIndex,
                stableIdentifier: nil
            )
        }

        let name = afterIndex[..<openingParenthesis]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let identifierStart = afterIndex.index(after: openingParenthesis)
        let identifier = afterIndex[identifierStart..<closingParenthesis]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return M1DDCDisplay(
            index: index,
            name: name.isEmpty ? "Unnamed display" : name,
            stableIdentifier: identifier.isEmpty || identifier == "(null)"
                || identifier.lowercased() == "null" ? nil : identifier
        )
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
    @Published var executablePath: String {
        didSet { defaults.set(executablePath, forKey: Keys.executablePath) }
    }
    @Published private(set) var status = "Monitor switching is ready"
    @Published private(set) var detectedDisplays: [M1DDCDisplay] = []
    @Published private(set) var isDisplaySelectorVerified = false
    @Published private(set) var diagnostic: String?

    var supportsAutomaticDDCSwitching: Bool {
#if arch(arm64)
        true
#else
        false
#endif
    }

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
        executablePath = defaults.string(
            forKey: Keys.executablePath
        ) ?? Self.detectM1DDC()
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
        automationEnabled = false
        status = "Preset: this Mac uses HDMI 1; use manual monitor switching"
    }

    func refreshDetectedDisplays() {
#if arch(arm64)
        guard !isDiscoveringDisplays else { return }
        isDiscoveringDisplays = true
        hasCompletedDisplayDiscovery = false
        detectedDisplays = []
        isDisplaySelectorVerified = false
        let path = executablePath.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path) else {
            self.publishDiscovery(
                displays: [],
                message: "m1ddc was not found; install it before detecting the MA270U",
                diagnostic: "No executable m1ddc was found at \(path)."
            )
            return
        }
        status = "Detecting external displays…"
        queue.async { [weak self] in
            guard let self else { return }
            let result = executeM1DDC(
                path: path,
                arguments: ["display", "list"]
            )
            let displays = result.succeeded
                ? M1DDCDisplayListParser.displays(from: result.standardOutput)
                : []
            let message: String
            if !result.succeeded {
                message = "Could not detect displays; see the DDC diagnostic below"
            } else if displays.isEmpty {
                message = "m1ddc found no external displays; check the USB-C connection"
            } else if let recommended = M1DDCDisplayListParser.recommendedDisplay(
                from: displays
            ) {
                message = "Detected \(recommended.name); select it to use DDC/CI"
            } else {
                message = "No uniquely identified MA270U was found; automatic switching remains off"
            }
            self.publishDiscovery(
                displays: displays,
                message: message,
                diagnostic: result.diagnostic
            )
        }
#else
        publishDiscovery(
            displays: [],
            message: "m1ddc does not support Intel Macs; use the MA270U OSD",
            diagnostic: nil
        )
#endif
    }

    /// Latches the app's final local-route intent and returns completions for
    /// cancelled normal routes. The caller must first mark any receiver-side
    /// input teardown as quitting, then invoke the returned completions. This
    /// prevents a cancelled monitor route from making that teardown look idle
    /// before it can suppress a second input release.
    func beginTermination() -> [() -> Void] {
        deferredAutomaticSwitchState.beginTermination()
    }

    func selectDisplay(_ display: M1DDCDisplay) {
        displaySelector = display.selector
        if display.stableIdentifier == nil {
            status = "\(display.name) has no stable m1ddc identifier; automatic switching remains blocked"
        } else if display.isLikelyMA270U {
            status = "Selected \(display.name) for DDC/CI switching"
        } else {
            status = "\(display.name) is not identified as an MA270U; automatic switching remains blocked"
        }
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

    private func switchInput(
        _ input: MonitorInputSource,
        description: String,
        intent: DeferredAutomaticSwitchIntent,
        completion: (() -> Void)?
    ) {
        guard intent == .terminating
                || !deferredAutomaticSwitchState.isTerminating else {
            completion?()
            return
        }
        guard automationEnabled else {
            status = "Use the MA270U OSD to select \(input.name) for \(description)"
            completion?()
            return
        }
#if arch(arm64)
        let path = executablePath.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: path) else {
            status = "m1ddc was not found; use the MA270U OSD to select \(input.name)"
            completion?()
            return
        }
        let selector = displaySelector
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            status = "Verifying the saved MA270U before switching…"
            if !isDiscoveringDisplays {
                refreshDetectedDisplays()
            }
            return
        case .useManualFallback:
            status = selector.isEmpty
                ? "Detect and select the MA270U before using DDC/CI switching"
                : "The selected display is not a verified MA270U; choose the MA270U again"
            completion?()
            return
        }
        status = "Switching the MA270U to \(input.name)…"
        queue.async { [weak self] in
            self?.runM1DDC(
                path: path,
                arguments: M1DDCCommand.arguments(
                    displaySelector: selector,
                    input: input
                ),
                input: input,
                description: description,
                completion: completion
            )
        }
#else
        status = "m1ddc does not support Intel Macs; use the MA270U OSD to select \(input.name)"
        completion?()
#endif
    }

    private func runM1DDC(
        path: String,
        arguments: [String],
        input: MonitorInputSource,
        description: String,
        completion: (() -> Void)?
    ) {
        let result = executeM1DDC(path: path, arguments: arguments)
        if result.succeeded {
            publish(
                "MA270U switched to \(input.name) for \(description)",
                diagnostic: result.diagnostic,
                completion: completion
            )
        } else {
            publish(
                "DDC switch failed; select \(input.name) in the MA270U OSD",
                diagnostic: result.diagnostic,
                completion: completion
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
        displays: [M1DDCDisplay],
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

            if let selected = M1DDCDisplayListParser.recommendedDisplay(
                from: displays
            ), let stableSelector = selected.stableSelectorReplacing(
                displaySelector
            ) {
                displaySelector = stableSelector
                status = "Migrated the selected \(selected.name) to its stable identifier"
            } else {
                status = message
            }
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
                $0.matches(selector: selector) && $0.isLikelyMA270U
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
        return !selector.isEmpty && Int(selector) == nil
    }

    private static func detectM1DDC() -> String {
        let candidates = [
            "/opt/homebrew/bin/m1ddc",
            "/usr/local/bin/m1ddc"
        ]
        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "/opt/homebrew/bin/m1ddc"
    }

    private enum Keys {
        static let automationEnabled = "MacKVM.monitor.automationEnabled"
        static let localInput = "MacKVM.monitor.localInput"
        static let remoteInput = "MacKVM.monitor.remoteInput"
        static let displaySelector = "MacKVM.monitor.displaySelector"
        static let executablePath = "MacKVM.monitor.executablePath"
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

private struct M1DDCProcessResult {
    let terminationStatus: Int32?
    let timedOut: Bool
    let standardOutput: String
    let standardError: String
    let launchError: String?

    var succeeded: Bool {
        terminationStatus == 0 && !timedOut && launchError == nil
    }

    var diagnostic: String? {
        let output = [standardError, standardOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let detail: String
        if let launchError {
            detail = launchError
        } else if timedOut {
            detail = "m1ddc timed out after 5 seconds."
        } else if let terminationStatus, terminationStatus != 0 {
            detail = "m1ddc exited with status \(terminationStatus)."
        } else {
            detail = ""
        }
        let combined = [detail, output]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !combined.isEmpty else { return nil }
        return String(combined.prefix(600))
    }
}

private final class M1DDCTimeoutState {
    private let lock = NSLock()
    private var value = false

    func markTimedOut() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func executeM1DDC(
    path: String,
    arguments: [String]
) -> M1DDCProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError
    do {
        try process.run()
        let output = M1DDCOutputCollector()
        let errorOutput = M1DDCOutputCollector()
        let readGroup = DispatchGroup()
        collectPipe(standardOutput, into: output, group: readGroup)
        collectPipe(standardError, into: errorOutput, group: readGroup)
        let timeoutState = M1DDCTimeoutState()
        let timeout = DispatchWorkItem {
            if process.isRunning {
                timeoutState.markTimedOut()
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 5,
            execute: timeout
        )
        process.waitUntilExit()
        timeout.cancel()
        readGroup.wait()
        return M1DDCProcessResult(
            terminationStatus: process.terminationStatus,
            timedOut: timeoutState.timedOut,
            standardOutput: output.value,
            standardError: errorOutput.value,
            launchError: nil
        )
    } catch {
        return M1DDCProcessResult(
            terminationStatus: nil,
            timedOut: false,
            standardOutput: "",
            standardError: "",
            launchError: "Could not start m1ddc: \(error.localizedDescription)"
        )
    }
}

private final class M1DDCOutputCollector {
    private let lock = NSLock()
    private var data = Data()

    func set(_ data: Data) {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private func collectPipe(
    _ pipe: Pipe,
    into collector: M1DDCOutputCollector,
    group: DispatchGroup
) {
    group.enter()
    DispatchQueue.global(qos: .utility).async {
        collector.set(pipe.fileHandleForReading.readDataToEndOfFile())
        group.leave()
    }
}
