import Foundation

public enum MonitorInputSource: Int, CaseIterable, Codable, Sendable {
    case displayPort1 = 15
    case displayPort2 = 16
    case hdmi1 = 17
    case hdmi2 = 18
    // Input-source values are monitor-firmware values, not a universal
    // connection-type enum. 27 is the long-standing MCCS value used by many
    // panels; model-specific firmware overrides are applied by
    // MonitorInputMapping when the EDID identifies a known exception.
    case usbC = 27

    public var name: String {
        switch self {
        case .displayPort1:
            return "DisplayPort 1"
        case .displayPort2:
            return "DisplayPort 2"
        case .hdmi1:
            return "HDMI 1"
        case .hdmi2:
            return "HDMI 2"
        case .usbC:
            return "USB-C"
        }
    }
}

/// Resolves a logical input to the VCP value used by a particular monitor.
///
/// MCCS documents common values, but input-source values are ultimately
/// monitor-firmware data. Keep the generic USB-C value for existing panels and
/// persisted preferences while allowing a model-specific EDID override (the
/// BenQ MA270U tested with MacKVM uses 0x13).
public enum MonitorInputMapping {
    /// The native display selector encodes the EDID vendor and product IDs
    /// before its serial number or EDID fingerprint.  CoreGraphics can
    /// temporarily return an empty display list while a monitor changes
    /// inputs, so callers must be able to recover this identity from the
    /// persisted selector instead of falling back to a generic VCP value.
    ///
    /// Only the canonical `native-ddc:<vendor>:<product>:...` form is
    /// accepted.  Numeric legacy selectors and malformed/user-edited values
    /// are rejected rather than being treated as monitor identity.
    public static func displayIdentity(
        fromNativeSelector selector: String
    ) -> (vendorID: UInt32, productID: UInt32)? {
        let normalized = selector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let components = normalized.split(
            separator: ":",
            omittingEmptySubsequences: false
        )
        guard components.count >= 4,
              components[0].caseInsensitiveCompare("native-ddc") == .orderedSame,
              let vendorID = UInt32(components[1]),
              let productID = UInt32(components[2]),
              vendorID > 0,
              productID > 0 else {
            return nil
        }
        return (vendorID: vendorID, productID: productID)
    }

    public static func rawValue(
        for input: MonitorInputSource,
        vendorID: UInt32?,
        productID: UInt32?,
        nativeSelector: String? = nil
    ) -> UInt32 {
        let selectorIdentity = nativeSelector.flatMap {
            displayIdentity(fromNativeSelector: $0)
        }
        let effectiveVendorID = vendorID.flatMap { $0 > 0 ? $0 : nil }
            ?? selectorIdentity?.vendorID
        let effectiveProductID = productID.flatMap { $0 > 0 ? $0 : nil }
            ?? selectorIdentity?.productID
        if input == .usbC,
           effectiveVendorID == 2513,
           effectiveProductID == 32884 {
            return 19
        }
        return UInt32(input.rawValue)
    }

    /// Compares a read-back VCP 0x60 value with the monitor-specific value
    /// that a logical input represents. Keeping this decision beside the
    /// mapping prevents a MA270U USB-C value (19) from being compared with
    /// the generic MCCS value (27).
    public static func isInputSelected(
        currentValue: UInt16,
        input: MonitorInputSource,
        vendorID: UInt32?,
        productID: UInt32?,
        nativeSelector: String? = nil
    ) -> Bool {
        UInt32(currentValue) == rawValue(
            for: input,
            vendorID: vendorID,
            productID: productID,
            nativeSelector: nativeSelector
        )
    }
}

/// The native bridge sends a VESA DDC/CI Set VCP packet for input source
/// (VCP 0x60). Keeping the packet layout here makes the protocol testable
/// without requiring a physical monitor in CI; IOKit performs the transport.
public enum NativeDDCCommand {
    public static func setInputPacket(
        for input: MonitorInputSource
    ) -> [UInt8] {
        setInputPacket(for: input, vendorID: nil, productID: nil)
    }

    public static func setInputPacket(
        for input: MonitorInputSource,
        vendorID: UInt32?,
        productID: UInt32?
    ) -> [UInt8] {
        let rawValue = MonitorInputMapping.rawValue(
            for: input,
            vendorID: vendorID,
            productID: productID
        )
        var packet: [UInt8] = [
            0x51, // DDC/CI source address byte
            0x84, // Set VCP feature
            0x03, // payload length
            0x60, // Input Source VCP code
            0x00, // high byte of the new value
            UInt8(truncatingIfNeeded: rawValue),
            0x00 // checksum, filled below
        ]
        var checksum: UInt8 = 0x6E // 8-bit write address
        for byte in packet[0..<6] {
            checksum ^= byte
        }
        packet[6] = checksum
        return packet
    }
}
