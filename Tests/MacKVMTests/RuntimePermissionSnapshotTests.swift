import XCTest
@testable import MacKVM

final class RuntimePermissionSnapshotTests: XCTestCase {
    func testCaptureGateUsesCoreGraphicsListenCheckNotHIDDiagnostic() {
        let hidDenied = snapshot(
            canListen: true,
            canPost: false,
            accessibilityTrusted: false,
            hidListen: .denied,
            hidPost: .unknown
        )
        XCTAssertTrue(hidDenied.canCaptureInput)
        XCTAssertFalse(hidDenied.canInjectRemoteInput)

        let cgDenied = snapshot(
            canListen: false,
            canPost: true,
            accessibilityTrusted: true,
            hidListen: .granted,
            hidPost: .granted
        )
        XCTAssertFalse(cgDenied.canCaptureInput)
        XCTAssertTrue(cgDenied.canInjectRemoteInput)
    }

    func testPerEventGateRequiresPostUnlessCurrentSessionPassedStaleProbe() {
        XCTAssertTrue(
            RemoteInputPermissionCheck(
                accessibilityIsTrusted: true,
                canPostCoreGraphicsEvents: true
            ).isAuthorized
        )
        XCTAssertFalse(
            RemoteInputPermissionCheck(
                accessibilityIsTrusted: false,
                canPostCoreGraphicsEvents: true
            ).isAuthorized
        )
        XCTAssertFalse(
            RemoteInputPermissionCheck(
                accessibilityIsTrusted: true,
                canPostCoreGraphicsEvents: false
            ).isAuthorized
        )
        XCTAssertTrue(
            RemoteInputPermissionCheck(
                accessibilityIsTrusted: true,
                canPostCoreGraphicsEvents: false
            ).isAuthorized(stalePostingPermissionValidated: true)
        )
        XCTAssertFalse(
            RemoteInputPermissionCheck(
                accessibilityIsTrusted: false,
                canPostCoreGraphicsEvents: false
            ).isAuthorized(stalePostingPermissionValidated: true)
        )
    }

    func testOutboundControlGateIncludesAllRequiredCapabilities() {
        let listenOnly = snapshot(
            canListen: true,
            canPost: false,
            accessibilityTrusted: true,
            hidListen: .unknown,
            hidPost: .unknown
        )
        XCTAssertTrue(listenOnly.canCaptureInput)
        XCTAssertTrue(listenOnly.canStartOutboundControl)

        let accessibilityAndPostOnly = snapshot(
            canListen: false,
            canPost: true,
            accessibilityTrusted: true,
            hidListen: .unknown,
            hidPost: .unknown
        )
        XCTAssertFalse(accessibilityAndPostOnly.canCaptureInput)
        XCTAssertFalse(accessibilityAndPostOnly.canStartOutboundControl)

        let allRequiredAccess = snapshot(
            canListen: true,
            canPost: true,
            accessibilityTrusted: true,
            hidListen: .unknown,
            hidPost: .unknown
        )
        XCTAssertTrue(allRequiredAccess.canStartOutboundControl)
    }

    func testSessionHotKeyTapNeedsListenAndAXButNotPostPreflight() {
        let complete = snapshot(
            canListen: true,
            canPost: true,
            accessibilityTrusted: true,
            hidListen: .unknown,
            hidPost: .unknown
        )
        let accessibilityRevoked = snapshot(
            canListen: true,
            canPost: true,
            accessibilityTrusted: false,
            hidListen: .unknown,
            hidPost: .unknown
        )
        let postRevoked = snapshot(
            canListen: true,
            canPost: false,
            accessibilityTrusted: true,
            hidListen: .unknown,
            hidPost: .unknown
        )

        XCTAssertTrue(complete.canUseSessionHotKeyTap)
        XCTAssertFalse(accessibilityRevoked.canUseSessionHotKeyTap)
        XCTAssertTrue(postRevoked.canUseSessionHotKeyTap)
        XCTAssertTrue(accessibilityRevoked.canCaptureInput)
        XCTAssertTrue(postRevoked.canCaptureInput)
    }

    func testOnlyRequiredCapabilitiesRevokeOutboundAndSessionTapPaths() {
        let allAccess = snapshot(
            canListen: true,
            canPost: true,
            accessibilityTrusted: true,
            hidListen: .granted,
            hidPost: .granted
        )
        let accessibilityRevoked = snapshot(
            canListen: true,
            canPost: true,
            accessibilityTrusted: false,
            hidListen: .granted,
            hidPost: .granted
        )
        let postRevoked = snapshot(
            canListen: true,
            canPost: false,
            accessibilityTrusted: true,
            hidListen: .granted,
            hidPost: .granted
        )

        XCTAssertTrue(accessibilityRevoked.canCaptureInput)
        XCTAssertTrue(allAccess.revokesOutboundControl(comparedTo: accessibilityRevoked))
        XCTAssertTrue(allAccess.requiresHotKeyMonitorRebuild(comparedTo: accessibilityRevoked))

        XCTAssertTrue(postRevoked.canCaptureInput)
        XCTAssertFalse(allAccess.revokesOutboundControl(comparedTo: postRevoked))
        XCTAssertFalse(allAccess.requiresHotKeyMonitorRebuild(comparedTo: postRevoked))
    }

    func testPermissionSnapshotTruthTableForControllerAndReceiverPaths() {
        let cases: [(
            accessibility: Bool,
            listen: Bool,
            post: Bool,
            canInject: Bool,
            canControl: Bool,
            canUseTap: Bool,
            stale: Bool
        )] = [
            (true, true, true, true, true, true, false),
            (true, true, false, true, true, true, true),
            (false, true, true, false, false, false, false),
            (true, false, true, true, false, false, false)
        ]

        for item in cases {
            let value = snapshot(
                canListen: item.listen,
                canPost: item.post,
                accessibilityTrusted: item.accessibility,
                hidListen: .unknown,
                hidPost: .unknown
            )
            XCTAssertEqual(value.canInjectRemoteInput, item.canInject)
            XCTAssertEqual(value.canStartOutboundControl, item.canControl)
            XCTAssertEqual(value.canUseSessionHotKeyTap, item.canUseTap)
            XCTAssertEqual(value.postAccessLooksStale, item.stale)
        }
    }

    func testUnrelatedHIDDiagnosticChangeDoesNotRebuildShortcutPath() {
        let before = snapshot(
            canListen: true,
            canPost: true,
            accessibilityTrusted: true,
            hidListen: .granted,
            hidPost: .granted
        )
        let after = snapshot(
            canListen: true,
            canPost: true,
            accessibilityTrusted: true,
            hidListen: .denied,
            hidPost: .unknown
        )

        XCTAssertFalse(before.requiresHotKeyMonitorRebuild(comparedTo: after))
        XCTAssertFalse(before.revokesOutboundControl(comparedTo: after))
    }

    func testDiagnosticSummaryRetainsIndependentPermissionSignals() {
        let value = snapshot(
            canListen: false,
            canPost: true,
            accessibilityTrusted: true,
            hidListen: .unknown,
            hidPost: .denied
        ).diagnosticSummary

        XCTAssertTrue(value.contains("CG listen=no"))
        XCTAssertTrue(value.contains("CG post=yes"))
        XCTAssertTrue(value.contains("AX trusted=yes"))
        XCTAssertTrue(value.contains("IOHID listen (Manager/Device scope)=unknown"))
        XCTAssertTrue(value.contains("IOHID post (IOHIDPostEvent scope)=denied"))
    }

    func testCaptureServiceDoesNotStartWhenSystemDoesNotReportListenAccess() {
        let provider = MutablePermissionProvider(snapshot: snapshot(
            canListen: false,
            canPost: true,
            accessibilityTrusted: true,
            hidListen: .granted,
            hidPost: .granted
        ))
        let capture = InputCaptureService(permissionSnapshotProvider: provider)

        capture.startCapture()

        XCTAssertFalse(capture.hasInputMonitoringPermission)
        XCTAssertFalse(capture.isCapturing)
    }

    func testRemoteInputSinkRejectsControlWhenCGPostAccessIsNotReported() {
        let provider = MutablePermissionProvider(snapshot: snapshot(
            canListen: true,
            canPost: false,
            accessibilityTrusted: true,
            hidListen: .granted,
            hidPost: .granted
        ))
        let sink = RemoteInputSink(permissionSnapshotProvider: provider)
        let didFinish = expectation(description: "Remote control denied")
        var wasGranted: Bool?

        sink.beginRemoteControl { granted in
            wasGranted = granted
            didFinish.fulfill()
        }

        wait(for: [didFinish], timeout: 2)
        XCTAssertEqual(wasGranted, false)
        XCTAssertTrue(sink.hasAccessibilityPermission)
    }

    func testFunctionalProbeAcceptsOnlyTheMatchingTaggedMouseMove() throws {
        let driver = FakePermissionProbeDriver()
        let marker: Int64 = 0x1234
        let probe = FunctionalRemoteInputPermissionProbe(
            driver: driver,
            marker: { marker }
        )
        var result: Bool?
        let operation = probe.start { result = $0 }

        XCTAssertEqual(
            try XCTUnwrap(driver.timeoutDelay),
            0.3,
            accuracy: 0.0001
        )
        XCTAssertEqual(driver.postedMarker, marker)
        driver.emit(userData: InjectedEventMarker.value)
        XCTAssertNil(result)
        driver.emit(userData: marker)

        XCTAssertEqual(result, true)
        XCTAssertEqual(driver.tapCancellationCount, 1)
        XCTAssertEqual(driver.timerCancellationCount, 1)
        operation.cancel()
        XCTAssertEqual(result, true)
    }

    func testFunctionalProbeFailsClosedWhenListenOnlyTapIsUnavailable() {
        let driver = FakePermissionProbeDriver()
        driver.canInstallTap = false
        let probe = FunctionalRemoteInputPermissionProbe(
            driver: driver,
            marker: { 1 }
        )
        var result: Bool?

        _ = probe.start { result = $0 }

        XCTAssertEqual(result, false)
        XCTAssertNil(driver.timeoutDelay)
        XCTAssertNil(driver.postedMarker)
    }

    func testFunctionalProbeTimeoutAndPostFailureCleanUpBothResources() {
        let timeoutDriver = FakePermissionProbeDriver()
        let timeoutProbe = FunctionalRemoteInputPermissionProbe(
            driver: timeoutDriver,
            marker: { 2 }
        )
        var timeoutResult: Bool?
        let timeoutOperation = timeoutProbe.start { timeoutResult = $0 }
        timeoutDriver.fireTimeout()

        XCTAssertEqual(timeoutResult, false)
        XCTAssertEqual(timeoutDriver.tapCancellationCount, 1)
        XCTAssertEqual(timeoutDriver.timerCancellationCount, 1)
        timeoutOperation.cancel()

        let postDriver = FakePermissionProbeDriver()
        postDriver.postSucceeds = false
        let postProbe = FunctionalRemoteInputPermissionProbe(
            driver: postDriver,
            marker: { 3 }
        )
        var postResult: Bool?
        _ = postProbe.start { postResult = $0 }

        XCTAssertEqual(postResult, false)
        XCTAssertEqual(postDriver.tapCancellationCount, 1)
        XCTAssertEqual(postDriver.timerCancellationCount, 1)
    }

    func testFunctionalProbeCancellationCleansTapAndTimerWithoutCompleting() {
        let driver = FakePermissionProbeDriver()
        let probe = FunctionalRemoteInputPermissionProbe(
            driver: driver,
            marker: { 4 }
        )
        var result: Bool?
        let operation = probe.start { result = $0 }

        operation.cancel()

        XCTAssertNil(result)
        XCTAssertEqual(driver.tapCancellationCount, 1)
        XCTAssertEqual(driver.timerCancellationCount, 1)
        driver.emit(userData: 4)
        XCTAssertNil(result)
    }

    func testDroppingProbeOperationCancelsResourcesAndSuppressesLateEvents() {
        let driver = FakePermissionProbeDriver()
        let probe = FunctionalRemoteInputPermissionProbe(
            driver: driver,
            marker: { 5 }
        )
        var result: Bool?
        var operation: (any RuntimePermissionProbeResource)? =
            probe.start { result = $0 }

        XCTAssertNotNil(operation)
        operation = nil

        XCTAssertNil(result)
        XCTAssertEqual(driver.tapCancellationCount, 1)
        XCTAssertEqual(driver.timerCancellationCount, 1)
        driver.emit(userData: 5)
        driver.fireTimeout()
        XCTAssertNil(result)
    }

    func testRemoteInputPermissionRefreshTracksProviderGrantAndRevocation() {
        let denied = snapshot(
            canListen: false,
            canPost: false,
            accessibilityTrusted: false,
            hidListen: .denied,
            hidPost: .denied
        )
        let granted = snapshot(
            canListen: true,
            canPost: true,
            accessibilityTrusted: true,
            hidListen: .granted,
            hidPost: .granted
        )
        let provider = MutablePermissionProvider(snapshot: denied)
        let sink = RemoteInputSink(permissionSnapshotProvider: provider)

        XCTAssertFalse(sink.hasAccessibilityPermission)
        provider.snapshot = granted
        sink.refreshPermission()
        XCTAssertTrue(sink.hasAccessibilityPermission)

        provider.snapshot = denied
        sink.refreshPermission()
        XCTAssertFalse(sink.hasAccessibilityPermission)
    }

    private func snapshot(
        canListen: Bool,
        canPost: Bool,
        accessibilityTrusted: Bool,
        hidListen: IOHIDPermissionSignal,
        hidPost: IOHIDPermissionSignal
    ) -> RuntimePermissionSnapshot {
        RuntimePermissionSnapshot(
            canListenToCoreGraphicsEvents: canListen,
            canPostCoreGraphicsEvents: canPost,
            accessibilityIsTrusted: accessibilityTrusted,
            ioHIDListenAccess: hidListen,
            ioHIDPostAccess: hidPost
        )
    }
}

private final class MutablePermissionProvider:
    RuntimePermissionSnapshotProviding {
    var snapshot: RuntimePermissionSnapshot

    init(snapshot: RuntimePermissionSnapshot) {
        self.snapshot = snapshot
    }

    func currentSnapshot() -> RuntimePermissionSnapshot {
        snapshot
    }

    func currentRemoteInputPermission() -> RemoteInputPermissionCheck {
        RemoteInputPermissionCheck(
            accessibilityIsTrusted: snapshot.accessibilityIsTrusted,
            canPostCoreGraphicsEvents: snapshot.canPostCoreGraphicsEvents
        )
    }
}

private final class FakePermissionProbeDriver: RuntimePermissionProbeDriver {
    var canInstallTap = true
    var postSucceeds = true
    private(set) var timeoutDelay: TimeInterval?
    private(set) var postedMarker: Int64?
    private(set) var tapCancellationCount = 0
    private(set) var timerCancellationCount = 0
    private var eventHandler: ((Int64) -> Void)?
    private var timeoutHandler: (() -> Void)?

    func installListenOnlyTap(
        onEventUserData: @escaping (Int64) -> Void
    ) -> (any RuntimePermissionProbeResource)? {
        guard canInstallTap else { return nil }
        eventHandler = onEventUserData
        return FakePermissionProbeResource { [weak self] in
            self?.tapCancellationCount += 1
            self?.eventHandler = nil
        }
    }

    func postZeroDeltaMouseMove(userData: Int64) -> Bool {
        postedMarker = userData
        return postSucceeds
    }

    func scheduleTimeout(
        after delay: TimeInterval,
        handler: @escaping () -> Void
    ) -> any RuntimePermissionProbeResource {
        timeoutDelay = delay
        timeoutHandler = handler
        return FakePermissionProbeResource { [weak self] in
            self?.timerCancellationCount += 1
            self?.timeoutHandler = nil
        }
    }

    func emit(userData: Int64) {
        eventHandler?(userData)
    }

    func fireTimeout() {
        timeoutHandler?()
    }
}

private final class FakePermissionProbeResource:
    RuntimePermissionProbeResource {
    private var onCancel: (() -> Void)?

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    func cancel() {
        let action = onCancel
        onCancel = nil
        action?()
    }
}
