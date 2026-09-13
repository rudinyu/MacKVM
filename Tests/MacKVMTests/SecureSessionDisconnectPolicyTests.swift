import Network
import XCTest
@testable import MacKVM
@testable import MacKVMCore

final class SecureSessionDisconnectPolicyTests: XCTestCase {
    func testSecureTCPParametersEnableIdleConnectionKeepalive() throws {
        let parameters = SecureSessionService.makeSecureTCPParameters()
        let tcpOptions = try XCTUnwrap(
            parameters.defaultProtocolStack.transportProtocol
                as? NWProtocolTCP.Options
        )

        XCTAssertTrue(tcpOptions.enableKeepalive)
        XCTAssertEqual(
            tcpOptions.keepaliveIdle,
            SecureSessionService.secureTCPKeepaliveIdle
        )
        XCTAssertEqual(
            tcpOptions.keepaliveInterval,
            SecureSessionService.secureTCPKeepaliveInterval
        )
        XCTAssertEqual(
            tcpOptions.keepaliveCount,
            SecureSessionService.secureTCPKeepaliveCount
        )
    }

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
            SecureSessionCompatibilityPolicy.decision(for: 1),
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

    // MARK: - TransportLivenessPolicy

    func testAuthenticatedIdleContextSchedulesTheGracePeriod() {
        // The base case this watchdog exists for: an authenticated,
        // otherwise-idle context that just went `.waiting` or non-viable.
        XCTAssertTrue(
            TransportLivenessPolicy.shouldScheduleGracePeriod(
                isAuthenticated: true,
                isClosing: false,
                hasScheduledTimeout: false
            )
        )
    }

    func testHandshakingContextIsExemptFromTheGracePeriod() {
        // A still-handshaking context is covered by its own handshake
        // timeout; the liveness watchdog must not also race it.
        XCTAssertFalse(
            TransportLivenessPolicy.shouldScheduleGracePeriod(
                isAuthenticated: false,
                isClosing: false,
                hasScheduledTimeout: false
            )
        )
    }

    func testClosingContextIsExemptFromTheGracePeriod() {
        // A deliberate close already owns its own bounded flush window
        // (disconnectTransportFlushTimeout); the liveness watchdog must not
        // race it and cancel the socket before the close marker is flushed.
        XCTAssertFalse(
            TransportLivenessPolicy.shouldScheduleGracePeriod(
                isAuthenticated: true,
                isClosing: true,
                hasScheduledTimeout: false
            )
        )
    }

    func testARunningTimerIsNotRestartedByARepeatedSignal() {
        // NWConnection can flap between waiting/non-viable more than once
        // before the first grace period elapses. The clock must anchor to
        // the first loss-of-viability event, not the most recent one.
        XCTAssertFalse(
            TransportLivenessPolicy.shouldScheduleGracePeriod(
                isAuthenticated: true,
                isClosing: false,
                hasScheduledTimeout: true
            )
        )
    }

    func testExpiredGracePeriodFailsAMatchingCurrentAuthenticatedContext() {
        XCTAssertTrue(
            TransportLivenessPolicy.shouldFailAfterGracePeriodExpiry(
                isCurrentContext: true,
                isAuthenticated: true,
                isClosing: false,
                scheduledGeneration: 1,
                expiredGeneration: 1
            )
        )
    }

    func testStaleContextIsNotFailedByAnExpiredTimer() {
        // The context was removed, or a newer epoch superseded it, between
        // scheduling and firing.
        XCTAssertFalse(
            TransportLivenessPolicy.shouldFailAfterGracePeriodExpiry(
                isCurrentContext: false,
                isAuthenticated: true,
                isClosing: false,
                scheduledGeneration: 1,
                expiredGeneration: 1
            )
        )
    }

    func testContextThatStartedClosingIsNotFailedByAnExpiredTimer() {
        // A deliberate disconnect/close began after the timer was scheduled
        // but before it fired; the graceful close path owns teardown now.
        XCTAssertFalse(
            TransportLivenessPolicy.shouldFailAfterGracePeriodExpiry(
                isCurrentContext: true,
                isAuthenticated: true,
                isClosing: true,
                scheduledGeneration: 1,
                expiredGeneration: 1
            )
        )
    }

    func testSupersededGenerationIsNotFailedByAnOlderTimer() {
        // The connection recovered (cancel bumped the generation) and then
        // lost viability again (a new timer, and a new generation, was
        // scheduled) before the original timer's deadline arrived. The
        // original, now-stale timer must be a no-op.
        XCTAssertFalse(
            TransportLivenessPolicy.shouldFailAfterGracePeriodExpiry(
                isCurrentContext: true,
                isAuthenticated: true,
                isClosing: false,
                scheduledGeneration: 2,
                expiredGeneration: 1
            )
        )
    }

    // MARK: - Authenticated heartbeat lease

    func testAuthenticatedSessionSchedulesOneHeartbeatLease() {
        XCTAssertTrue(
            SecureSessionHeartbeatPolicy.shouldSchedule(
                isAuthenticated: true,
                isClosing: false,
                hasScheduledHeartbeat: false,
                awaitingAcknowledgement: false
            )
        )
        XCTAssertFalse(
            SecureSessionHeartbeatPolicy.shouldSchedule(
                isAuthenticated: true,
                isClosing: false,
                hasScheduledHeartbeat: true,
                awaitingAcknowledgement: false
            )
        )
        XCTAssertFalse(
            SecureSessionHeartbeatPolicy.shouldSchedule(
                isAuthenticated: true,
                isClosing: false,
                hasScheduledHeartbeat: false,
                awaitingAcknowledgement: true
            )
        )
    }

    func testHeartbeatLeaseDoesNotStartBeforeAuthenticationOrDuringClose() {
        XCTAssertFalse(
            SecureSessionHeartbeatPolicy.shouldSchedule(
                isAuthenticated: false,
                isClosing: false,
                hasScheduledHeartbeat: false,
                awaitingAcknowledgement: false
            )
        )
        XCTAssertFalse(
            SecureSessionHeartbeatPolicy.shouldSchedule(
                isAuthenticated: true,
                isClosing: true,
                hasScheduledHeartbeat: false,
                awaitingAcknowledgement: false
            )
        )
    }

    func testHeartbeatTimeoutFailsOnlyTheCurrentOutstandingLease() {
        XCTAssertTrue(
            SecureSessionHeartbeatPolicy.shouldFailAfterTimeout(
                isCurrentContext: true,
                isAuthenticated: true,
                isClosing: false,
                awaitingAcknowledgement: true,
                scheduledGeneration: 4,
                expiredGeneration: 4
            )
        )
        XCTAssertFalse(
            SecureSessionHeartbeatPolicy.shouldFailAfterTimeout(
                isCurrentContext: true,
                isAuthenticated: true,
                isClosing: false,
                awaitingAcknowledgement: false,
                scheduledGeneration: 4,
                expiredGeneration: 4
            )
        )
        XCTAssertFalse(
            SecureSessionHeartbeatPolicy.shouldFailAfterTimeout(
                isCurrentContext: true,
                isAuthenticated: true,
                isClosing: false,
                awaitingAcknowledgement: true,
                scheduledGeneration: 5,
                expiredGeneration: 4
            )
        )
    }
}
