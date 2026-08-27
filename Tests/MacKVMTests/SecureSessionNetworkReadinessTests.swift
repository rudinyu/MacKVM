import XCTest
@testable import MacKVM

final class SecureSessionNetworkReadinessTests: XCTestCase {
    func testRecoveryRequiresBothBonjourServicesToBeActuallyReady() {
        XCTAssertFalse(
            SecureSessionService.areNetworkServicesReady(
                listenerPresent: true,
                browserPresent: true,
                listenerReady: true,
                browserReady: false
            )
        )
        XCTAssertFalse(
            SecureSessionService.areNetworkServicesReady(
                listenerPresent: true,
                browserPresent: true,
                listenerReady: false,
                browserReady: true
            )
        )
        XCTAssertTrue(
            SecureSessionService.areNetworkServicesReady(
                listenerPresent: true,
                browserPresent: true,
                listenerReady: true,
                browserReady: true
            )
        )
    }
}
