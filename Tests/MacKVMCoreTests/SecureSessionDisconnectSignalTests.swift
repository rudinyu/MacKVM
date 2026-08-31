import Foundation
import XCTest
@testable import MacKVMCore

final class SecureSessionDisconnectSignalTests: XCTestCase {
    func testDisconnectSignalRequiresAnExactAuthenticatedPayload() {
        XCTAssertTrue(
            SecureSessionControlSignal.isDisconnect(
                SecureSessionControlSignal.disconnect
            )
        )
        XCTAssertFalse(
            SecureSessionControlSignal.isDisconnect(
                Data("MacKVM secure session disconnect v2".utf8)
            )
        )
        XCTAssertFalse(
            SecureSessionControlSignal.isDisconnect(
                Data("MacKVM secure session disconnect v1\0".utf8)
            )
        )
    }

    func testDisconnectAcknowledgementRequiresAnExactAuthenticatedPayload() {
        XCTAssertTrue(
            SecureSessionControlSignal.isDisconnectAcknowledgement(
                SecureSessionControlSignal.disconnectAcknowledgement
            )
        )
        XCTAssertFalse(
            SecureSessionControlSignal.isDisconnectAcknowledgement(
                SecureSessionControlSignal.disconnect
            )
        )
        XCTAssertFalse(
            SecureSessionControlSignal.isDisconnectAcknowledgement(
                Data("MacKVM secure session disconnect acknowledgement v2".utf8)
            )
        )
    }
}
