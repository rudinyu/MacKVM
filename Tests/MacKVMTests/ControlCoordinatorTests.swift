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

        fixture.coordinator.acceptIncomingControlRequest(requestID)

        XCTAssertNil(fixture.coordinator.pendingIncomingControlRequest)
        XCTAssertTrue(fixture.coordinator.isReceivingControl)
        XCTAssertEqual(fixture.sink.beginCount, 1)
        XCTAssertEqual(
            fixture.transport.sentMessages.last,
            controlMessage(.controlGranted, requestID)
        )
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

        fixture.coordinator.requestControl()
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

    private func makeFixture(
        localID: UUID = UUID(),
        remoteID: UUID = UUID()
    ) -> Fixture {
        let transport = FakeControlTransport(connectedPeerID: remoteID)
        let capture = FakeInputCapture()
        let sink = FakeInputSink()
        let coordinator = ControlCoordinator(
            localID: localID,
            secureSession: transport,
            inputCapture: capture,
            inputSink: sink
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

    var connectedPeerID: UUID? {
        didSet { connectionSubject.send(connectedPeerID) }
    }
    var connectedPeerIDPublisher: AnyPublisher<UUID?, Never> {
        connectionSubject.eraseToAnyPublisher()
    }
    var onPayload: ((Data) -> Void)?
    var sentMessages: [ControlMessage] = []

    init(connectedPeerID: UUID?) {
        connectionSubject = CurrentValueSubject(connectedPeerID)
        self.connectedPeerID = connectedPeerID
    }

    func send(_ payload: Data) {
        sentMessages.append(try! ControlMessageCodec.decode(payload))
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
    var onControlFailure: (() -> Void)?
    var completesBeginImmediately = true
    var completesEndImmediately = true
    var onEndRequested: (() -> Void)?
    private(set) var beginCount = 0
    private(set) var endCount = 0
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

    func receive(_ input: RemoteInputEvent) {}

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
        pendingBeginCompletion = nil
        pendingEndCompletions.removeAll()
        onEndRequested = nil
    }
}
