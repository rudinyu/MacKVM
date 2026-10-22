import Combine
import Foundation
import MacKVMCore
import XCTest
@testable import MacKVM

final class ControlCoordinatorTests: XCTestCase {
    func testAcceptRequiresTheExactPendingRequestID() {
        let fixture = makeFixture()
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()

        XCTAssertEqual(fixture.coordinator.pendingIncomingControlRequest?.id, requestID)

        fixture.coordinator.acceptIncomingControlRequest(UUID())

        XCTAssertEqual(fixture.coordinator.pendingIncomingControlRequest?.id, requestID)
        XCTAssertEqual(fixture.sink.beginCount, 0)
        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertTrue(
            fixture.coordinator.status.contains("expired")
        )

        fixture.coordinator.acceptIncomingControlRequest(requestID)

        XCTAssertNil(fixture.coordinator.pendingIncomingControlRequest)
        XCTAssertTrue(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(fixture.sink.beginCount, 1)
        XCTAssertEqual(
            fixture.transport.sentMessages.last,
            controlMessage(.controlGranted, requestID)
        )
    }

    func testResolvedIncomingRequestCallbackCarriesExactRequestIdentity() {
        let fixture = makeFixture()
        var resolvedRequests: [IncomingControlRequest] = []
        fixture.coordinator.onIncomingControlRequestResolved = {
            resolvedRequests.append($0)
        }
        let requestID = UUID()
        let peerID = fixture.transport.connectedPeerID!

        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.denyIncomingControlRequest(requestID)

        XCTAssertEqual(
            resolvedRequests,
            [IncomingControlRequest(id: requestID, peerID: peerID)]
        )
    }

    func testSeamlessAuthorizationAutomaticallyGrantsControl() {
        let fixture = makeFixture(seamlessControlAuthorized: true)
        let requestID = UUID()

        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()

        XCTAssertNil(fixture.coordinator.pendingIncomingControlRequest)
        XCTAssertTrue(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(fixture.sink.beginCount, 1)
        XCTAssertEqual(
            fixture.transport.sentMessages.last,
            controlMessage(.controlGranted, requestID)
        )
        XCTAssertTrue(
            fixture.coordinator.status.contains("Automatically allowing")
                || fixture.coordinator.status.contains("Remote control granted")
        )
    }

    func testStalePostingProbeGatesManualAndAutomaticAcceptance() {
        let manual = makeFixture()
        manual.sink.requiresFunctionalPermissionProbe = true
        let manualRequestID = UUID()
        manual.transport.deliver(controlMessage(.requestControl, manualRequestID))
        drainMainQueue()
        manual.coordinator.acceptIncomingControlRequest(manualRequestID)

        XCTAssertEqual(manual.permissionProbe.startCount, 1)
        XCTAssertEqual(manual.sink.beginCount, 0)
        XCTAssertFalse(manual.coordinator.isReceivingControl)
        manual.permissionProbe.deliverNext(true)
        drainMainQueue()

        XCTAssertTrue(manual.coordinator.isReceivingControl)
        XCTAssertEqual(manual.sink.beginCount, 1)
        XCTAssertTrue(manual.sink.lastStalePostingPermissionValidated)

        let automatic = makeFixture(seamlessControlAuthorized: true)
        automatic.sink.requiresFunctionalPermissionProbe = true
        let automaticRequestID = UUID()
        automatic.transport.deliver(
            controlMessage(.requestControl, automaticRequestID)
        )
        drainMainQueue()

        XCTAssertEqual(automatic.permissionProbe.startCount, 1)
        XCTAssertEqual(automatic.sink.beginCount, 0)
        XCTAssertFalse(automatic.coordinator.isReceivingControl)
        automatic.permissionProbe.deliverNext(true)
        drainMainQueue()

        XCTAssertTrue(automatic.coordinator.isReceivingControl)
        XCTAssertEqual(automatic.sink.beginCount, 1)
        XCTAssertTrue(automatic.sink.lastStalePostingPermissionValidated)
    }

    func testStalePostingProbeFailureDeniesWithRecoveryMessage() {
        let fixture = makeFixture()
        fixture.sink.requiresFunctionalPermissionProbe = true
        fixture.sink.permissionFailureStatus =
            "macOS reports event posting as unavailable. Turn MacKVM off and on in Accessibility, or quit and reopen MacKVM"
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)
        fixture.permissionProbe.deliverNext(false)
        drainMainQueue()

        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(fixture.sink.beginCount, 0)
        XCTAssertEqual(fixture.coordinator.status, fixture.sink.permissionFailureStatus)
        XCTAssertEqual(
            fixture.transport.sentMessages.last,
            controlMessage(.controlDenied, requestID)
        )
    }

    func testHealthyPermissionPathNeverCallsFunctionalProbe() {
        for seamless in [false, true] {
            let fixture = makeFixture(seamlessControlAuthorized: seamless)
            let requestID = UUID()
            fixture.transport.deliver(controlMessage(.requestControl, requestID))
            drainMainQueue()
            if !seamless {
                fixture.coordinator.acceptIncomingControlRequest(requestID)
            }
            drainMainQueue()

            XCTAssertEqual(fixture.permissionProbe.startCount, 0)
            XCTAssertTrue(fixture.coordinator.isReceivingControl)
        }
    }

    func testLateStalePostingProbePassCannotGrantAfterDisconnect() {
        let fixture = makeFixture()
        fixture.sink.requiresFunctionalPermissionProbe = true
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)
        XCTAssertEqual(fixture.permissionProbe.startCount, 1)

        fixture.transport.disconnect()
        drainMainQueue()
        fixture.permissionProbe.deliverNext(true)
        drainMainQueue()

        XCTAssertGreaterThanOrEqual(fixture.permissionProbe.cancelCount, 1)
        XCTAssertEqual(fixture.sink.beginCount, 0)
        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertFalse(
            fixture.transport.sentMessages.contains {
                $0.kind == .controlGranted && $0.requestID == requestID
            }
        )
    }

    func testForgettingPeerCancelsPendingProbeBeforeTransportDisconnect() {
        let fixture = makeFixture()
        fixture.sink.requiresFunctionalPermissionProbe = true
        let requestID = UUID()
        let peerID = fixture.transport.connectedPeerID!
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)

        fixture.coordinator.cancelIncomingControlRequestForRevokedPeer(peerID)
        fixture.permissionProbe.deliverNext(true)
        drainMainQueue()

        XCTAssertGreaterThanOrEqual(fixture.permissionProbe.cancelCount, 1)
        XCTAssertEqual(fixture.sink.beginCount, 0)
        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertFalse(
            fixture.transport.sentMessages.contains {
                $0.kind == .controlGranted && $0.requestID == requestID
            }
        )
    }

    func testDisconnectAfterProbePassCleansUpLateInputSinkStart() {
        let fixture = makeFixture()
        fixture.sink.requiresFunctionalPermissionProbe = true
        fixture.sink.completesBeginImmediately = false
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)
        fixture.permissionProbe.deliverNext(true)
        drainMainQueue()
        XCTAssertEqual(fixture.sink.beginCount, 1)

        fixture.transport.disconnect()
        drainMainQueue()
        fixture.sink.completeBegin(didStart: true)
        drainMainQueue()

        XCTAssertGreaterThanOrEqual(fixture.sink.endCount, 1)
        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertFalse(
            fixture.transport.sentMessages.contains {
                $0.kind == .controlGranted && $0.requestID == requestID
            }
        )
    }

    func testAccessibilityRevocationCancelsPendingProbeAndLatePassCannotGrant() {
        let fixture = makeFixture()
        fixture.sink.requiresFunctionalPermissionProbe = true
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)

        fixture.sink.hasAccessibilityPermission = false
        fixture.sink.onControlFailure?(.accessibilityPermission)
        drainMainQueue()
        fixture.permissionProbe.deliverNext(true)
        drainMainQueue()

        XCTAssertGreaterThanOrEqual(fixture.permissionProbe.cancelCount, 1)
        XCTAssertEqual(fixture.sink.beginCount, 0)
        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertFalse(
            fixture.transport.sentMessages.contains {
                $0.kind == .controlGranted && $0.requestID == requestID
            }
        )
    }

    func testHealthyPathThatBecomesStaleBeforeGrantIsDenied() {
        let fixture = makeFixture()
        fixture.sink.completesBeginImmediately = false
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)
        XCTAssertEqual(fixture.sink.beginCount, 1)
        XCTAssertEqual(fixture.permissionProbe.startCount, 0)

        fixture.sink.requiresFunctionalPermissionProbe = true
        fixture.sink.completeBegin(didStart: true)
        drainMainQueue()

        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(
            fixture.transport.sentMessages.last,
            controlMessage(.controlDenied, requestID)
        )
    }

    func testHeartbeatAcknowledgementWaitsForInputPathProgress() {
        let fixture = makeFixture(seamlessControlAuthorized: true)
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        XCTAssertTrue(fixture.coordinator.isReceivingControl)

        var acknowledged = false
        let heartbeatAcknowledgement = SecureSessionHeartbeatAcknowledgement {
            acknowledged = true
        }
        fixture.transport.onHeartbeat?(heartbeatAcknowledgement)
        drainMainQueue()

        XCTAssertEqual(fixture.sink.awaitInputProcessingCount, 1)
        XCTAssertFalse(acknowledged)

        fixture.sink.completeNextInputProgress()
        drainMainQueue()

        XCTAssertTrue(acknowledged)
    }

    func testHeartbeatAcknowledgementDoesNotNeedAnInputQueueWhenNotReceiving() {
        let fixture = makeFixture()
        var acknowledged = false
        let heartbeatAcknowledgement = SecureSessionHeartbeatAcknowledgement {
            acknowledged = true
        }

        fixture.transport.onHeartbeat?(heartbeatAcknowledgement)
        drainMainQueue()

        XCTAssertTrue(acknowledged)
        XCTAssertEqual(fixture.sink.awaitInputProcessingCount, 0)
    }

    func testHeartbeatAcknowledgementStaysPendingDuringReceiverTeardown() {
        let fixture = makeFixture(seamlessControlAuthorized: true)
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        XCTAssertTrue(fixture.coordinator.isReceivingControl)

        fixture.sink.completesEndImmediately = false
        fixture.coordinator.endReceivingControl()
        XCTAssertTrue(fixture.coordinator.isRemoteInputTearingDown)

        var acknowledged = false
        let heartbeatAcknowledgement = SecureSessionHeartbeatAcknowledgement {
            acknowledged = true
        }
        fixture.transport.onHeartbeat?(heartbeatAcknowledgement)
        drainMainQueue()

        XCTAssertFalse(acknowledged)
        XCTAssertEqual(fixture.sink.awaitInputProcessingCount, 0)

        fixture.sink.completeNextEnd()
        XCTAssertFalse(fixture.coordinator.isRemoteInputTearingDown)
        XCTAssertTrue(acknowledged)
    }

    func testHeartbeatAcknowledgementQueuedBeforeReceiverTeardownCompletesAfterTeardown() {
        let fixture = makeFixture(seamlessControlAuthorized: true)
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        XCTAssertTrue(fixture.coordinator.isReceivingControl)

        var acknowledged = false
        let heartbeatAcknowledgement = SecureSessionHeartbeatAcknowledgement {
            acknowledged = true
        }
        fixture.transport.onHeartbeat?(heartbeatAcknowledgement)
        drainMainQueue()
        XCTAssertEqual(fixture.sink.awaitInputProcessingCount, 1)

        fixture.sink.completesEndImmediately = false
        fixture.coordinator.endReceivingControl()
        XCTAssertTrue(fixture.coordinator.isRemoteInputTearingDown)

        fixture.sink.completeNextInputProgress(didProgress: false)
        drainMainQueue()
        XCTAssertFalse(acknowledged)

        fixture.sink.completeNextEnd()
        XCTAssertFalse(fixture.coordinator.isRemoteInputTearingDown)
        XCTAssertTrue(acknowledged)
    }

    func testStoppingAWaitingControlRequestRestoresTheLocalRoute() {
        let fixture = makeFixture()
        var routeRestoreCount = 0
        fixture.coordinator.onControllingStopped = {
            routeRestoreCount += 1
        }

        XCTAssertTrue(fixture.coordinator.requestControl())
        XCTAssertEqual(fixture.coordinator.state, .suspended)

        fixture.coordinator.stopControl()

        XCTAssertEqual(routeRestoreCount, 1)
        XCTAssertEqual(fixture.coordinator.state, .connected)
    }

    func testInputPermissionRevocationEndsOutboundControlOnce() throws {
        let fixture = makeFixture()
        XCTAssertTrue(fixture.coordinator.requestControl())
        let requestID = try XCTUnwrap(
            fixture.transport.sentMessages.last?.requestID
        )

        fixture.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()
        XCTAssertEqual(fixture.coordinator.state, .controlling)

        fixture.capture.hasInputMonitoringPermission = false
        fixture.capture.onPermissionRevoked?()

        XCTAssertEqual(fixture.coordinator.state, .connected)
        XCTAssertFalse(fixture.capture.isCapturing)
        XCTAssertEqual(
            fixture.transport.sentMessages.filter { $0.kind == .endControl }.count,
            1
        )
        XCTAssertEqual(fixture.transport.sentMessages.last?.requestID, requestID)
    }

    func testPermissionRevokedDuringCaptureStartDoesNotSendEndControlTwice() throws {
        let fixture = makeFixture()
        var requestCompletion: Bool?
        var controllingStartedCount = 0
        fixture.coordinator.onControllingStarted = {
            controllingStartedCount += 1
        }
        XCTAssertTrue(
            fixture.coordinator.requestControl {
                requestCompletion = $0
            }
        )
        let requestID = try XCTUnwrap(
            fixture.transport.sentMessages.last?.requestID
        )
        fixture.capture.onStartCapture = {
            fixture.capture.hasInputMonitoringPermission = false
            fixture.capture.onPermissionRevoked?()
        }

        fixture.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()

        XCTAssertEqual(fixture.coordinator.state, .connected)
        XCTAssertFalse(fixture.capture.isCapturing)
        XCTAssertGreaterThanOrEqual(fixture.capture.stopCount, 1)
        XCTAssertEqual(
            fixture.transport.sentMessages.filter {
                $0.kind == .endControl && $0.requestID == requestID
            }.count,
            1
        )
        XCTAssertEqual(controllingStartedCount, 0)
        XCTAssertEqual(requestCompletion, false)
    }

    func testSwitchHotKeyStartsControlWhenConnected() {
        let fixture = makeFixture()

        fixture.capture.onSwitchControl?()

        XCTAssertEqual(fixture.coordinator.state, .suspended)
        XCTAssertEqual(fixture.transport.sentMessages.count, 1)
        XCTAssertEqual(
            fixture.transport.sentMessages.first?.kind,
            .requestControl
        )
    }

    func testClipboardSyncRequiresMutualOptInAndStartsOnlyAfterGrant() throws {
        let fixture = makeFixture(clipboardSyncEnabled: true)
        var transitions: [ControlOwnershipTransition] = []
        fixture.coordinator.onOwnershipTransition = {
            transitions.append($0)
        }

        XCTAssertTrue(fixture.coordinator.requestControl())
        let request = try XCTUnwrap(fixture.transport.sentMessages.last)
        XCTAssertEqual(request.kind, .requestControl)
        XCTAssertEqual(request.supportsClipboard, true)
        XCTAssertEqual(request.clipboardEnabled, true)
        XCTAssertEqual(fixture.clipboard.startCount, 0)
        XCTAssertTrue(transitions.isEmpty)

        let requestID = try XCTUnwrap(request.requestID)
        fixture.transport.deliver(
            .controlGranted(requestID: requestID, clipboardEnabled: true)
        )
        drainMainQueue()

        XCTAssertEqual(fixture.coordinator.state, .controlling)
        XCTAssertEqual(fixture.clipboard.startCount, 1)
        XCTAssertEqual(
            transitions,
            [.outboundControl(peerID: fixture.transport.connectedPeerID!)]
        )

        fixture.clipboard.emitLocalText("hello")
        let clipboardMessage = try XCTUnwrap(fixture.transport.sentMessages.last)
        XCTAssertEqual(clipboardMessage.kind, .clipboard)
        XCTAssertEqual(clipboardMessage.requestID, requestID)
        XCTAssertEqual(clipboardMessage.clipboardText, "hello")

        fixture.transport.deliver(
            .clipboard("remote text", requestID: requestID)
        )
        drainMainQueue()
        XCTAssertEqual(fixture.clipboard.receivedTexts, ["remote text"])

        fixture.coordinator.stopControl()
        XCTAssertEqual(fixture.clipboard.stopCount, 1)
        XCTAssertEqual(transitions.last, .returnedLocally)
    }

    func testOwnershipHUDTransitionsOnlyAfterGrantAndReturnShortcuts() throws {
        let fixture = makeFixture()
        var transitions: [ControlOwnershipTransition] = []
        fixture.coordinator.onOwnershipTransition = {
            transitions.append($0)
        }

        fixture.capture.onSwitchControl?()
        XCTAssertTrue(transitions.isEmpty)
        var requestID = try XCTUnwrap(
            fixture.transport.sentMessages.last?.requestID
        )
        fixture.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()
        XCTAssertEqual(
            transitions,
            [.outboundControl(peerID: fixture.transport.connectedPeerID!)]
        )

        // The manual-monitor K shortcut ends an established session and must
        // report the return even though it deliberately leaves the display route alone.
        fixture.capture.onSwitchControl?()
        XCTAssertEqual(transitions.last, .returnedLocally)

        fixture.capture.onSwitchControl?()
        requestID = try XCTUnwrap(
            fixture.transport.sentMessages.last?.requestID
        )
        fixture.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()
        fixture.capture.onEmergencyStop?()

        XCTAssertEqual(
            transitions,
            [
                .outboundControl(peerID: fixture.transport.connectedPeerID!),
                .returnedLocally,
                .outboundControl(peerID: fixture.transport.connectedPeerID!),
                .returnedLocally
            ]
        )
    }

    func testIncomingOwnershipTransitionWaitsForAcceptedControl() throws {
        let fixture = makeFixture(
            seamlessControlAuthorized: false,
            clipboardSyncEnabled: true
        )
        var transitions: [ControlOwnershipTransition] = []
        fixture.coordinator.onOwnershipTransition = {
            transitions.append($0)
        }
        let requestID = UUID()
        let peerID = try XCTUnwrap(fixture.transport.connectedPeerID)
        fixture.transport.deliver(
            ControlMessage.requestControl(
                requestID: requestID,
                clipboardEnabled: true
            )
        )
        drainMainQueue()

        XCTAssertTrue(transitions.isEmpty)
        fixture.coordinator.acceptIncomingControlRequest(requestID)

        XCTAssertEqual(
            transitions,
            [.inboundControl(peerID: peerID)]
        )
        XCTAssertEqual(fixture.clipboard.startCount, 1)
        let grant = try XCTUnwrap(fixture.transport.sentMessages.last)
        XCTAssertEqual(grant.kind, .controlGranted)
        XCTAssertEqual(grant.supportsClipboard, true)
        XCTAssertEqual(grant.clipboardEnabled, true)

        fixture.coordinator.endReceivingControl()
        XCTAssertEqual(transitions.last, .returnedLocally)
        XCTAssertEqual(fixture.clipboard.stopCount, 1)
    }

    func testLegacyPeerCannotNegotiateClipboardOrTriggerClipboardMessages() throws {
        let fixture = makeFixture(
            seamlessControlAuthorized: true,
            clipboardSyncEnabled: true
        )
        let requestID = UUID()
        fixture.transport.deliver(
            ControlMessage(kind: .requestControl, requestID: requestID)
        )
        drainMainQueue()

        XCTAssertTrue(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(fixture.clipboard.startCount, 0)
        let grant = try XCTUnwrap(fixture.transport.sentMessages.last)
        XCTAssertEqual(grant.kind, .controlGranted)
        XCTAssertNil(grant.supportsClipboard)
        XCTAssertNil(grant.clipboardEnabled)

        fixture.clipboard.emitLocalText("private")
        XCTAssertFalse(fixture.transport.sentMessages.contains {
            $0.kind == .clipboard
        })
    }

    func testChangingClipboardPreferenceEndsTheActiveControlSession() throws {
        let fixture = makeFixture(clipboardSyncEnabled: true)
        XCTAssertTrue(fixture.coordinator.requestControl())
        let requestID = try XCTUnwrap(
            fixture.transport.sentMessages.last?.requestID
        )
        fixture.transport.deliver(
            .controlGranted(requestID: requestID, clipboardEnabled: true)
        )
        drainMainQueue()
        XCTAssertEqual(fixture.clipboard.startCount, 1)

        fixture.coordinator.clipboardSyncPreferenceChanged(
            for: fixture.transport.connectedPeerID!
        )

        XCTAssertEqual(fixture.coordinator.state, .connected)
        XCTAssertEqual(fixture.clipboard.stopCount, 1)
        XCTAssertEqual(fixture.transport.sentMessages.last?.kind, .endControl)
    }

    func testChangingClipboardPreferenceEndsIncomingControlSession() {
        let fixture = makeFixture(
            seamlessControlAuthorized: true,
            clipboardSyncEnabled: true
        )
        let peerID = fixture.transport.connectedPeerID!
        fixture.transport.deliver(
            .requestControl(
                requestID: UUID(),
                clipboardEnabled: true
            )
        )
        drainMainQueue()
        XCTAssertTrue(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(fixture.clipboard.startCount, 1)

        fixture.coordinator.clipboardSyncPreferenceChanged(for: peerID)

        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(fixture.clipboard.stopCount, 1)
        XCTAssertEqual(fixture.transport.sentMessages.last?.kind, .endControl)
    }

    func testManualMonitorHotKeyDoesNotStartAutomaticDisplayRoute() {
        let fixture = makeFixture()
        var automaticRouteStartCount = 0
        fixture.coordinator.onControllingStarted = {
            automaticRouteStartCount += 1
        }

        fixture.capture.onSwitchControl?()
        guard let requestID = fixture.transport.sentMessages.first?.requestID
        else {
            XCTFail("manual monitor hotkey did not send a control request")
            return
        }
        fixture.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()

        XCTAssertEqual(fixture.coordinator.state, .controlling)
        XCTAssertEqual(automaticRouteStartCount, 0)
    }

    func testManualMonitorHotKeyStopKeepsTheMonitorRoute() {
        let fixture = makeFixture()
        var routeRestoreCount = 0
        fixture.coordinator.onControllingStopped = {
            routeRestoreCount += 1
        }

        fixture.capture.onSwitchControl?()
        guard let requestID = fixture.transport.sentMessages.first?.requestID
        else {
            XCTFail("manual monitor hotkey did not send a control request")
            return
        }
        fixture.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()
        XCTAssertEqual(fixture.coordinator.state, .controlling)

        // The K session started on a display the user routed manually, so
        // ending it must return input without triggering a DDC switch.
        fixture.capture.onSwitchControl?()

        XCTAssertEqual(fixture.coordinator.state, .connected)
        XCTAssertEqual(routeRestoreCount, 0)
        XCTAssertTrue(
            fixture.transport.sentMessages.contains(
                controlMessage(.endControl, requestID)
            )
        )
    }

    func testInputOnlyRequestOwnershipSkipsRoutesWithoutPreRoutedDisplayFlag() {
        let fixture = makeFixture()
        var displayRoutes = 0
        fixture.coordinator.onControllingStarted = { displayRoutes += 1 }
        fixture.coordinator.onControllingStopped = { displayRoutes += 1 }

        XCTAssertTrue(fixture.coordinator.requestControl(managesDisplayRoute: false))
        let requestID = fixture.transport.sentMessages.last!.requestID!
        fixture.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()
        fixture.coordinator.stopControl()
        XCTAssertEqual(displayRoutes, 0)

        XCTAssertTrue(fixture.coordinator.requestControl(managesDisplayRoute: false))
        fixture.coordinator.stopControl()
        XCTAssertEqual(displayRoutes, 0)
    }

    func testPeerEndingManualMonitorSessionKeepsTheMonitorRoute() {
        let fixture = makeFixture()
        var routeRestoreCount = 0
        fixture.coordinator.onControllingStopped = {
            routeRestoreCount += 1
        }

        fixture.capture.onSwitchControl?()
        guard let requestID = fixture.transport.sentMessages.first?.requestID
        else {
            XCTFail("manual monitor hotkey did not send a control request")
            return
        }
        fixture.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()
        XCTAssertEqual(fixture.coordinator.state, .controlling)

        fixture.transport.deliver(controlMessage(.endControl, requestID))
        drainMainQueue()

        XCTAssertEqual(fixture.coordinator.state, .connected)
        XCTAssertEqual(routeRestoreCount, 0)
    }

    func testTransportDisconnectOfManualMonitorSessionKeepsTheMonitorRoute() {
        let fixture = makeFixture()
        var routeRestoreCount = 0
        fixture.coordinator.onControllingStopped = {
            routeRestoreCount += 1
        }

        fixture.capture.onSwitchControl?()
        guard let requestID = fixture.transport.sentMessages.first?.requestID
        else {
            XCTFail("manual monitor hotkey did not send a control request")
            return
        }
        fixture.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()
        XCTAssertEqual(fixture.coordinator.state, .controlling)

        fixture.transport.connectedPeerID = nil
        drainMainQueue()

        XCTAssertEqual(fixture.coordinator.state, .disconnected)
        XCTAssertEqual(routeRestoreCount, 0)
    }

    func testPairedManualMonitorHotKeyStartAndStopNeverRoutesEitherDisplay() throws {
        let pair = makePairedFixtures()
        var displayRoutes: [String] = []
        pair.controller.coordinator.onControllingStarted = {
            displayRoutes.append("controller-start")
        }
        pair.controller.coordinator.onControllingStopped = {
            displayRoutes.append("controller-stop")
        }
        pair.receiver.coordinator.onReceivingStarted = {
            displayRoutes.append("receiver-start")
        }
        pair.receiver.coordinator.onReceivingStopped = { completion in
            displayRoutes.append("receiver-stop")
            completion()
        }

        let requestID = try startManualControl(pair)
        XCTAssertEqual(pair.controller.transport.sentMessages.first?.managesDisplayRoute, false)
        XCTAssertTrue(pair.controller.capture.isCapturing)
        XCTAssertEqual(pair.receiver.sink.beginCount, 1)

        pair.controller.capture.onSwitchControl?()
        let ended = try XCTUnwrap(pair.controller.transport.sentMessages.last)
        XCTAssertEqual(ended, controlMessage(.endControl, requestID))
        pair.receiver.transport.deliver(ended)
        drainMainQueue()

        XCTAssertEqual(pair.controller.coordinator.state, .connected)
        XCTAssertFalse(pair.controller.capture.isCapturing)
        XCTAssertFalse(pair.receiver.coordinator.isReceivingControl)
        XCTAssertFalse(pair.receiver.coordinator.isRemoteInputTearingDown)
        XCTAssertEqual(pair.receiver.sink.endCount, 1)
        XCTAssertEqual(displayRoutes, [])
    }

    func testPairedReceiverManualHotKeyReturnsInputWithoutDisplayRoutes() throws {
        let pair = makePairedFixtures()
        var receiverRoutes = 0
        var controllerRoutes = 0
        pair.controller.coordinator.onControllingStopped = { controllerRoutes += 1 }
        pair.receiver.coordinator.onReceivingStarted = { receiverRoutes += 1 }
        pair.receiver.coordinator.onReceivingStopped = { completion in
            receiverRoutes += 1
            completion()
        }
        _ = try startManualControl(pair)

        pair.receiver.capture.onSwitchControl?()
        pair.controller.transport.deliver(try XCTUnwrap(pair.receiver.transport.sentMessages.last))
        drainMainQueue()

        XCTAssertEqual(pair.controller.coordinator.state, .connected)
        XCTAssertFalse(pair.receiver.coordinator.isReceivingControl)
        XCTAssertEqual(receiverRoutes, 0)
        XCTAssertEqual(controllerRoutes, 0)
    }

    func testExplicitControllerDisplayReturnAfterManualSessionDoesNotDependOnPeerDDC() throws {
        let pair = makePairedFixtures()
        var localDisplayReturns = 0
        var receiverDisplayRoutes = 0
        pair.controller.coordinator.onControllingStopped = { localDisplayReturns += 1 }
        // These callbacks stand in for a peer with automatic DDC disabled.
        // The explicit controller-side O return must not rely on either one.
        pair.receiver.coordinator.onReceivingStarted = { receiverDisplayRoutes += 1 }
        pair.receiver.coordinator.onReceivingStopped = { completion in
            receiverDisplayRoutes += 1
            completion()
        }
        _ = try startManualControl(pair)

        pair.controller.coordinator.stopControl(
            reason: "Returned display and input to this Mac",
            returnDisplayLocally: true
        )
        pair.receiver.transport.deliver(try XCTUnwrap(pair.controller.transport.sentMessages.last))
        drainMainQueue()

        XCTAssertEqual(pair.controller.coordinator.state, .connected)
        XCTAssertFalse(pair.controller.capture.isCapturing)
        XCTAssertFalse(pair.receiver.coordinator.isReceivingControl)
        XCTAssertEqual(localDisplayReturns, 1)
        XCTAssertEqual(receiverDisplayRoutes, 0)
    }

    func testExplicitReceiverDisplayReturnAfterManualSessionWaitsForInputRelease() throws {
        let pair = makePairedFixtures()
        var order: [String] = []
        pair.receiver.sink.onEndRequested = { order.append("release") }
        pair.receiver.sink.completesEndImmediately = false
        var completeDisplayRoute: (() -> Void)?
        pair.receiver.coordinator.onReceivingStopped = { completion in
            order.append("display")
            completeDisplayRoute = completion
        }
        let requestID = try startManualControl(pair)

        pair.receiver.coordinator.endReceivingControl(
            forceDisplayRouteRestoration: true
        )
        XCTAssertEqual(order, ["release"])
        XCTAssertEqual(pair.receiver.transport.sentMessages.last?.kind, .controlGranted)
        pair.receiver.sink.completeNextEnd()
        XCTAssertEqual(order, ["release", "display"])
        XCTAssertTrue(pair.receiver.coordinator.isRemoteInputTearingDown)
        XCTAssertEqual(pair.receiver.transport.sentMessages.last?.kind, .controlGranted)

        completeDisplayRoute?()
        XCTAssertFalse(pair.receiver.coordinator.isRemoteInputTearingDown)
        XCTAssertEqual(pair.receiver.transport.sentMessages.last, controlMessage(.endControl, requestID))
    }

    func testLegacyIncomingRequestStillRoutesDisplayAtStartAndEnd() {
        let fixture = makeFixture(seamlessControlAuthorized: true)
        var displayRoutes: [String] = []
        fixture.coordinator.onReceivingStarted = { displayRoutes.append("local") }
        fixture.coordinator.onReceivingStopped = { completion in
            displayRoutes.append("remote")
            completion()
        }
        fixture.transport.deliver(controlMessage(.requestControl, UUID()))
        drainMainQueue()

        fixture.coordinator.endReceivingControl()

        XCTAssertEqual(displayRoutes, ["local", "remote"])
    }

    func testSwitchHotKeyReturnsControlLocally() {
        let fixture = makeFixture()
        XCTAssertTrue(fixture.coordinator.requestControl())
        guard let requestID = fixture.transport.sentMessages.first?.requestID
        else {
            XCTFail("requestControl did not send a request")
            return
        }
        fixture.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()

        fixture.capture.onSwitchControl?()

        XCTAssertEqual(fixture.coordinator.state, .connected)
        XCTAssertTrue(
            fixture.transport.sentMessages.contains(
                controlMessage(.endControl, requestID)
            )
        )
    }

    func testStoppingActiveControlRestoresTheLocalRoute() {
        let fixture = makeFixture()
        var routeRestoreCount = 0
        fixture.coordinator.onControllingStopped = {
            routeRestoreCount += 1
        }

        XCTAssertTrue(fixture.coordinator.requestControl())
        guard let requestID = fixture.transport.sentMessages.first?.requestID
        else {
            XCTFail("requestControl did not send a request")
            return
        }
        fixture.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()

        XCTAssertEqual(fixture.coordinator.state, .controlling)
        fixture.coordinator.stopControl(reason: "Returned input to this Mac")

        XCTAssertEqual(routeRestoreCount, 1)
        XCTAssertEqual(fixture.coordinator.state, .connected)
        XCTAssertTrue(
            fixture.transport.sentMessages.contains(
                controlMessage(.endControl, requestID)
            )
        )
    }

    func testPreRoutedControlSkipsDuplicateStartRouteButRestoresOnStop() {
        let fixture = makeFixture()
        var routeStartCount = 0
        var routeRestoreCount = 0
        fixture.coordinator.onControllingStarted = {
            routeStartCount += 1
        }
        fixture.coordinator.onControllingStopped = {
            routeRestoreCount += 1
        }

        XCTAssertTrue(
            fixture.coordinator.requestControl(displayAlreadyRemote: true)
        )
        guard let requestID = fixture.transport.sentMessages.first?.requestID
        else {
            XCTFail("requestControl did not send a request")
            return
        }
        fixture.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()

        XCTAssertEqual(fixture.coordinator.state, .controlling)
        XCTAssertEqual(routeStartCount, 0)

        fixture.coordinator.stopControl()

        XCTAssertEqual(routeRestoreCount, 1)
        XCTAssertEqual(fixture.coordinator.state, .connected)
    }

    func testCancellingPreRoutedWaitingControlUsesRequestCompletionForRestore() {
        let fixture = makeFixture()
        var routeRestoreCount = 0
        var completionResult: Bool?
        fixture.coordinator.onControllingStopped = {
            routeRestoreCount += 1
        }

        XCTAssertTrue(
            fixture.coordinator.requestControl(displayAlreadyRemote: true) {
                completionResult = $0
            }
        )

        fixture.coordinator.stopControl()

        XCTAssertEqual(completionResult, false)
        XCTAssertEqual(routeRestoreCount, 0)
        XCTAssertEqual(fixture.coordinator.state, .connected)
    }

    /// A differing keyboard layout used to be denied here, before the
    /// consent prompt. RemoteInputSink now resolves each remappable key to
    /// its local equivalent instead, so admission no longer depends on the
    /// two layouts matching.
    func testMismatchedKeyboardLayoutNoLongerBlocksConsentPrompt() {
        let fixture = makeFixture(
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )
        let requestID = UUID()
        fixture.transport.deliver(
            ControlMessage.requestControl(
                requestID: requestID,
                keyboardLayoutIdentifier: "com.apple.keylayout.ABC"
            )
        )
        drainMainQueue()

        XCTAssertEqual(
            fixture.coordinator.pendingIncomingControlRequest?.id,
            requestID
        )
        XCTAssertFalse(
            fixture.transport.sentMessages.contains(
                controlMessage(.controlDenied, requestID)
            )
        )
    }

    /// A v1 peer never sends the RemoteInputEvent.character field remapping
    /// needs, so admitting it under a differing layout would only grant
    /// control to end it on the first remappable keystroke. Denying it here
    /// instead, before the consent prompt, is the one case where a layout
    /// mismatch is still denied outright.
    func testMismatchedKeyboardLayoutFromLegacyPeerIsDeniedBeforeConsentPrompt() {
        let fixture = makeFixture(
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )
        let requestID = UUID()
        fixture.transport.deliver(
            ControlMessage(
                kind: .requestControl,
                requestID: requestID,
                protocolVersion: 1,
                minimumProtocolVersion: 1,
                keyboardLayoutIdentifier: "com.apple.keylayout.ABC"
            )
        )
        drainMainQueue()

        XCTAssertNil(fixture.coordinator.pendingIncomingControlRequest)
        XCTAssertTrue(
            fixture.transport.sentMessages.contains(
                controlMessage(.controlDenied, requestID)
            )
        )
        XCTAssertTrue(fixture.coordinator.status.contains("keyboard layout"))
    }

    /// The legacy-peer gate above is specifically about a *differing*
    /// layout, not about the peer's version by itself: a v1 peer with a
    /// matching layout has nothing to remap and must be admitted normally.
    func testMatchingKeyboardLayoutFromLegacyPeerIsNotDenied() {
        let fixture = makeFixture(
            keyboardLayoutIdentifier: "com.apple.keylayout.US"
        )
        let requestID = UUID()
        fixture.transport.deliver(
            ControlMessage(
                kind: .requestControl,
                requestID: requestID,
                protocolVersion: 1,
                minimumProtocolVersion: 1,
                keyboardLayoutIdentifier: "com.apple.keylayout.US"
            )
        )
        drainMainQueue()

        XCTAssertEqual(
            fixture.coordinator.pendingIncomingControlRequest?.id,
            requestID
        )
    }

    func testInboundAdmissionOverflowDisconnectsTransport() {
        let fixture = makeFixture()

        for _ in 0...256 {
            fixture.transport.deliver(
                controlMessage(.endControl, UUID())
            )
        }

        XCTAssertEqual(fixture.transport.disconnectCount, 1)
    }

    func testAuthenticatedPayloadIsAdmittedBeforeConnectionPublisherRuns() {
        let fixture = makeFixture()
        let requestID = UUID()
        let peerID = fixture.transport.connectedPeerID!

        fixture.transport.connectedPeerID = nil
        drainMainQueue()
        fixture.transport.connectedPeerID = peerID
        fixture.transport.onAuthenticated?()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()

        XCTAssertEqual(
            fixture.coordinator.pendingIncomingControlRequest?.id,
            requestID
        )
    }

    func testReauthenticationKeepsPayloadAcrossAStaleDisconnectPublication() {
        let fixture = makeFixture()
        let requestID = UUID()
        let peerID = fixture.transport.connectedPeerID!

        fixture.transport.connectedPeerID = nil
        fixture.transport.onAuthenticated?()
        fixture.transport.connectedPeerID = peerID
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()

        XCTAssertEqual(
            fixture.coordinator.pendingIncomingControlRequest?.id,
            requestID
        )
    }

    func testAuthenticationBeatsTheInitialNilPublisherValue() {
        let fixture = makeFixture(initiallyConnected: false)
        let peerID = UUID()
        let requestID = UUID()

        fixture.transport.onAuthenticated?()
        fixture.transport.connectedPeerID = peerID
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()

        XCTAssertEqual(
            fixture.coordinator.pendingIncomingControlRequest?.id,
            requestID
        )
    }

    func testStaleConnectionPublicationCannotInvalidateANewAuthentication() {
        let fixture = makeFixture()
        let peerID = fixture.transport.connectedPeerID!
        let requestID = UUID()

        let firstGeneration = fixture.transport.onAuthenticated?() ?? 0
        fixture.transport.setConnection(
            peerID,
            admissionGeneration: firstGeneration
        )
        fixture.transport.setConnection(
            nil,
            admissionGeneration: firstGeneration
        )
        let secondGeneration = fixture.transport.onAuthenticated?() ?? 0
        fixture.transport.setConnection(
            peerID,
            admissionGeneration: secondGeneration
        )
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()

        XCTAssertEqual(
            fixture.coordinator.pendingIncomingControlRequest?.id,
            requestID
        )

        fixture.transport.setConnection(
            nil,
            admissionGeneration: secondGeneration
        )
        fixture.transport.deliver(
            controlMessage(.requestControl, UUID())
        )
        drainMainQueue()

        XCTAssertNil(fixture.coordinator.pendingIncomingControlRequest)
    }

    func testSamePeerReconnectEndsActiveControlAndRejectsOldInput() {
        let fixture = makeFixture()
        let peerID = fixture.transport.connectedPeerID!
        let firstGeneration = fixture.transport.onAuthenticated?() ?? 0
        fixture.transport.setConnection(
            peerID,
            admissionGeneration: firstGeneration
        )
        drainMainQueue()
        fixture.sink.resetActivity()

        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)

        XCTAssertTrue(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(fixture.sink.beginCount, 1)

        fixture.transport.setConnection(
            nil,
            admissionGeneration: firstGeneration
        )
        let secondGeneration = fixture.transport.onAuthenticated?() ?? 0
        fixture.transport.setConnection(
            peerID,
            admissionGeneration: secondGeneration
        )
        drainMainQueue()

        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(fixture.sink.endCount, 1)

        fixture.transport.deliver(
            ControlMessage.input(
                RemoteInputEvent(
                    kind: .mouseMoved,
                    location: NormalizedPoint(x: 0.25, y: 0.25)
                ),
                requestID: requestID
            )
        )
        drainMainQueue()

        XCTAssertEqual(fixture.sink.receiveCount, 0)

        fixture.capture.onSwitchControl?()

        XCTAssertEqual(fixture.coordinator.state, .suspended)
        XCTAssertEqual(
            fixture.transport.sentMessages.last?.kind,
            .requestControl
        )
    }

    func testInputQueueFailureUsesAResourceReason() {
        let fixture = makeFixture()
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)

        fixture.sink.onControlFailure?(.queueOverloaded)

        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertTrue(fixture.coordinator.status.contains("input queue"))
    }

    func testStaleActionForPreviousRequestCannotAffectReplacement() {
        let fixture = makeFixture()
        let firstRequestID = UUID()
        let secondRequestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, firstRequestID))
        drainMainQueue()

        fixture.coordinator.denyIncomingControlRequest(firstRequestID)
        fixture.transport.deliver(controlMessage(.requestControl, secondRequestID))
        drainMainQueue()
        let responseCountBeforeStaleAction = fixture.transport.sentMessages.count

        fixture.coordinator.acceptIncomingControlRequest(firstRequestID)
        fixture.coordinator.denyIncomingControlRequest(firstRequestID)

        XCTAssertEqual(
            fixture.coordinator.pendingIncomingControlRequest?.id,
            secondRequestID
        )
        XCTAssertEqual(fixture.sink.beginCount, 0)
        XCTAssertEqual(
            fixture.transport.sentMessages.count,
            responseCountBeforeStaleAction
        )
    }

    func testStalePeerEndCannotStopTheCurrentReceiver() {
        let fixture = makeFixture()
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)
        XCTAssertTrue(fixture.coordinator.isReceivingControl)

        fixture.sink.completesEndImmediately = false
        fixture.transport.deliver(controlMessage(.endControl, UUID()))
        drainMainQueue()

        XCTAssertTrue(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(fixture.sink.endCount, 0)

        fixture.transport.deliver(controlMessage(.endControl, requestID))
        drainMainQueue()

        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(fixture.sink.endCount, 1)
        fixture.sink.completeNextEnd()
    }

    func testReceiverStopReleasesInputBeforeMonitorRouteAndPeerNotification() {
        let fixture = makeFixture()
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)
        fixture.sink.completesEndImmediately = false
        var order: [String] = []
        fixture.sink.onEndRequested = { order.append("release") }
        fixture.coordinator.onReceivingStopped = { completion in
            order.append("monitor")
            completion()
        }

        fixture.coordinator.endReceivingControl()

        XCTAssertEqual(order, ["release"])
        XCTAssertFalse(
            fixture.transport.sentMessages.contains(
                controlMessage(.endControl, requestID)
            )
        )

        fixture.sink.completeNextEnd()

        XCTAssertEqual(order, ["release", "monitor"])
        XCTAssertTrue(
            fixture.transport.sentMessages.contains(
                controlMessage(.endControl, requestID)
            )
        )
    }

    func testReceiverTeardownBlocksNewSessionsUntilInputReleaseCompletes() {
        let fixture = makeFixture()
        let firstRequestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, firstRequestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(firstRequestID)
        fixture.sink.completesEndImmediately = false

        fixture.coordinator.endReceivingControl()

        XCTAssertTrue(fixture.coordinator.isRemoteInputTearingDown)
        XCTAssertFalse(fixture.coordinator.isReceivingControl)

        XCTAssertFalse(fixture.coordinator.requestControl())
        XCTAssertEqual(fixture.coordinator.state, .connected)

        let secondRequestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, secondRequestID))
        drainMainQueue()

        XCTAssertNil(fixture.coordinator.pendingIncomingControlRequest)
        XCTAssertTrue(
            fixture.transport.sentMessages.contains(
                controlMessage(.controlDenied, secondRequestID)
            )
        )

        fixture.sink.completeNextEnd()

        XCTAssertFalse(fixture.coordinator.isRemoteInputTearingDown)
        fixture.coordinator.requestControl()
        XCTAssertEqual(fixture.coordinator.state, .suspended)
    }

    func testReceiverTeardownBlocksNewSessionsUntilMonitorRouteCompletes() {
        let fixture = makeFixture()
        let firstRequestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, firstRequestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(firstRequestID)
        var completeMonitorRoute: (() -> Void)?
        fixture.coordinator.onReceivingStopped = { completion in
            completeMonitorRoute = completion
        }

        fixture.coordinator.endReceivingControl()

        XCTAssertTrue(fixture.coordinator.isRemoteInputTearingDown)
        XCTAssertNotNil(completeMonitorRoute)

        fixture.coordinator.requestControl()
        XCTAssertEqual(fixture.coordinator.state, .connected)

        let secondRequestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, secondRequestID))
        drainMainQueue()
        XCTAssertTrue(
            fixture.transport.sentMessages.contains(
                controlMessage(.controlDenied, secondRequestID)
            )
        )

        completeMonitorRoute?()

        XCTAssertFalse(fixture.coordinator.isRemoteInputTearingDown)
        fixture.coordinator.requestControl()
        XCTAssertEqual(fixture.coordinator.state, .suspended)
    }

    func testLocalMonitorReturnWaitsForReceiverTeardownRoute() {
        let fixture = makeFixture()
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)

        var completeMonitorRoute: (() -> Void)?
        fixture.coordinator.onReceivingStopped = { completion in
            completeMonitorRoute = completion
        }
        fixture.coordinator.endReceivingControl()

        var localReturnCount = 0
        fixture.coordinator.requestLocalMonitorReturn {
            localReturnCount += 1
        }

        XCTAssertTrue(fixture.coordinator.isRemoteInputTearingDown)
        XCTAssertEqual(localReturnCount, 0)
        completeMonitorRoute?()

        XCTAssertFalse(fixture.coordinator.isRemoteInputTearingDown)
        XCTAssertEqual(localReturnCount, 1)
    }

    func testDuplicateDisconnectPreservesReceiverMonitorRestoration() {
        let fixture = makeFixture()
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)
        fixture.sink.completesEndImmediately = false
        var completeMonitorRoute: (() -> Void)?
        var monitorRouteCount = 0
        fixture.coordinator.onReceivingStopped = { completion in
            monitorRouteCount += 1
            completeMonitorRoute = completion
        }

        fixture.transport.connectedPeerID = nil
        drainMainQueue()
        fixture.transport.connectedPeerID = nil
        drainMainQueue()

        XCTAssertTrue(fixture.coordinator.isRemoteInputTearingDown)
        XCTAssertEqual(fixture.sink.endCount, 1)

        fixture.sink.completeNextEnd()

        XCTAssertEqual(monitorRouteCount, 1)
        XCTAssertNotNil(completeMonitorRoute)
        completeMonitorRoute?()
        XCTAssertFalse(fixture.coordinator.isRemoteInputTearingDown)
    }

    func testQuitWaitsForAnExistingReceiverTeardown() {
        let fixture = makeFixture()
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)
        fixture.sink.completesEndImmediately = false
        var receiverStopCount = 0
        var quitCompletionCount = 0
        fixture.coordinator.onReceivingStopped = { completion in
            receiverStopCount += 1
            completion()
        }

        fixture.coordinator.endReceivingControl()
        fixture.coordinator.stopForQuit { quitCompletionCount += 1 }

        XCTAssertEqual(fixture.sink.endCount, 1)
        XCTAssertEqual(quitCompletionCount, 0)

        fixture.sink.completeNextEnd()

        XCTAssertEqual(receiverStopCount, 0)
        XCTAssertEqual(quitCompletionCount, 1)
        XCTAssertTrue(
            fixture.transport.sentMessages.contains(
                controlMessage(.endControl, requestID)
            )
        )
    }

    func testQuitWaitsForAnInFlightMonitorRestore() {
        let fixture = makeFixture()
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)
        var completeMonitorRoute: (() -> Void)?
        var quitCompletionCount = 0
        fixture.coordinator.onReceivingStopped = { completion in
            completeMonitorRoute = completion
        }

        fixture.coordinator.endReceivingControl()
        fixture.coordinator.stopForQuit { quitCompletionCount += 1 }

        XCTAssertTrue(fixture.coordinator.isRemoteInputTearingDown)
        XCTAssertEqual(quitCompletionCount, 0)
        XCTAssertEqual(fixture.sink.endCount, 1)

        completeMonitorRoute?()

        XCTAssertFalse(fixture.coordinator.isRemoteInputTearingDown)
        XCTAssertEqual(quitCompletionCount, 1)
        XCTAssertEqual(fixture.sink.endCount, 1)
        XCTAssertTrue(
            fixture.transport.sentMessages.contains(
                controlMessage(.endControl, requestID)
            )
        )
    }

    func testTerminationDisplayRouteUsesTheOwnedControllerSession() throws {
        let fixture = makeFixture()
        XCTAssertNil(fixture.coordinator.displayRouteRoleForTermination)

        XCTAssertTrue(fixture.coordinator.requestControl())
        let requestID = try XCTUnwrap(
            fixture.transport.sentMessages.last?.requestID
        )
        fixture.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()

        XCTAssertEqual(
            fixture.coordinator.displayRouteRoleForTermination,
            .local
        )
        var quitCompleted = false
        fixture.coordinator.stopForQuit { quitCompleted = true }

        XCTAssertTrue(quitCompleted)
        XCTAssertFalse(fixture.capture.isCapturing)
        XCTAssertNil(fixture.coordinator.displayRouteRoleForTermination)
    }

    func testTerminationDisplayRouteKeepsManualAndNotYetRoutedControlLocal() {
        let waiting = makeFixture()
        XCTAssertTrue(waiting.coordinator.requestControl())
        XCTAssertNil(waiting.coordinator.displayRouteRoleForTermination)

        let manual = makeFixture()
        XCTAssertTrue(
            manual.coordinator.requestControl(
                displayAlreadyRemote: true,
                managesDisplayRoute: false
            )
        )
        let requestID = manual.transport.sentMessages.last!.requestID!
        manual.transport.deliver(controlMessage(.controlGranted, requestID))
        drainMainQueue()

        XCTAssertNil(manual.coordinator.displayRouteRoleForTermination)

        let receiverManual = makeFixture()
        let receiverManualRequestID = UUID()
        receiverManual.transport.deliver(
            ControlMessage.requestControl(
                requestID: receiverManualRequestID,
                managesDisplayRoute: false
            )
        )
        drainMainQueue()
        receiverManual.coordinator.acceptIncomingControlRequest(
            receiverManualRequestID
        )

        XCTAssertNil(
            receiverManual.coordinator.displayRouteRoleForTermination
        )
    }

    func testTerminationDisplayRoutePreservesExplicitManualReceiverReturn() throws {
        let fixture = makeFixture()
        let requestID = UUID()
        fixture.transport.deliver(
            ControlMessage.requestControl(
                requestID: requestID,
                managesDisplayRoute: false
            )
        )
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)
        fixture.sink.completesEndImmediately = false
        var receiverRouteCount = 0
        var quitCompletionCount = 0
        fixture.coordinator.onReceivingStopped = { completion in
            receiverRouteCount += 1
            completion()
        }

        fixture.coordinator.endReceivingControl(
            forceDisplayRouteRestoration: true
        )

        XCTAssertTrue(fixture.coordinator.isRemoteInputTearingDown)
        XCTAssertEqual(
            fixture.coordinator.displayRouteRoleForTermination,
            .remote
        )
        let terminationRoute = fixture.coordinator.displayRouteRoleForTermination
        fixture.coordinator.stopForQuit { quitCompletionCount += 1 }

        XCTAssertEqual(terminationRoute, .remote)
        XCTAssertNil(fixture.coordinator.displayRouteRoleForTermination)
        XCTAssertEqual(quitCompletionCount, 0)
        fixture.sink.completeNextEnd()

        XCTAssertEqual(receiverRouteCount, 0)
        XCTAssertEqual(quitCompletionCount, 1)
    }

    func testTerminationDisplayRouteReturnsLocalForAnOwnedPreRoutedRequest() {
        let fixture = makeFixture()
        XCTAssertTrue(
            fixture.coordinator.requestControl(displayAlreadyRemote: true)
        )

        XCTAssertEqual(
            fixture.coordinator.displayRouteRoleForTermination,
            .local
        )
    }

    func testQuitFromReceiverNeverRequestsTheRemoteMonitorRoute() {
        let fixture = makeFixture()
        let requestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()
        fixture.coordinator.acceptIncomingControlRequest(requestID)
        fixture.sink.completesEndImmediately = false
        var receiverStopCount = 0
        var quitCompletionCount = 0
        fixture.coordinator.onReceivingStopped = { completion in
            receiverStopCount += 1
            completion()
        }

        XCTAssertEqual(
            fixture.coordinator.displayRouteRoleForTermination,
            .remote
        )

        fixture.coordinator.stopForQuit { quitCompletionCount += 1 }

        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(
            fixture.coordinator.displayRouteRoleForTermination,
            .remote
        )
        XCTAssertEqual(receiverStopCount, 0)
        XCTAssertEqual(quitCompletionCount, 0)
        XCTAssertEqual(fixture.sink.endCount, 1)

        fixture.sink.completeNextEnd()

        XCTAssertEqual(receiverStopCount, 0)
        XCTAssertEqual(quitCompletionCount, 1)
        XCTAssertNil(fixture.coordinator.displayRouteRoleForTermination)
        XCTAssertTrue(
            fixture.transport.sentMessages.contains(
                controlMessage(.endControl, requestID)
            )
        )

        fixture.coordinator.stopForQuit { quitCompletionCount += 1 }
        XCTAssertEqual(quitCompletionCount, 1)
    }

    func testQuitDuringDeferredAcceptanceCannotResurrectReceivingSession() {
        let fixture = makeFixture()
        let requestID = UUID()
        fixture.sink.completesBeginImmediately = false
        fixture.transport.deliver(controlMessage(.requestControl, requestID))
        drainMainQueue()

        fixture.coordinator.acceptIncomingControlRequest(requestID)
        XCTAssertEqual(fixture.sink.beginCount, 1)
        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertNil(fixture.coordinator.displayRouteRoleForTermination)

        var quitCompletionCount = 0
        fixture.coordinator.stopForQuit { quitCompletionCount += 1 }
        fixture.sink.completeBegin(didStart: true)

        XCTAssertEqual(quitCompletionCount, 1)
        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertTrue(
            fixture.transport.sentMessages.contains(
                controlMessage(.controlDenied, requestID)
            )
        )
        XCTAssertFalse(
            fixture.transport.sentMessages.contains(
                controlMessage(.controlGranted, requestID)
            )
        )
    }

    func testSimultaneousRequestKeepsLocalWhenLocalIDWins() {
        let localID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let remoteID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let fixture = makeFixture(localID: localID, remoteID: remoteID)

        fixture.coordinator.requestControl()
        XCTAssertEqual(fixture.coordinator.state, .suspended)
        let incomingRequestID = UUID()
        fixture.transport.deliver(controlMessage(.requestControl, incomingRequestID))
        drainMainQueue()

        XCTAssertEqual(fixture.coordinator.state, .suspended)
        XCTAssertNil(fixture.coordinator.pendingIncomingControlRequest)
        XCTAssertTrue(
            fixture.transport.sentMessages.contains(
                controlMessage(.controlDenied, incomingRequestID)
            )
        )
    }

    func testControllingMacNeedsInputMonitoringAndAccessibility() {
        let fixture = makeFixture()
        fixture.sink.hasAccessibilityPermission = false

        XCTAssertFalse(fixture.coordinator.requestControl())

        XCTAssertEqual(fixture.coordinator.state, .connected)
        XCTAssertTrue(fixture.transport.sentMessages.isEmpty)
        XCTAssertTrue(
            fixture.coordinator.status.contains("Accessibility")
        )
    }

    func testControlRequestCompletionReportsRemoteDenial() {
        let fixture = makeFixture()
        var outcomes: [Bool] = []

        XCTAssertTrue(
            fixture.coordinator.requestControl { outcomes.append($0) }
        )
        guard let requestID = fixture.transport.sentMessages.first?.requestID
        else {
            XCTFail("requestControl did not send a request")
            return
        }

        fixture.transport.deliver(controlMessage(.controlDenied, requestID))
        drainMainQueue()

        XCTAssertEqual(outcomes, [false])
        XCTAssertEqual(fixture.coordinator.state, .connected)
    }

    private func makePairedFixtures() -> (controller: Fixture, receiver: Fixture) {
        let controllerID = UUID()
        let receiverID = UUID()
        return (
            makeFixture(localID: controllerID, remoteID: receiverID),
            makeFixture(
                localID: receiverID,
                remoteID: controllerID,
                seamlessControlAuthorized: true
            )
        )
    }

    private func startManualControl(
        _ pair: (controller: Fixture, receiver: Fixture),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UUID {
        pair.controller.capture.onSwitchControl?()
        let request = try XCTUnwrap(pair.controller.transport.sentMessages.last, file: file, line: line)
        pair.receiver.transport.deliver(request)
        drainMainQueue(file: file, line: line)
        XCTAssertTrue(pair.receiver.coordinator.isReceivingControl, file: file, line: line)
        let grant = try XCTUnwrap(pair.receiver.transport.sentMessages.last, file: file, line: line)
        XCTAssertEqual(grant.kind, .controlGranted, file: file, line: line)
        pair.controller.transport.deliver(grant)
        drainMainQueue(file: file, line: line)
        XCTAssertEqual(pair.controller.coordinator.state, .controlling, file: file, line: line)
        return try XCTUnwrap(request.requestID, file: file, line: line)
    }

    private func makeFixture(
        localID: UUID = UUID(),
        remoteID: UUID = UUID(),
        initiallyConnected: Bool = true,
        keyboardLayoutIdentifier: String? = nil,
        seamlessControlAuthorized: Bool = false,
        clipboardSyncEnabled: Bool = false
    ) -> Fixture {
        let transport = FakeControlTransport(
            connectedPeerID: initiallyConnected ? remoteID : nil
        )
        let capture = FakeInputCapture()
        let sink = FakeInputSink()
        let clipboard = FakeClipboardSync()
        let permissionProbe = ControlledPermissionProbe()
        let coordinator = ControlCoordinator(
            localID: localID,
            secureSession: transport,
            inputCapture: capture,
            inputSink: sink,
            keyboardLayoutIdentifier: { keyboardLayoutIdentifier },
            seamlessControlAuthorized: { _ in seamlessControlAuthorized },
            clipboardSyncEnabled: { _ in clipboardSyncEnabled },
            clipboardSync: clipboard,
            remoteInputPermissionProbe: permissionProbe
        )
        drainMainQueue()
        transport.sentMessages.removeAll()
        capture.resetActivity()
        sink.resetActivity()
        return Fixture(
            coordinator: coordinator,
            transport: transport,
            capture: capture,
            sink: sink,
            clipboard: clipboard,
            permissionProbe: permissionProbe
        )
    }

    private func controlMessage(
        _ kind: ControlMessageKind,
        _ requestID: UUID
    ) -> ControlMessage {
        ControlMessage(kind: kind, requestID: requestID)
    }

    private func drainMainQueue(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let drained = expectation(description: "Drain main queue")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        wait(for: [drained], timeout: 1)
    }
}

private struct Fixture {
    let coordinator: ControlCoordinator
    let transport: FakeControlTransport
    let capture: FakeInputCapture
    let sink: FakeInputSink
    let clipboard: FakeClipboardSync
    let permissionProbe: ControlledPermissionProbe
}

private final class ControlledPermissionProbe: RuntimePermissionProbing {
    private var pending: [ControlledPermissionProbeOperation] = []
    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func start(
        completion: @escaping (Bool) -> Void
    ) -> any RuntimePermissionProbeResource {
        startCount += 1
        let operation = ControlledPermissionProbeOperation(
            completion: completion,
            onCancel: { [weak self] in self?.cancelCount += 1 }
        )
        pending.append(operation)
        return operation
    }

    func deliverNext(_ result: Bool) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().deliver(result)
    }
}

private final class ControlledPermissionProbeOperation:
    RuntimePermissionProbeResource {
    private let completion: (Bool) -> Void
    private let onCancel: () -> Void
    private var isCancelled = false

    init(
        completion: @escaping (Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.completion = completion
        self.onCancel = onCancel
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        onCancel()
    }

    func deliver(_ result: Bool) {
        // Deliberately allow a callback after cancellation to exercise the
        // coordinator's generation and live-request fence.
        completion(result)
    }
}

private final class FakeClipboardSync: ClipboardSyncManaging {
    var onLocalTextChange: ((String) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var receivedTexts: [String] = []

    func start() {
        startCount += 1
    }

    func receive(_ text: String) {
        receivedTexts.append(text)
    }

    func stop() {
        stopCount += 1
    }

    func emitLocalText(_ text: String) {
        onLocalTextChange?(text)
    }
}

private final class FakeControlTransport: ControlSessionTransport {
    private let connectionSubject: CurrentValueSubject<UUID?, Never>
    private let connectionPublicationSubject:
        CurrentValueSubject<ControlConnectionPublication, Never>
    private var nextAdmissionGeneration: UInt64?

    var connectedPeerID: UUID? {
        didSet {
            connectionSubject.send(connectedPeerID)
            connectionPublicationSubject.send(
                ControlConnectionPublication(
                    peerID: connectedPeerID,
                    admissionGeneration: nextAdmissionGeneration
                )
            )
            nextAdmissionGeneration = nil
        }
    }
    var connectedPeerIDPublisher: AnyPublisher<UUID?, Never> {
        connectionSubject.eraseToAnyPublisher()
    }
    var connectionPublicationPublisher:
        AnyPublisher<ControlConnectionPublication, Never> {
        connectionPublicationSubject.eraseToAnyPublisher()
    }
    var onPayload: ((Data) -> Void)?
    var onAuthenticated: (() -> UInt64)?
    var onHeartbeat: ((SecureSessionHeartbeatAcknowledgement) -> Void)?
    var sentMessages: [ControlMessage] = []
    private(set) var disconnectCount = 0

    init(connectedPeerID: UUID?) {
        connectionSubject = CurrentValueSubject(connectedPeerID)
        connectionPublicationSubject = CurrentValueSubject(
            ControlConnectionPublication(
                peerID: connectedPeerID,
                admissionGeneration: nil
            )
        )
        self.connectedPeerID = connectedPeerID
    }

    func send(_ payload: Data) {
        sentMessages.append(try! ControlMessageCodec.decode(payload))
    }

    func disconnect() {
        disconnectCount += 1
        connectedPeerID = nil
    }

    func setConnection(
        _ peerID: UUID?,
        admissionGeneration: UInt64?
    ) {
        nextAdmissionGeneration = admissionGeneration
        connectedPeerID = peerID
    }

    func deliver(_ message: ControlMessage) {
        onPayload?(try! ControlMessageCodec.encode(message))
    }
}

private final class FakeInputCapture: ControlInputCapture {
    var hasInputMonitoringPermission = true
    var isCapturing = false
    var onEvent: ((RemoteInputEvent) -> Void)?
    var onPermissionRevoked: (() -> Void)?
    var onEmergencyStop: (() -> Void)?
    var onSwitchControl: (() -> Void)?
    var onSwitchMonitor: (() -> Void)?
    var onStartCapture: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func refreshPermission() {}

    func startCapture(suppressingLocalEvents: Bool) {
        startCount += 1
        isCapturing = true
        onStartCapture?()
    }

    func stopCapture() {
        stopCount += 1
        isCapturing = false
    }

    func resetActivity() {
        startCount = 0
        stopCount = 0
    }
}

private final class FakeInputSink: ControlInputSink {
    var hasAccessibilityPermission = true
    var requiresFunctionalPermissionProbe = false
    var permissionFailureStatus = "Accessibility permission is required"
    private(set) var lastStalePostingPermissionValidated = false
    var onControlFailure: ((ControlInputFailure) -> Void)?
    var completesBeginImmediately = true
    var completesEndImmediately = true
    var onEndRequested: (() -> Void)?
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var receiveCount = 0
    private(set) var awaitInputProcessingCount = 0
    private var pendingBeginCompletion: ((Bool) -> Void)?
    private var pendingEndCompletions: [() -> Void] = []
    private var pendingInputProgressCompletions: [(Bool) -> Void] = []

    func refreshPermission() {}

    func beginRemoteControl(completion: @escaping (Bool) -> Void) {
        beginRemoteControl(
            stalePostingPermissionValidated: false,
            completion: completion
        )
    }

    func beginRemoteControl(
        stalePostingPermissionValidated: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        beginCount += 1
        lastStalePostingPermissionValidated =
            stalePostingPermissionValidated
        if completesBeginImmediately {
            completion(true)
        } else {
            pendingBeginCompletion = completion
        }
    }

    func endRemoteControl(completion: @escaping () -> Void) {
        endCount += 1
        onEndRequested?()
        if completesEndImmediately {
            completion()
        } else {
            pendingEndCompletions.append(completion)
        }
    }

    func receive(_ input: RemoteInputEvent) {
        receiveCount += 1
    }

    func awaitInputProcessing(completion: @escaping (Bool) -> Void) {
        awaitInputProcessingCount += 1
        pendingInputProgressCompletions.append(completion)
    }

    func completeBegin(didStart: Bool) {
        let completion = pendingBeginCompletion
        pendingBeginCompletion = nil
        completion?(didStart)
    }

    func completeNextEnd() {
        let completion = pendingEndCompletions.removeFirst()
        completion()
    }

    func completeNextInputProgress(didProgress: Bool = true) {
        let completion = pendingInputProgressCompletions.removeFirst()
        completion(didProgress)
    }

    func resetActivity() {
        beginCount = 0
        endCount = 0
        receiveCount = 0
        awaitInputProcessingCount = 0
        pendingBeginCompletion = nil
        pendingEndCompletions.removeAll()
        pendingInputProgressCompletions.removeAll()
        onEndRequested = nil
    }
}
