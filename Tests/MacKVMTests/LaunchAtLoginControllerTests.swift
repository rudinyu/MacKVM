import ServiceManagement
import XCTest
@testable import MacKVM

final class LaunchAtLoginControllerTests: XCTestCase {
    func testEnabledStatusMessage() {
        XCTAssertTrue(LaunchAtLoginStatus.isRegistered(.enabled))
        XCTAssertEqual(
            LaunchAtLoginStatus.message(for: .enabled),
            "MacKVM will start when you log in"
        )
    }

    func testNotRegisteredStatusMessage() {
        XCTAssertFalse(
            LaunchAtLoginStatus.isRegistered(.notRegistered)
        )
        XCTAssertEqual(
            LaunchAtLoginStatus.message(for: .notRegistered),
            "Launch at login is off"
        )
    }

    func testRequiresApprovalStatusMessage() {
        XCTAssertTrue(
            LaunchAtLoginStatus.isRegistered(.requiresApproval)
        )
        XCTAssertEqual(
            LaunchAtLoginStatus.message(for: .requiresApproval),
            "Approve MacKVM in System Settings > Login Items"
        )
    }

    func testNotFoundStatusMessage() {
        XCTAssertFalse(LaunchAtLoginStatus.isRegistered(.notFound))
        XCTAssertEqual(
            LaunchAtLoginStatus.message(for: .notFound),
            "Launch at login is off"
        )
    }
}
