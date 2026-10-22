import Foundation
import XCTest
@testable import MacKVM

final class PermissionOnboardingTests: XCTestCase {
    func testNoMissingPermissionsWhenBothAreGranted() {
        XCTAssertEqual(
            PermissionOnboardingPolicy.missingPermissions(
                inputMonitoringGranted: true,
                accessibilityGranted: true
            ),
            []
        )
    }

    func testReportsOnlyInputMonitoringWhenItIsMissing() {
        XCTAssertEqual(
            PermissionOnboardingPolicy.missingPermissions(
                inputMonitoringGranted: false,
                accessibilityGranted: true
            ),
            [.inputMonitoring]
        )
    }

    func testReportsOnlyAccessibilityWhenItIsMissing() {
        XCTAssertEqual(
            PermissionOnboardingPolicy.missingPermissions(
                inputMonitoringGranted: true,
                accessibilityGranted: false
            ),
            [.accessibility]
        )
    }

    func testReportsBothMissingPermissionsInSetupOrder() {
        XCTAssertEqual(
            PermissionOnboardingPolicy.missingPermissions(
                inputMonitoringGranted: false,
                accessibilityGranted: false
            ),
            [.inputMonitoring, .accessibility]
        )
    }

    func testInputMonitoringSettingsOpenWhenRequestLeavesPermissionMissing() {
        XCTAssertTrue(
            PermissionOnboardingPolicy
                .shouldOpenInputMonitoringSettingsAfterRequest(
                    for: .inputMonitoring,
                    inputMonitoringGranted: false
                )
        )
    }

    func testInputMonitoringSettingsStayClosedWhenRequestGrantsPermission() {
        XCTAssertFalse(
            PermissionOnboardingPolicy
                .shouldOpenInputMonitoringSettingsAfterRequest(
                    for: .inputMonitoring,
                    inputMonitoringGranted: true
                )
        )
    }

    func testAccessibilityRequestDoesNotOpenInputMonitoringSettings() {
        XCTAssertFalse(
            PermissionOnboardingPolicy
                .shouldOpenInputMonitoringSettingsAfterRequest(
                    for: .accessibility,
                    inputMonitoringGranted: false
                )
        )
    }

    func testAccessibilitySettingsOpenWhenEffectiveInputGateRemainsClosed() {
        XCTAssertTrue(
            PermissionOnboardingPolicy
                .shouldOpenAccessibilitySettingsAfterRequest(
                    for: .accessibility,
                    accessibilityGranted: false
                )
        )
    }

    func testAccessibilitySettingsStayClosedWhenEffectiveInputGateOpens() {
        XCTAssertFalse(
            PermissionOnboardingPolicy
                .shouldOpenAccessibilitySettingsAfterRequest(
                    for: .accessibility,
                    accessibilityGranted: true
                )
        )
    }

    func testInputMonitoringRequestDoesNotOpenAccessibilitySettings() {
        XCTAssertFalse(
            PermissionOnboardingPolicy
                .shouldOpenAccessibilitySettingsAfterRequest(
                    for: .inputMonitoring,
                    accessibilityGranted: false
                )
        )
    }

    func testChecklistStartsWithLocalNetworkAwareness() {
        let state = PermissionOnboardingPolicy.checklistState(
            localNetworkAccessReviewed: false,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        )

        XCTAssertEqual(state.nextPermission, .localNetwork)
        XCTAssertFalse(state.isChecklistComplete)
        XCTAssertFalse(state.isReadyForInputSharing)
        XCTAssertEqual(
            state.checklist,
            [
                PermissionOnboardingChecklistItem(
                    permission: .localNetwork,
                    status: .current
                ),
                PermissionOnboardingChecklistItem(
                    permission: .inputMonitoring,
                    status: .waiting
                ),
                PermissionOnboardingChecklistItem(
                    permission: .accessibility,
                    status: .waiting
                )
            ]
        )
    }

    func testFirstTrackedBuildInvalidatesAnExistingReviewAcknowledgement() {
        withDefaults { defaults in
            defaults.set(
                true,
                forKey: OnboardingDefaults.localNetworkAccessReviewedKey
            )

            XCTAssertFalse(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    hadExistingDeviceCredentials: true,
                    currentBuild: "1.102.03(100)"
                )
            )
            XCTAssertFalse(
                defaults.bool(
                    forKey: OnboardingDefaults.localNetworkAccessReviewedKey
                )
            )
            XCTAssertEqual(
                defaults.string(forKey: OnboardingDefaults.lastExecutedBuildKey),
                "1.102.03(100)"
            )
        }
    }

    func testBuildUpgradeInvalidatesTheLocalNetworkReview() {
        withDefaults { defaults in
            defaults.set(
                "1.102.02(99)",
                forKey: OnboardingDefaults.lastExecutedBuildKey
            )
            defaults.set(
                true,
                forKey: OnboardingDefaults.localNetworkAccessReviewedKey
            )

            XCTAssertFalse(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    hadExistingDeviceCredentials: true,
                    currentBuild: "1.102.03(100)"
                )
            )
            XCTAssertFalse(
                defaults.bool(
                    forKey: OnboardingDefaults.localNetworkAccessReviewedKey
                )
            )
            XCTAssertEqual(
                defaults.string(forKey: OnboardingDefaults.lastExecutedBuildKey),
                "1.102.03(100)"
            )
        }
    }

    func testLegacyReviewMigrationStillWorksAfterBuildTrackingExists() {
        withDefaults { defaults in
            defaults.set(
                "1.102.03(100)",
                forKey: OnboardingDefaults.lastExecutedBuildKey
            )

            XCTAssertTrue(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    hadExistingDeviceCredentials: true,
                    currentBuild: "1.102.03(100)"
                )
            )
        }
    }

    func testNewInstallationStillRequiresTheLocalNetworkStep() {
        withDefaults { defaults in
            XCTAssertFalse(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    hadExistingDeviceCredentials: false,
                    currentBuild: "1.102.03(100)"
                )
            )
            XCTAssertEqual(
                defaults.object(
                    forKey: OnboardingDefaults.localNetworkAccessReviewedKey
                ) as? Bool,
                false
            )
            XCTAssertFalse(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    // Simulates the next launch, after the first launch has
                    // persisted a newly-created device identity.
                    hadExistingDeviceCredentials: true,
                    currentBuild: "1.102.03(100)"
                )
            )
            XCTAssertEqual(
                defaults.object(
                    forKey: OnboardingDefaults.localNetworkAccessReviewedKey
                ) as? Bool,
                false
            )
        }
    }

    func testExplicitLocalNetworkDenialIsNotOverwrittenByMigration() {
        withDefaults { defaults in
            defaults.set(
                "1.102.03(100)",
                forKey: OnboardingDefaults.lastExecutedBuildKey
            )
            defaults.set(
                false,
                forKey: OnboardingDefaults.localNetworkAccessReviewedKey
            )

            XCTAssertFalse(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    hadExistingDeviceCredentials: true,
                    currentBuild: "1.102.03(100)"
                )
            )
        }
    }

    func testExplicitLocalNetworkBlockOutranksOldProbeAndSocketResults() {
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: true,
                isExplicitlyBlocked: true,
                isChecking: true,
                latestCheckResult: .reachable
            ),
            .blocked
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: true,
                isExplicitlyBlocked: true,
                isChecking: false,
                latestCheckResult: .noPeer
            ),
            .blocked
        )
    }

    func testChecklistAdvancesInOrderAfterEachCompletedRequirement() {
        let afterNetworkReview = PermissionOnboardingPolicy.checklistState(
            localNetworkAccessReviewed: true,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        )
        XCTAssertEqual(afterNetworkReview.nextPermission, .inputMonitoring)
        XCTAssertEqual(
            afterNetworkReview.checklist.map(\.status),
            [.complete, .current, .waiting]
        )

        let afterInputMonitoring = PermissionOnboardingPolicy.checklistState(
            localNetworkAccessReviewed: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        )
        XCTAssertEqual(afterInputMonitoring.nextPermission, .accessibility)
        XCTAssertEqual(
            afterInputMonitoring.checklist.map(\.status),
            [.complete, .complete, .current]
        )
    }

    func testChecklistCanBeCompleteWhenAllRequirementsAreSatisfied() {
        let state = PermissionOnboardingPolicy.checklistState(
            localNetworkAccessReviewed: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )

        XCTAssertNil(state.nextPermission)
        XCTAssertTrue(state.isChecklistComplete)
        XCTAssertTrue(state.isReadyForInputSharing)
        XCTAssertEqual(state.checklist.map(\.status), [.complete, .complete, .complete])
    }

    func testInputSharingReadinessDoesNotPretendToVerifyLocalNetworkAccess() {
        let state = PermissionOnboardingPolicy.checklistState(
            localNetworkAccessReviewed: false,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )

        XCTAssertEqual(state.nextPermission, .localNetwork)
        XCTAssertFalse(state.isChecklistComplete)
        XCTAssertTrue(state.isReadyForInputSharing)
    }

    func testOnlyInputMonitoringAndAccessibilityCanBeRequestedInApp() {
        XCTAssertFalse(MacKVMPermission.localNetwork.canRequestInApp)
        XCTAssertTrue(MacKVMPermission.inputMonitoring.canRequestInApp)
        XCTAssertTrue(MacKVMPermission.accessibility.canRequestInApp)
    }

    func testLocalNetworkStatusUsesCurrentEvidenceOnly() {
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: false,
                isExplicitlyBlocked: false,
                isChecking: false,
                latestCheckResult: nil
            ),
            .unverified
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: false,
                isExplicitlyBlocked: true,
                isChecking: false,
                latestCheckResult: nil
            ),
            .blocked
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: false,
                isExplicitlyBlocked: false,
                isChecking: true,
                latestCheckResult: nil
            ),
            .checking
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: true,
                isExplicitlyBlocked: false,
                isChecking: false,
                latestCheckResult: nil
            ),
            .working
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: true,
                isExplicitlyBlocked: true,
                isChecking: false,
                latestCheckResult: nil
            ),
            .blocked
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: true,
                isExplicitlyBlocked: false,
                isChecking: false,
                latestCheckResult: .unconfirmed
            ),
            .unconfirmed
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: false,
                isExplicitlyBlocked: true,
                isChecking: false,
                latestCheckResult: .reachable
            ),
            .blocked
        )
    }

    func testNewAuthenticatedPeerInvalidatesOlderNetworkCheckEvidence() {
        let firstPeer = UUID()
        let secondPeer = UUID()

        XCTAssertTrue(
            LocalNetworkStatusFreshnessPolicy.hasNewAuthenticatedPeer(
                previousPeerID: nil,
                currentPeerID: firstPeer
            )
        )
        XCTAssertFalse(
            LocalNetworkStatusFreshnessPolicy.hasNewAuthenticatedPeer(
                previousPeerID: firstPeer,
                currentPeerID: firstPeer
            )
        )
        XCTAssertTrue(
            LocalNetworkStatusFreshnessPolicy.hasNewAuthenticatedPeer(
                previousPeerID: firstPeer,
                currentPeerID: secondPeer
            )
        )
        XCTAssertFalse(
            LocalNetworkStatusFreshnessPolicy.hasNewAuthenticatedPeer(
                previousPeerID: firstPeer,
                currentPeerID: nil
            )
        )
    }

    @MainActor
    func testVisiblePermissionRefreshContinuesWhileApplicationIsInactive() {
        let scheduler = ManualPermissionRefreshScheduler()
        var refreshCount = 0
        let monitor = PermissionRefreshMonitor(
            interval: 2,
            scheduler: scheduler
        ) {
            refreshCount += 1
        }
        let menuSurface = UUID()
        let windowSurface = UUID()

        monitor.surfaceAppeared(menuSurface)
        monitor.surfaceAppeared(windowSurface)
        XCTAssertTrue(monitor.isPolling)
        XCTAssertEqual(scheduler.activeTimerCount, 1)
        XCTAssertEqual(scheduler.scheduledIntervals, [2])

        monitor.applicationWillResignActive()

        XCTAssertFalse(monitor.applicationIsActive)
        scheduler.fireActiveTimers()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(monitor.isPolling)

        monitor.surfaceDisappeared(menuSurface)
        XCTAssertTrue(monitor.isPolling)
        monitor.surfaceDisappeared(windowSurface)
        XCTAssertFalse(monitor.isPolling)
        XCTAssertEqual(scheduler.activeTimerCount, 0)
    }

    @MainActor
    func testTerminationStopsVisiblePermissionRefresh() {
        let scheduler = ManualPermissionRefreshScheduler()
        var refreshCount = 0
        let monitor = PermissionRefreshMonitor(
            interval: 2,
            scheduler: scheduler
        ) {
            refreshCount += 1
        }
        monitor.surfaceAppeared(UUID())
        XCTAssertTrue(monitor.isPolling)

        monitor.terminate()

        scheduler.fireActiveTimers()
        XCTAssertFalse(monitor.isPolling)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(monitor.visibleSurfaces.isEmpty)
    }

    func testPrivacySettingsURLsCoverEveryChecklistRequirement() {
        XCTAssertEqual(
            PrivacySettings.url(for: .localNetwork)?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        )
        XCTAssertEqual(
            PrivacySettings.url(for: .inputMonitoring)?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        )
        XCTAssertEqual(
            PrivacySettings.url(for: .accessibility)?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "PermissionOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        body(defaults)
    }
}

@MainActor
private final class ManualPermissionRefreshScheduler:
    PermissionRefreshScheduling {
    private(set) var scheduledIntervals: [TimeInterval] = []
    private var timers: [ManualPermissionRefreshTimer] = []

    var activeTimerCount: Int {
        timers.filter(\.isActive).count
    }

    func schedule(
        every interval: TimeInterval,
        action: @escaping () -> Void
    ) -> any PermissionRefreshTimerToken {
        scheduledIntervals.append(interval)
        let timer = ManualPermissionRefreshTimer(action: action)
        timers.append(timer)
        return timer
    }

    func fireActiveTimers() {
        timers.filter(\.isActive).forEach { $0.fire() }
    }
}

@MainActor
private final class ManualPermissionRefreshTimer: PermissionRefreshTimerToken {
    private let action: () -> Void
    private(set) var isActive = true

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func fire() {
        guard isActive else { return }
        action()
    }

    func invalidate() {
        isActive = false
    }
}
