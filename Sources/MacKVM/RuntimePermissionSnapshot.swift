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

    /// The outbound controller captures locally and needs Accessibility for
    /// its suppressing event tap. Local event-posting access is not used by
    /// the controller path.
    var canStartOutboundControl: Bool {
        canCaptureInput && accessibilityIsTrusted
    }

    var canInjectRemoteInput: Bool {
        accessibilityIsTrusted
    }

    /// Accessibility can authorize event injection even while Core Graphics
    /// reports a stale posting preflight. The receiver must run the functional
    /// loopback check before granting a session in that state.
    var postAccessLooksStale: Bool {
        accessibilityIsTrusted && !canPostCoreGraphicsEvents
    }

    /// The consuming session tap used for global shortcuts needs listen access
    /// and Accessibility. Carbon registered hotkeys remain the fallback when
    /// tap creation fails.
    var canUseSessionHotKeyTap: Bool {
        canListenToCoreGraphicsEvents
            && accessibilityIsTrusted
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
        if postAccessLooksStale {
            return stalePostingRecoveryStatus
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
        if postAccessLooksStale {
            return stalePostingRecoveryStatus
        }
        return "Accessibility permission is required to control another device"
    }

    var remoteInputPermissionDenialReason: String {
        if !accessibilityIsTrusted {
            if #available(macOS 27, *) {
                return "Denied remote control: Device Control and Data Access permission is missing"
            }
            return "Denied remote control: Accessibility permission is missing"
        }
        if postAccessLooksStale {
            return "Denied remote control: event posting failed functional validation"
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
        return postAccessLooksStale
            ? stalePostingRecoveryStatus
            : "Remote control ended because Accessibility is unavailable"
    }

    private var stalePostingRecoveryStatus: String {
        if #available(macOS 27, *) {
            return "macOS reports event posting as unavailable. Turn MacKVM off and on in Device Control and Data Access, or quit and reopen MacKVM"
        }
        return "macOS reports event posting as unavailable. Turn MacKVM off and on in Accessibility, or quit and reopen MacKVM"
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
        isAuthorized(stalePostingPermissionValidated: false)
    }

    /// A false posting preflight is accepted only for a receiver session that
    /// passed the functional probe before its grant. Accessibility is always
    /// checked again for every event.
    func isAuthorized(stalePostingPermissionValidated: Bool) -> Bool {
        accessibilityIsTrusted
            && (canPostCoreGraphicsEvents || stalePostingPermissionValidated)
    }
}

protocol RuntimePermissionProbeResource: AnyObject {
    func cancel()
}

protocol RuntimePermissionProbeDriver: AnyObject {
    func installListenOnlyTap(
        onEventUserData: @escaping (Int64) -> Void
    ) -> (any RuntimePermissionProbeResource)?
    func postZeroDeltaMouseMove(userData: Int64) -> Bool
    func scheduleTimeout(
        after delay: TimeInterval,
        handler: @escaping () -> Void
    ) -> any RuntimePermissionProbeResource
}

protocol RuntimePermissionProbing: AnyObject {
    func start(
        completion: @escaping (Bool) -> Void
    ) -> any RuntimePermissionProbeResource
}

/// Coordinates a marker-matched loopback event with an injected driver so the
/// timeout, tap lifecycle, and failure paths can be tested without posting a
/// real desktop event.
final class FunctionalRemoteInputPermissionProbe: RuntimePermissionProbing {
    private let driver: any RuntimePermissionProbeDriver
    private let timeout: TimeInterval
    private let marker: () -> Int64

    init(
        driver: any RuntimePermissionProbeDriver,
        timeout: TimeInterval = 0.3,
        marker: @escaping () -> Int64
    ) {
        self.driver = driver
        self.timeout = timeout
        self.marker = marker
    }

    func start(
        completion: @escaping (Bool) -> Void
    ) -> any RuntimePermissionProbeResource {
        let operation = Operation(
            driver: driver,
            marker: marker(),
            timeout: timeout,
            completion: completion
        )
        operation.begin()
        return operation
    }

    private final class Operation: RuntimePermissionProbeResource {
        private let lock = NSLock()
        private let driver: any RuntimePermissionProbeDriver
        private let marker: Int64
        private let timeout: TimeInterval
        private var completion: ((Bool) -> Void)?
        private var tap: (any RuntimePermissionProbeResource)?
        private var timer: (any RuntimePermissionProbeResource)?
        private var isFinished = false

        init(
            driver: any RuntimePermissionProbeDriver,
            marker: Int64,
            timeout: TimeInterval,
            completion: @escaping (Bool) -> Void
        ) {
            self.driver = driver
            self.marker = marker
            self.timeout = timeout
            self.completion = completion
        }

        deinit {
            cancel()
        }

        func begin() {
            guard let tap = driver.installListenOnlyTap(onEventUserData: {
                [weak self] observedUserData in
                guard let self, observedUserData == marker else { return }
                finish(with: true)
            }) else {
                finish(with: false)
                return
            }
            guard keep(tap, as: .tap) else {
                tap.cancel()
                return
            }

            let timer = driver.scheduleTimeout(after: timeout) { [weak self] in
                self?.finish(with: false)
            }
            guard keep(timer, as: .timer) else {
                timer.cancel()
                return
            }

            guard driver.postZeroDeltaMouseMove(userData: marker) else {
                finish(with: false)
                return
            }
        }

        func cancel() {
            finish(with: nil)
        }

        private enum ResourceKind {
            case tap
            case timer
        }

        private func keep(
            _ resource: any RuntimePermissionProbeResource,
            as kind: ResourceKind
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !isFinished else { return false }
            switch kind {
            case .tap:
                tap = resource
            case .timer:
                timer = resource
            }
            return true
        }

        private func finish(with result: Bool?) {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return
            }
            isFinished = true
            let tap = self.tap
            let timer = self.timer
            let completion = self.completion
            self.tap = nil
            self.timer = nil
            self.completion = nil
            lock.unlock()

            timer?.cancel()
            tap?.cancel()
            if let result {
                completion?(result)
            }
        }
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
        logger.notice(
            "timestamp=\(timestamp, privacy: .public) phase=permission.snapshot source=\(source, privacy: .public) \(snapshot.diagnosticSummary, privacy: .public)"
        )
    }
}
