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

public enum M1DDCCommand {
    public static func arguments(
        displaySelector: String,
        input: MonitorInputSource
    ) -> [String] {
        let selector = displaySelector.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if selector.isEmpty {
            return ["set", "input", String(input.rawValue)]
        }
        return [
            "display", selector, "set", "input", String(input.rawValue)
        ]
    }
}
