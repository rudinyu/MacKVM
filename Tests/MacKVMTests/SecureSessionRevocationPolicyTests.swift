import XCTest
@testable import MacKVM

final class SecureSessionRevocationPolicyTests: XCTestCase {
    private final class Context {}

    func testOnlyRevokingTheActiveContextClearsPublishedConnection() {
        let active = Context()
        let anonymous = Context()

        XCTAssertTrue(
            SecureSessionRevocationPolicy.removesActiveContext(
                activeContextID: ObjectIdentifier(active),
                revokedContextIDs: [ObjectIdentifier(active), ObjectIdentifier(anonymous)]
            )
        )
        XCTAssertFalse(
            SecureSessionRevocationPolicy.removesActiveContext(
                activeContextID: ObjectIdentifier(active),
                revokedContextIDs: [ObjectIdentifier(anonymous)]
            )
        )
    }
}
