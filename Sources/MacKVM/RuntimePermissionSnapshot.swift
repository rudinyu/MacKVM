import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hidsystem
import OSLog

/// A non-secret snapshot of the public macOS APIs MacKVM uses to decide
/// whether its Core Graphics event tap and event-posting paths are available.
/// IOHIDCheckAccess is retained as diagnostic evidence; its IOHIDManager /
/// IOHIDPostEvent scope does not replace the Core Graphics checks used here.
struct RuntimePermissionSnapshot: Equatable {
    let canListenToCoreGraphicsEvents: Bool
    let canPostCoreGraphicsEvents: Bool
    let accessibilityIsTrusted: Bool
    let ioHIDListenAccess: IOHIDPermissionSignal
    let ioHIDPostAccess: IOHIDPermissionSignal

    var canCaptureInput: Bool {
        canListenToCoreGraphicsEvents
    }

    /// The outbound controller needs its active capture path and the same
    /// receiver-side injection grants required when this Mac receives input.
    var canStartOutboundControl: Bool {
        canCaptureInput && canInjectRemoteInput
    }

    var canInjectRemoteInput: Bool {
        accessibilityIsTrusted && canPostCoreGraphicsEvents
    }

    /// The consuming session tap used for global shortcuts needs the listen
    /// grant plus the trust and posting grants required by a default tap.
    /// When this effective path is unavailable, Carbon registered hotkeys
    /// remain the fallback.
    var canUseSessionHotKeyTap: Bool {
        canListenToCoreGraphicsEvents
            && accessibilityIsTrusted
            && canPostCoreGraphicsEvents
    }

    func requiresHotKeyMonitorRebuild(
        comparedTo nextSnapshot: RuntimePermissionSnapshot
    ) -> Bool {
        canCaptureInput != nextSnapshot.canCaptureInput
            || canUseSessionHotKeyTap != nextSnapshot.canUseSessionHotKeyTap
    }

    func revokesOutboundControl(
        comparedTo nextSnapshot: RuntimePermissionSnapshot
    ) -> Bool {
        canStartOutboundControl && !nextSnapshot.canStartOutboundControl
    }

    var remoteInputPermissionFailureStatus: String {
        if !accessibilityIsTrusted {
            if #available(macOS 27, *) {
                return "Device Control and Data Access permission is required"
            }
            return "Accessibility permission is required"
        }
        if !canPostCoreGraphicsEvents {
            return "System-reported event posting access is required"
        }
        return "Accessibility permission is required"
    }

    var remoteControlPermissionFailureStatus: String {
        if !accessibilityIsTrusted {
            if #available(macOS 27, *) {
                return "Device Control and Data Access permission is required to control another device"
            }
            return "Accessibility permission is required to control another device"
        }
        return "System-reported event posting access is required to control another device"
    }

    var remoteInputPermissionDenialReason: String {
        if !accessibilityIsTrusted {
            if #available(macOS 27, *) {
                return "Denied remote control: Device Control and Data Access permission is missing"
            }
            return "Denied remote control: Accessibility permission is missing"
        }
        if !canPostCoreGraphicsEvents {
            return "Denied remote control: System-reported event posting access is missing"
        }
        return "Denied remote control: Accessibility permission is missing"
    }

    var remoteInputPermissionFailureEndReason: String {
        if !accessibilityIsTrusted {
            if #available(macOS 27, *) {
                return "Remote control ended because Device Control and Data Access is unavailable"
            }
            return "Remote control ended because Accessibility is unavailable"
        }
        return "Remote control ended because system-reported event posting access is unavailable"
    }

    var diagnosticSummary: String {
        "CG listen=\(canListenToCoreGraphicsEvents ? "yes" : "no"), " +
            "CG post=\(canPostCoreGraphicsEvents ? "yes" : "no"), " +
            "AX trusted=\(accessibilityIsTrusted ? "yes" : "no"), " +
            "IOHID listen (Manager/Device scope)=\(ioHIDListenAccess.rawValue), " +
            "IOHID post (IOHIDPostEvent scope)=\(ioHIDPostAccess.rawValue)"
    }

}

enum IOHIDPermissionSignal: String, Equatable {
    case granted
    case denied
    case unknown
}

struct RemoteInputPermissionCheck: Equatable {
    let accessibilityIsTrusted: Bool
    let canPostCoreGraphicsEvents: Bool

    var isAuthorized: Bool {
        accessibilityIsTrusted && canPostCoreGraphicsEvents
    }
}

protocol RuntimePermissionSnapshotProviding {
    func currentSnapshot() -> RuntimePermissionSnapshot

    /// Rechecks only the APIs needed for remote event injection. This runs on
    /// the serial input queue for each event, so it avoids the diagnostic-only
    /// IOHID calls in `currentSnapshot()`.
    func currentRemoteInputPermission() -> RemoteInputPermissionCheck
}

struct SystemRuntimePermissionSnapshotProvider:
    RuntimePermissionSnapshotProviding {
    func currentSnapshot() -> RuntimePermissionSnapshot {
        RuntimePermissionSnapshot(
            canListenToCoreGraphicsEvents: CGPreflightListenEventAccess(),
            canPostCoreGraphicsEvents: CGPreflightPostEventAccess(),
            accessibilityIsTrusted: AXIsProcessTrusted(),
            ioHIDListenAccess: signal(
                for: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
            ),
            ioHIDPostAccess: signal(
                for: IOHIDCheckAccess(kIOHIDRequestTypePostEvent)
            )
        )
    }

    func currentRemoteInputPermission() -> RemoteInputPermissionCheck {
        RemoteInputPermissionCheck(
            accessibilityIsTrusted: AXIsProcessTrusted(),
            canPostCoreGraphicsEvents: CGPreflightPostEventAccess()
        )
    }

    private func signal(for access: IOHIDAccessType) -> IOHIDPermissionSignal {
        switch access {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        case kIOHIDAccessTypeUnknown:
            return .unknown
        default:
            return .unknown
        }
    }
}

enum RuntimePermissionDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.mackvm.MacKVM",
        category: "permissions"
    )
    private static let lock = NSLock()
    private static var lastSnapshotBySource: [
        String: RuntimePermissionSnapshot
    ] = [:]

    static func log(
        _ snapshot: RuntimePermissionSnapshot,
        source: String
    ) {
        lock.lock()
        let hasChanged = lastSnapshotBySource[source] != snapshot
        if hasChanged {
            lastSnapshotBySource[source] = snapshot
        }
        lock.unlock()

        guard hasChanged else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        logger.info(
            "timestamp=\(timestamp, privacy: .public) phase=permission.snapshot source=\(source, privacy: .public) \(snapshot.diagnosticSummary, privacy: .public)"
        )
    }
}
