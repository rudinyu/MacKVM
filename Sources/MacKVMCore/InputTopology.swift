import Foundation

/// Describes where the physical keyboard and mouse are connected.  MacKVM
/// cannot create a USB path through an HDMI cable, so this setting is an
/// explicit safety boundary rather than an attempt to infer hardware.
public enum InputTopologyMode: String, CaseIterable, Codable, Sendable {
    /// The MA270U USB-C path is attached to the Apple Silicon Mac.  The
    /// Intel Mac is an HDMI-only display host and can receive control, but it
    /// cannot originate keyboard/mouse input until the devices are switched.
    case singleHostOnM5Pro

    /// Both Macs can see the same keyboard and mouse through an external USB
    /// switch (or an equivalent physical setup).  Software cannot verify the
    /// switch, so the user must test both paths before enabling it.
    case externalUsbSwitch

    public var displayName: String {
        switch self {
        case .singleHostOnM5Pro:
            String(localized: "One keyboard on M5 Pro (USB-C)")
        case .externalUsbSwitch:
            String(localized: "External USB switch (bidirectional)")
        }
    }

    public var hardwareSummary: String {
        switch self {
        case .singleHostOnM5Pro:
            String(localized: "Recommended for MA270U: M5 Pro uses USB-C and Intel uses HDMI.")
        case .externalUsbSwitch:
            String(localized: "Both Macs must see the keyboard and mouse through a physical USB switch.")
        }
    }

    /// Whether this Mac is allowed to originate a control request.  Receiving
    /// control remains safe and available in either mode.
    public func allowsLocalControl(isAppleSilicon: Bool) -> Bool {
        switch self {
        case .singleHostOnM5Pro:
            return isAppleSilicon
        case .externalUsbSwitch:
            return true
        }
    }
}

public enum InputTopologyPolicy {
    public static func allowsLocalControl(
        mode: InputTopologyMode,
        isAppleSilicon: Bool
    ) -> Bool {
        mode.allowsLocalControl(isAppleSilicon: isAppleSilicon)
    }
}
