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
            "This Intel Mac is HDMI-only in the current wiring, so it cannot originate keyboard/mouse input. Select the USB-switch mode after connecting the devices to both Macs."
        case .singleHostOnM5Pro:
            "Connect the keyboard and mouse to the M5 Pro (directly or through the MA270U USB hub). The Intel HDMI Mac can receive control only."
        case .externalUsbSwitch:
            "MacKVM cannot detect a USB switch. Verify both Macs see the keyboard and mouse before requesting control."
        }
    }
}
