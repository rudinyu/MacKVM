import Foundation
import UserNotifications

enum ControlRequestNotificationAction: String, CaseIterable {
    case allow = "app.mackvm.control-request.allow"
    case deny = "app.mackvm.control-request.deny"
    case review = "app.mackvm.control-request.review"

    static func action(for identifier: String) -> Self? {
        Self(rawValue: identifier)
    }

    var notificationOptions: UNNotificationActionOptions {
        switch self {
        case .allow:
            // Remote input injection changes the active user's session. Do
            // not let a person at the lock screen approve it without first
            // authenticating as that user.
            [.authenticationRequired]
        case .deny:
            [.destructive]
        case .review:
            // Opening the app exposes the pending remote-control decision;
            // require the active user to authenticate before doing so from a
            // lock-screen notification.
            [.foreground, .authenticationRequired]
        }
    }
}

struct ControlRequestNotificationPayload: Equatable {
    static let requestIDKey = "requestID"
    static let nonceKey = "notificationNonce"

    let requestID: UUID
    let nonce: UUID

    var userInfo: [AnyHashable: Any] {
        [
            Self.requestIDKey: requestID.uuidString,
            Self.nonceKey: nonce.uuidString,
        ]
    }

    static func payload(
        from userInfo: [AnyHashable: Any]
    ) -> ControlRequestNotificationPayload? {
        guard let rawRequestID = userInfo[requestIDKey] as? String,
              let requestID = UUID(uuidString: rawRequestID),
              let rawNonce = userInfo[nonceKey] as? String,
              let nonce = UUID(uuidString: rawNonce) else {
            return nil
        }
        return ControlRequestNotificationPayload(
            requestID: requestID,
            nonce: nonce
        )
    }
}

/// Chooses the delivery route for a pending control request. The menu-bar
/// indicator is always visible while a request is pending, and is the only
/// app-visible fallback when macOS alert delivery is unavailable.
enum ControlRequestNotificationDeliveryDecision: Equatable {
    case nativeNotification
    case menuBarIndicator

    static func resolve(
        authorizationStatus: UNAuthorizationStatus,
        alertSetting: UNNotificationSetting
    ) -> Self {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return alertSetting == .enabled
                ? .nativeNotification : .menuBarIndicator
        case .notDetermined, .denied:
            return .menuBarIndicator
        @unknown default:
            return .menuBarIndicator
        }
    }
}

/// Presents a short-lived native notification for an incoming remote-control
/// request. Each notification carries the request identifier plus a fresh,
/// device-local nonce. The coordinator still verifies the request identifier
/// against its live pending request before it can grant or deny anything.
final class ControlRequestNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let categoryIdentifier = "app.mackvm.control-request"
    private static let notificationIdentifierPrefix =
        "app.mackvm.control-request."

    private let center: UNUserNotificationCenter
    private let stateLock = NSLock()
    private var activeRequest: ControlRequestNotificationPayload?

    var onAction: ((ControlRequestNotificationAction, UUID) -> Void)?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
        registerCategory()
        removeStaleNotificationsFromPreviousLaunch()
    }

    /// Request optional alert permission before the first live control request.
    /// This keeps macOS's authorization sheet out of the 15-second consent
    /// window. Declining alerts never blocks the menu-based Allow/Deny flow.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func present(
        request: IncomingControlRequest,
        peerName: String
    ) {
        let notificationPayload = ControlRequestNotificationPayload(
            requestID: request.id,
            nonce: UUID()
        )
        if let previousRequest = replaceActiveRequest(with: notificationPayload) {
            removeNotification(for: previousRequest)
        }

        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch ControlRequestNotificationDeliveryDecision.resolve(
                authorizationStatus: settings.authorizationStatus,
                alertSetting: settings.alertSetting
            ) {
            case .nativeNotification:
                deliverIfCurrent(
                    request: request,
                    peerName: peerName,
                    notificationPayload: notificationPayload
                )
            case .menuBarIndicator:
                // `MacKVMMenuBarLabel` observes the coordinator's pending
                // request and visibly adds its warning symbol. This works for
                // the LSUIElement menu-bar app, which has no Dock icon to
                // bounce, and does not open a permission sheet mid-request.
                break
            }
        }
    }

    func clearActiveRequest() {
        guard let request = takeActiveRequest() else { return }
        removeNotification(for: request)
    }

    func clearAllControlRequestNotifications() {
        _ = takeActiveRequest()
        removeStoredNotifications(excludingActiveRequest: false)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (
            UNNotificationPresentationOptions
        ) -> Void
    ) {
        guard let notificationPayload = ControlRequestNotificationPayload.payload(
            from: notification.request.content.userInfo
        ), isRequestActive(notificationPayload) else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let notificationPayload = ControlRequestNotificationPayload.payload(
            from: response.notification.request.content.userInfo
        ) else {
            completionHandler()
            return
        }
        let action: ControlRequestNotificationAction?
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            action = .review
        } else {
            action = ControlRequestNotificationAction.action(
                for: response.actionIdentifier
            )
        }
        guard let action else {
            completionHandler()
            return
        }

        // A Review action can synchronously open an NSAlert. Tell macOS that
        // notification handling is complete before entering that modal UI.
        completionHandler()
        DispatchQueue.main.async { [weak self] in
            guard self?.isRequestActive(notificationPayload) == true else {
                return
            }
            self?.onAction?(action, notificationPayload.requestID)
        }
    }

    private func registerCategory() {
        let allow = UNNotificationAction(
            identifier: ControlRequestNotificationAction.allow.rawValue,
            title: String(localized: "Allow"),
            options: ControlRequestNotificationAction.allow.notificationOptions
        )
        let deny = UNNotificationAction(
            identifier: ControlRequestNotificationAction.deny.rawValue,
            title: String(localized: "Deny"),
            options: ControlRequestNotificationAction.deny.notificationOptions
        )
        let review = UNNotificationAction(
            identifier: ControlRequestNotificationAction.review.rawValue,
            title: String(localized: "Review in MacKVM"),
            options: ControlRequestNotificationAction.review.notificationOptions
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [allow, deny, review],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    private func deliverIfCurrent(
        request: IncomingControlRequest,
        peerName: String,
        notificationPayload: ControlRequestNotificationPayload
    ) {
        guard isRequestActive(notificationPayload) else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "MacKVM control request")
        let bodyFormat = String(localized: "%@ wants to control this Mac.")
        content.body = String(format: bodyFormat, peerName)
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = notificationPayload.userInfo
        let notification = UNNotificationRequest(
            identifier: notificationIdentifier(for: notificationPayload),
            content: content,
            trigger: nil
        )
        center.add(notification) { [weak self] error in
            guard let self else { return }
            if error == nil, !self.isRequestActive(notificationPayload) {
                self.removeNotification(for: notificationPayload)
            }
        }
    }

    private func removeNotification(for request: ControlRequestNotificationPayload) {
        let identifier = notificationIdentifier(for: request)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func notificationIdentifier(
        for request: ControlRequestNotificationPayload
    ) -> String {
        "\(Self.notificationIdentifierPrefix)\(request.requestID.uuidString).\(request.nonce.uuidString)"
    }

    private func removeStaleNotificationsFromPreviousLaunch() {
        removeStoredNotifications(excludingActiveRequest: true)
    }

    private func removeStoredNotifications(excludingActiveRequest: Bool) {
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let activeIdentifier = excludingActiveRequest
                ? self.activeNotificationIdentifier() : nil
            let identifiers = requests.map(\.identifier).filter {
                $0.hasPrefix(Self.notificationIdentifierPrefix)
                    && $0 != activeIdentifier
            }
            guard !identifiers.isEmpty else { return }
            self.center.removePendingNotificationRequests(
                withIdentifiers: identifiers
            )
        }
        center.getDeliveredNotifications { [weak self] notifications in
            guard let self else { return }
            let activeIdentifier = excludingActiveRequest
                ? self.activeNotificationIdentifier() : nil
            let identifiers = notifications.map(\.request.identifier).filter {
                $0.hasPrefix(Self.notificationIdentifierPrefix)
                    && $0 != activeIdentifier
            }
            guard !identifiers.isEmpty else { return }
            self.center.removeDeliveredNotifications(
                withIdentifiers: identifiers
            )
        }
    }

    private func replaceActiveRequest(
        with request: ControlRequestNotificationPayload
    ) -> ControlRequestNotificationPayload? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let previousRequest = activeRequest
        activeRequest = request
        return previousRequest
    }

    private func takeActiveRequest() -> ControlRequestNotificationPayload? {
        stateLock.lock()
        defer { stateLock.unlock() }
        let request = activeRequest
        activeRequest = nil
        return request
    }

    private func isRequestActive(
        _ request: ControlRequestNotificationPayload
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeRequest == request
    }

    private func activeNotificationIdentifier() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return activeRequest.map(notificationIdentifier(for:))
    }
}
