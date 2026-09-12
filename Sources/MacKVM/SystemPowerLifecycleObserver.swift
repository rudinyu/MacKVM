import AppKit
import Foundation

/// Bridges workspace power notifications to a small, testable callback pair.
/// The observer itself owns no session state; SecureSessionService decides how
/// to preserve reconnect intent and tear down active control safely.
final class SystemPowerLifecycleObserver {
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []

    /// The notification center is always supplied by the caller. Defaulting it
    /// to `NSWorkspace.shared.notificationCenter` would evaluate that AppKit
    /// singleton wherever the observer happens to be constructed, which for
    /// `SecureSessionService` is its background session queue.
    init(
        notificationCenter: NotificationCenter,
        onWillSleep: @escaping () -> Void,
        onDidWake: @escaping () -> Void
    ) {
        self.notificationCenter = notificationCenter
        observers = [
            notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: nil
            ) { _ in
                onWillSleep()
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { _ in
                onDidWake()
            }
        ]
    }

    deinit {
        observers.forEach(notificationCenter.removeObserver)
    }
}
