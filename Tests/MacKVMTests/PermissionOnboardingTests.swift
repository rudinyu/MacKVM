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
}
