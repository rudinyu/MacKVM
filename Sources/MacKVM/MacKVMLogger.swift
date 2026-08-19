import Foundation
import OSLog

/// Unified-log channels used for diagnosing pairing and secure-session issues.
///
/// These logs intentionally contain only short request/peer identifiers,
/// message stages, and transport outcomes. They never include private keys,
/// verification contributions, verification codes, or wire payloads.
enum MacKVMLogger {
    private static let subsystem =
        Bundle.main.bundleIdentifier ?? "app.mackvm.MacKVM"

    static let pairing = Logger(
        subsystem: subsystem,
        category: "pairing"
    )
    static let secureSession = Logger(
        subsystem: subsystem,
        category: "secure-session"
    )

    static func short(_ id: UUID?) -> String {
        guard let id else { return "none" }
        return String(id.uuidString.prefix(8))
    }

    static func short(_ id: ObjectIdentifier?) -> String {
        guard let id else { return "none" }
        return String(describing: id)
    }
}
