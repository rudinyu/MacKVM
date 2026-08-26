import Combine
import Foundation
import MacKVMCore

/// Persists the user's physical input wiring and exposes the safety decision
/// used by both the menu and ControlCoordinator.  The hardware itself is not
/// discoverable from the app, so changing this setting is an explicit user
/// acknowledgement.
final class InputTopologyController: ObservableObject {
    static let storageKey = "MacKVM.inputTopologyMode"

    @Published var mode: InputTopologyMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.storageKey)
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedMode = defaults.string(forKey: Self.storageKey)
            .flatMap(InputTopologyMode.init(rawValue:))
        mode = storedMode ?? .singleHostOnM5Pro
    }

    var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    var allowsLocalControl: Bool {
        InputTopologyPolicy.allowsLocalControl(
            mode: mode,
            isAppleSilicon: isAppleSilicon
        )
    }

    var statusMessage: String {
        switch mode {
        case .singleHostOnM5Pro where !isAppleSilicon:
            String(localized: "The HDMI path does not carry external USB devices to this Intel Mac, but its built-in keyboard and trackpad can still request control. Connect shared external devices to both Macs or use a USB switch for external bidirectional input.")
        case .singleHostOnM5Pro:
            String(localized: "Connect external keyboard and mouse devices to the M5 Pro (directly or through the MA270U USB hub). Both Macs can still use their local keyboard, mouse, and trackpad to request control.")
        case .externalUsbSwitch:
            String(localized: "MacKVM cannot detect a USB switch. Verify both Macs see the external keyboard and mouse; each Mac can also use its local keyboard, mouse, and trackpad.")
        }
    }
}
