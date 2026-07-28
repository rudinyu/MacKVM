import Combine
import Foundation
import MacKVMCore

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
        didSet { defaults.set(displaySelector, forKey: Keys.displaySelector) }
    }
    @Published var executablePath: String {
        didSet { defaults.set(executablePath, forKey: Keys.executablePath) }
    }
    @Published private(set) var status = "Monitor switching is ready"

    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "app.mackvm.monitor-control")

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
        ) ?? "1"
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

    func switchToLocal(completion: (() -> Void)? = nil) {
        switchInput(
            localInput,
            description: "this Mac",
            completion: completion
        )
    }

    func switchToRemote() {
        switchInput(
            remoteInput,
            description: "the other Mac",
            completion: nil
        )
    }

    private func switchInput(
        _ input: MonitorInputSource,
        description: String,
        completion: (() -> Void)?
    ) {
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let timeout = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + 5,
                execute: timeout
            )
            process.waitUntilExit()
            timeout.cancel()
            if process.terminationStatus == 0 {
                publish(
                    "MA270U switched to \(input.name) for \(description)",
                    completion: completion
                )
            } else {
                publish(
                    "DDC switch failed; select \(input.name) in the MA270U OSD",
                    completion: completion
                )
            }
        } catch {
            publish(
                "Could not run m1ddc; select \(input.name) in the MA270U OSD",
                completion: completion
            )
        }
    }

    private func publish(
        _ message: String,
        completion: (() -> Void)? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.status = message
            completion?()
        }
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
