import Combine
import ServiceManagement

enum LaunchAtLoginStatus {
    static func isRegistered(_ status: SMAppService.Status) -> Bool {
        // `.requiresApproval` means macOS has not enabled the login item yet;
        // it is still registered and must remain unregisterable.
        status == .enabled || status == .requiresApproval
    }

    static func isEnabled(_ status: SMAppService.Status) -> Bool {
        status == .enabled
    }

    static func message(for status: SMAppService.Status) -> String? {
        switch status {
        case .enabled:
            return "MacKVM will start when you log in"
        case .notRegistered, .notFound:
            return "Launch at login is off"
        case .requiresApproval:
            return "Approve MacKVM in System Settings > Login Items"
        @unknown default:
            return nil
        }
    }
}

private struct LaunchAtLoginUpdate: Sendable {
    let status: SMAppService.Status
    let errorMessage: String?
}

private actor LaunchAtLoginService {
    func currentStatus() -> SMAppService.Status {
        SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) -> LaunchAtLoginUpdate {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            return LaunchAtLoginUpdate(
                status: service.status,
                errorMessage: nil
            )
        } catch {
            return LaunchAtLoginUpdate(
                status: service.status,
                errorMessage: error.localizedDescription
            )
        }
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isAwaitingApproval = false
    @Published private(set) var isUpdating = false
    @Published private(set) var status: String?
    private let service = LaunchAtLoginService()
    private var operationID = 0

    init() {
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        operationID += 1
        let currentOperationID = operationID
        isUpdating = true
        status = "Updating Login Items…"

        Task { [weak self] in
            guard let self else { return }
            let update = await service.setEnabled(enabled)
            guard currentOperationID == operationID else { return }
            isUpdating = false
            if let errorMessage = update.errorMessage {
                apply(update.status)
                status = "Could not update Login Items: \(errorMessage)"
            } else {
                apply(update.status)
            }
        }
    }

    func refresh() {
        guard !isUpdating else { return }
        operationID += 1
        let currentOperationID = operationID

        Task { [weak self] in
            guard let self else { return }
            let currentStatus = await service.currentStatus()
            guard currentOperationID == operationID, !isUpdating else { return }
            apply(currentStatus)
        }
    }

    private func apply(_ currentStatus: SMAppService.Status) {
        isEnabled = LaunchAtLoginStatus.isEnabled(currentStatus)
        isAwaitingApproval = currentStatus == .requiresApproval
        status = LaunchAtLoginStatus.message(for: currentStatus)
    }
}
