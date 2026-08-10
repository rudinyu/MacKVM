import Foundation
import UserNotifications
import XCTest
@testable import MacKVM

final class ControlRequestNotifierTests: XCTestCase {
    func testDeliveryDecisionUsesNativeNotificationOnlyForEnabledAlerts() {
        let alertAuthorizedStatuses: [UNAuthorizationStatus] = [
            .authorized,
            .provisional,
        ]

        for authorizationStatus in alertAuthorizedStatuses {
            XCTAssertEqual(
                ControlRequestNotificationDeliveryDecision.resolve(
                    authorizationStatus: authorizationStatus,
                    alertSetting: .enabled
                ),
                .nativeNotification
            )
            XCTAssertEqual(
                ControlRequestNotificationDeliveryDecision.resolve(
                    authorizationStatus: authorizationStatus,
                    alertSetting: .disabled
                ),
                .menuBarIndicator
            )
        }
    }

    func testDeliveryDecisionUsesMenuBarIndicatorWithoutAlertAuthorization() {
        for authorizationStatus: UNAuthorizationStatus in [
            .notDetermined,
            .denied,
        ] {
            XCTAssertEqual(
                ControlRequestNotificationDeliveryDecision.resolve(
                    authorizationStatus: authorizationStatus,
                    alertSetting: .enabled
                ),
                .menuBarIndicator
            )
        }
    }

    func testMenuBarStatusAddsAVisibleIndicatorForPendingControlRequest() {
        XCTAssertEqual(
            ControlRequestMenuBarStatus(pendingIncomingControlRequest: nil),
            .ready
        )
        XCTAssertNil(ControlRequestMenuBarStatus.ready.pendingIndicatorSystemImage)

        let pendingRequest = IncomingControlRequest(
            id: UUID(),
            peerID: UUID()
        )
        let pendingStatus = ControlRequestMenuBarStatus(
            pendingIncomingControlRequest: pendingRequest
        )
        XCTAssertEqual(pendingStatus, .pendingControlRequest)
        XCTAssertEqual(
            pendingStatus.pendingIndicatorSystemImage,
            "exclamationmark.circle.fill"
        )
        XCTAssertEqual(
            pendingStatus.accessibilityLabel,
            "MacKVM: incoming control request pending"
        )
    }

    func testNotificationActionsOnlyAcceptKnownIdentifiers() {
        XCTAssertEqual(
            ControlRequestNotificationAction.action(
                for: ControlRequestNotificationAction.allow.rawValue
            ),
            .allow
        )
        XCTAssertEqual(
            ControlRequestNotificationAction.action(
                for: ControlRequestNotificationAction.deny.rawValue
            ),
            .deny
        )
        XCTAssertEqual(
            ControlRequestNotificationAction.action(
                for: ControlRequestNotificationAction.review.rawValue
            ),
            .review
        )
        XCTAssertNil(ControlRequestNotificationAction.action(for: "unknown"))
    }

    func testAllowActionRequiresAuthentication() {
        XCTAssertTrue(
            ControlRequestNotificationAction.allow.notificationOptions.contains(
                .authenticationRequired
            )
        )
        XCTAssertFalse(
            ControlRequestNotificationAction.deny.notificationOptions.contains(
                .authenticationRequired
            )
        )
        XCTAssertTrue(
            ControlRequestNotificationAction.review.notificationOptions.contains(
                .authenticationRequired
            )
        )
    }

    func testPayloadRoundTripsOnlyAValidRequestIdentifierAndNonce() {
        let requestID = UUID()
        let notificationPayload = ControlRequestNotificationPayload(
            requestID: requestID,
            nonce: UUID()
        )

        XCTAssertEqual(
            ControlRequestNotificationPayload.payload(
                from: notificationPayload.userInfo
            ),
            notificationPayload
        )
        XCTAssertNil(
            ControlRequestNotificationPayload.payload(
                from: [
                    ControlRequestNotificationPayload.requestIDKey: "not-a-uuid",
                    ControlRequestNotificationPayload.nonceKey: UUID().uuidString,
                ]
            )
        )
        XCTAssertNil(
            ControlRequestNotificationPayload.payload(
                from: [
                    ControlRequestNotificationPayload.requestIDKey:
                        requestID.uuidString,
                ]
            )
        )
        XCTAssertNil(ControlRequestNotificationPayload.payload(from: [:]))
    }

    func testPayloadNonceMakesReusedRequestIdentifierDistinct() {
        let requestID = UUID()
        let first = ControlRequestNotificationPayload(
            requestID: requestID,
            nonce: UUID()
        )
        let second = ControlRequestNotificationPayload(
            requestID: requestID,
            nonce: UUID()
        )

        XCTAssertNotEqual(first, second)
    }
}
