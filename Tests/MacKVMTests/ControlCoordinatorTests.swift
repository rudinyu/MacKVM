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

        fixture.coordinator.stopForQuit { quitCompletionCount += 1 }

        XCTAssertFalse(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(receiverStopCount, 0)
        XCTAssertEqual(quitCompletionCount, 0)
        XCTAssertEqual(fixture.sink.endCount, 1)

        fixture.sink.completeNextEnd()

        XCTAssertEqual(receiverStopCount, 0)
        XCTAssertEqual(quitCompletionCount, 1)
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

    private func makeFixture(
        localID: UUID = UUID(),
        remoteID: UUID = UUID(),
        initiallyConnected: Bool = true,
        keyboardLayoutIdentifier: String? = nil,
        seamlessControlAuthorized: Bool = false
    ) -> Fixture {
        let transport = FakeControlTransport(
            connectedPeerID: initiallyConnected ? remoteID : nil
        )
        let capture = FakeInputCapture()
        let sink = FakeInputSink()
        let coordinator = ControlCoordinator(
            localID: localID,
            secureSession: transport,
            inputCapture: capture,
            inputSink: sink,
            keyboardLayoutIdentifier: { keyboardLayoutIdentifier },
            seamlessControlAuthorized: { _ in seamlessControlAuthorized }
        )
        drainMainQueue()
        transport.sentMessages.removeAll()
        capture.resetActivity()
        sink.resetActivity()
        return Fixture(
            coordinator: coordinator,
            transport: transport,
            capture: capture,
            sink: sink
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
    var onEmergencyStop: (() -> Void)?
    var onSwitchControl: (() -> Void)?
    var onSwitchMonitor: (() -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func refreshPermission() {}

    func startCapture(suppressingLocalEvents: Bool) {
        startCount += 1
        isCapturing = true
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
    var onControlFailure: ((ControlInputFailure) -> Void)?
    var completesBeginImmediately = true
    var completesEndImmediately = true
    var onEndRequested: (() -> Void)?
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var receiveCount = 0
    private var pendingBeginCompletion: ((Bool) -> Void)?
    private var pendingEndCompletions: [() -> Void] = []

    func refreshPermission() {}

    func beginRemoteControl(completion: @escaping (Bool) -> Void) {
        beginCount += 1
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

    func completeBegin(didStart: Bool) {
        let completion = pendingBeginCompletion
        pendingBeginCompletion = nil
        completion?(didStart)
    }

    func completeNextEnd() {
        let completion = pendingEndCompletions.removeFirst()
        completion()
    }

    func resetActivity() {
        beginCount = 0
        endCount = 0
        receiveCount = 0
        pendingBeginCompletion = nil
        pendingEndCompletions.removeAll()
        onEndRequested = nil
    }
}
