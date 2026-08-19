import Foundation

public enum MonitorInputSource: Int, CaseIterable, Codable, Sendable {
    case displayPort1 = 15
    case displayPort2 = 16
    case hdmi1 = 17
    case hdmi2 = 18
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

/// The native bridge sends a VESA DDC/CI Set VCP packet for input source
/// (VCP 0x60). Keeping the packet layout here makes the protocol testable
/// without requiring a physical monitor in CI; IOKit performs the transport.
public enum NativeDDCCommand {
    public static func setInputPacket(
        for input: MonitorInputSource
    ) -> [UInt8] {
        var packet: [UInt8] = [
            0x51, // DDC/CI source address byte
            0x84, // Set VCP feature
            0x03, // payload length
            0x60, // Input Source VCP code
            0x00, // high byte of the new value
            UInt8(input.rawValue),
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
