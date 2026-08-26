import XCTest
@testable import MacKVM
@testable import MacKVMCore

final class SecureSessionDisconnectPolicyTests: XCTestCase {
    func testCurrentDisconnectCapabilityIsCompatible() {
        XCTAssertEqual(
            SecureSessionCompatibilityPolicy.decision(
                for: SecureSessionHandshake.currentDisconnectSignalVersion
            ),
            .compatible
        )
    }

    func testMissingDisconnectCapabilityRequiresCoordinatedUpgrade() {
        XCTAssertEqual(
            SecureSessionCompatibilityPolicy.decision(for: nil),
            .requiresPeerUpgrade
        )
        XCTAssertEqual(
            SecureSessionCompatibilityPolicy.decision(for: 0),
            .requiresPeerUpgrade
        )
        XCTAssertEqual(
            SecureSessionCompatibilityPolicy.decision(for: 2),
            .requiresPeerUpgrade
        )
    }

    func testPeerRequestedDisconnectSuppressesReconnect() {
        XCTAssertFalse(
            SecureSessionDisconnectPolicy.shouldRetryAfterRemoval(
                removedActiveContext: true,
                localRole: .responder,
                retriesAfterRemoval: false,
                desiredPeerMatches: true,
                hasDesiredPeer: true,
                suppressesReconnect: true
            )
        )
    }

    func testUnexpectedActiveRemovalStillRetries() {
        XCTAssertTrue(
            SecureSessionDisconnectPolicy.shouldRetryAfterRemoval(
                removedActiveContext: true,
                localRole: .responder,
                retriesAfterRemoval: false,
                desiredPeerMatches: true,
                hasDesiredPeer: true,
                suppressesReconnect: false
            )
        )
    }

    func testPendingPreferredIncomingSessionCanRetryWhenItFails() {
        XCTAssertTrue(
            SecureSessionDisconnectPolicy.shouldRetryAfterRemoval(
                removedActiveContext: false,
                localRole: .responder,
                retriesAfterRemoval: true,
                desiredPeerMatches: true,
                hasDesiredPeer: true,
                suppressesReconnect: false
            )
        )
    }

    func testClosingOnePeerDoesNotSuppressAnotherSelectedPeer() {
        XCTAssertTrue(
            SecureSessionDisconnectPolicy.shouldRetryAfterRemoval(
                removedActiveContext: true,
                localRole: .responder,
                retriesAfterRemoval: false,
                desiredPeerMatches: false,
                hasDesiredPeer: true,
                suppressesReconnect: true
            )
        )
    }

    func testDeliberateDisconnectSuppressesReconnectWithNoDesiredPeer() {
        // disconnect() clears the desired peer before the contexts are
        // removed, so the close marker must still suppress recovery even
        // though no peer matches any more.
        XCTAssertFalse(
            SecureSessionDisconnectPolicy.shouldRetryAfterRemoval(
                removedActiveContext: true,
                localRole: .initiator,
                retriesAfterRemoval: false,
                desiredPeerMatches: false,
                hasDesiredPeer: false,
                suppressesReconnect: true
            )
        )
    }
}
