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
    public static func rawValue(
        for input: MonitorInputSource,
        vendorID: UInt32?,
        productID: UInt32?
    ) -> UInt32 {
        if input == .usbC,
           vendorID == 2513,
           productID == 32884 {
            return 19
        }
        return UInt32(input.rawValue)
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
