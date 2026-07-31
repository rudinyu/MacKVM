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

    func testExistingInstallationMigratesItsLocalNetworkAcknowledgement() {
        withDefaults { defaults in
            XCTAssertTrue(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    hadExistingDeviceCredentials: true
                )
            )
            XCTAssertTrue(
                defaults.bool(
                    forKey: OnboardingDefaults.localNetworkAccessReviewedKey
                )
            )
        }
    }

    func testNewInstallationStillRequiresTheLocalNetworkStep() {
        withDefaults { defaults in
            XCTAssertFalse(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    hadExistingDeviceCredentials: false
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
                    hadExistingDeviceCredentials: true
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
                false,
                forKey: OnboardingDefaults.localNetworkAccessReviewedKey
            )

            XCTAssertFalse(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    hadExistingDeviceCredentials: true
                )
            )
        }
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
