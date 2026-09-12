import Foundation

/// Describes where external USB keyboard and mouse devices are connected.
/// MacKVM cannot create a USB path through an HDMI cable, but every Mac can
/// still originate remote control from its own keyboard, mouse, or trackpad.
/// This setting documents the physical wiring without incorrectly treating
/// the HDMI path as a limit on software input sharing.
public enum InputTopologyMode: String, CaseIterable, Codable, Sendable {
    /// The MA270U USB-C path carries the external devices to the Apple Silicon
    /// Mac. The HDMI path does not carry those external USB devices.
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

    /// Whether this Mac may originate a control request from its local input
    /// devices. Built-in keyboard/trackpad input is local to each Mac, so the
    /// answer is independent of CPU architecture and external USB wiring.
    public func allowsLocalControl(isAppleSilicon _: Bool) -> Bool {
        true
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
