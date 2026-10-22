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

    func testRemoteInjectionRequiresAccessibilityAndCoreGraphicsPostChecks() {
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
        XCTAssertFalse(listenOnly.canStartOutboundControl)

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

    func testSessionHotKeyTapCapabilityTracksAXAndPostWithoutChangingCapture() {
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
        XCTAssertFalse(postRevoked.canUseSessionHotKeyTap)
        XCTAssertTrue(accessibilityRevoked.canCaptureInput)
        XCTAssertTrue(postRevoked.canCaptureInput)
    }

    func testRevokingAXOrPostAccessInvalidatesOutboundAndSessionTapPaths() {
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

        for revoked in [accessibilityRevoked, postRevoked] {
            XCTAssertTrue(revoked.canCaptureInput)
            XCTAssertTrue(allAccess.revokesOutboundControl(comparedTo: revoked))
            XCTAssertTrue(allAccess.requiresHotKeyMonitorRebuild(comparedTo: revoked))
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
        XCTAssertFalse(sink.hasAccessibilityPermission)
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
