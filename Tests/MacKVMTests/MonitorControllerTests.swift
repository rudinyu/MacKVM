import Foundation
import MacKVMCore
import XCTest
@testable import MacKVM

final class MonitorControllerTests: XCTestCase {
    func testNewControllerDoesNotBlindlyDefaultToDisplayOne() {
        withDefaults { defaults in
            let monitor = MonitorController(defaults: defaults)

            XCTAssertEqual(monitor.displaySelector, "")
            XCTAssertFalse(monitor.isDisplaySelectorVerified)
        }
    }

    func testNativeDDCIsAvailableOnBothSupportedArchitectures() {
        withDefaults { defaults in
            XCTAssertTrue(MonitorController(defaults: defaults)
                .supportsAutomaticDDCSwitching)
        }
    }

    func testAutomaticSwitchingRequiresAVerifiedDDCSelection() {
        XCTAssertFalse(
            MonitorController.canUseAutomaticDDCSwitching(
                displaySelector: "saved-selector",
                isDisplaySelectorVerified: false
            )
        )
        XCTAssertFalse(
            MonitorController.canUseAutomaticDDCSwitching(
                displaySelector: "   ",
                isDisplaySelectorVerified: true
            )
        )
        XCTAssertTrue(
            MonitorController.canUseAutomaticDDCSwitching(
                displaySelector: "native-ddc:111:222:333",
                isDisplaySelectorVerified: true
            )
        )
        XCTAssertTrue(
            MonitorController.canUseAutomaticDDCSwitching(
                displaySelector: "NATIVE-DDC:111:222:333",
                isDisplaySelectorVerified: true
            )
        )
        XCTAssertFalse(
            MonitorController.canUseAutomaticDDCSwitching(
                displaySelector: "1",
                isDisplaySelectorVerified: true
            )
        )
    }

    func testSavedSelectorWaitsForItsFirstVerification() {
        XCTAssertEqual(
            MonitorController.automaticSwitchDecision(
                displaySelector: "native-ddc:111:222:333",
                isDisplaySelectorVerified: false,
                hasCompletedDisplayDiscovery: false
            ),
            .waitForVerification
        )
        XCTAssertEqual(
            MonitorController.automaticSwitchDecision(
                displaySelector: "native-ddc:111:222:333",
                isDisplaySelectorVerified: false,
                hasCompletedDisplayDiscovery: true
            ),
            .useManualFallback
        )
        XCTAssertEqual(
            MonitorController.automaticSwitchDecision(
                displaySelector: "native-ddc:111:222:333",
                isDisplaySelectorVerified: true,
                hasCompletedDisplayDiscovery: true
            ),
            .switchNow
        )
        XCTAssertEqual(
            MonitorController.automaticSwitchDecision(
                displaySelector: "1",
                isDisplaySelectorVerified: true,
                hasCompletedDisplayDiscovery: false
            ),
            .waitForVerification
        )
        XCTAssertEqual(
            MonitorController.automaticSwitchDecision(
                displaySelector: "1",
                isDisplaySelectorVerified: true,
                hasCompletedDisplayDiscovery: true
            ),
            .useManualFallback
        )
    }

    func testDDCDisplayMatchesStableSelectorWithoutModelNameAllowlist() {
        let display = DDCDisplay(
            index: 1,
            name: "Dell U2720Q",
            stableIdentifier: "native-ddc:111:222:333"
        )

        XCTAssertTrue(display.isDDCCapable)
        XCTAssertEqual(display.selector, "native-ddc:111:222:333")
        XCTAssertTrue(display.matches(selector: "NATIVE-DDC:111:222:333"))

        withDefaults { defaults in
            let monitor = MonitorController(defaults: defaults)
            monitor.selectDisplay(display)
            XCTAssertEqual(monitor.displaySelector, display.selector)
            XCTAssertTrue(monitor.status.contains("native DDC/CI"))
        }
    }

    func testNumericDisplayIndexCannotMatchOrSelectForAutomaticDDC() {
        let stableDisplay = DDCDisplay(
            index: 1,
            name: "Dell U2720Q",
            stableIdentifier: "native-ddc:111:222:333"
        )
        let indexOnlyDisplay = DDCDisplay(
            index: 2,
            name: "External display",
            stableIdentifier: nil
        )

        XCTAssertFalse(stableDisplay.matches(selector: "1"))
        XCTAssertEqual(indexOnlyDisplay.selector, "")
        XCTAssertFalse(indexOnlyDisplay.matches(selector: "2"))

        withDefaults { defaults in
            let monitor = MonitorController(defaults: defaults)
            monitor.selectDisplay(indexOnlyDisplay)

            XCTAssertEqual(monitor.displaySelector, "")
            XCTAssertFalse(monitor.isDisplaySelectorVerified)
        }
    }

    func testLegacyNumericSelectorRequiresExplicitReselection() {
        let display = DDCDisplay(
            index: 1,
            name: "Dell U2720Q",
            stableIdentifier: "native-ddc:111:222:333"
        )

        XCTAssertFalse(display.matches(selector: "1"))
        XCTAssertEqual(
            MonitorController.automaticSwitchDecision(
                displaySelector: "1",
                isDisplaySelectorVerified: true,
                hasCompletedDisplayDiscovery: true
            ),
            .useManualFallback
        )
    }

    func testDeferredSwitchReplacementCompletesTheSupersededRequest() {
        var state = DeferredAutomaticSwitchState()
        var completed: [String] = []

        XCTAssertTrue(
            state.deferSwitch(
                input: .usbC,
                description: "this Mac",
                intent: .normal,
                completion: { completed.append("local") }
            ).isEmpty
        )

        let superseded = state.deferSwitch(
            input: .hdmi1,
            description: "the other Mac",
            intent: .normal,
            completion: { completed.append("remote") }
        )
        superseded.forEach { $0() }

        XCTAssertEqual(completed, ["local"])
        let pending = state.takeDeferredSwitch()
        XCTAssertEqual(pending?.input, .hdmi1)
        XCTAssertEqual(pending?.intent, .normal)
        pending?.complete()
        XCTAssertEqual(completed, ["local", "remote"])
    }

    func testTerminationKeepsOnlyTheFinalLocalDeferredRoute() {
        var state = DeferredAutomaticSwitchState()
        var completed: [String] = []

        _ = state.deferSwitch(
            input: .hdmi1,
            description: "the other Mac",
            intent: .normal,
            completion: { completed.append("old remote") }
        )
        state.beginTermination().forEach { $0() }

        XCTAssertTrue(state.isTerminating)
        XCTAssertEqual(completed, ["old remote"])
        XCTAssertTrue(
            state.deferSwitch(
                input: .usbC,
                description: "this Mac",
                intent: .terminating,
                completion: { completed.append("final local") }
            ).isEmpty
        )

        let ignoredNormalRoute = state.deferSwitch(
            input: .hdmi1,
            description: "the other Mac",
            intent: .normal,
            completion: { completed.append("ignored remote") }
        )
        ignoredNormalRoute.forEach { $0() }

        let pending = state.takeDeferredSwitch()
        XCTAssertEqual(pending?.input, .usbC)
        XCTAssertEqual(pending?.intent, .terminating)
        pending?.complete()
        XCTAssertEqual(
            completed,
            ["old remote", "ignored remote", "final local"]
        )
    }

    func testTerminationLatchDefersCancelledRouteCompletionUntilRequested() {
        var state = DeferredAutomaticSwitchState()
        var cancelledRouteCompletionCount = 0

        _ = state.deferSwitch(
            input: .hdmi1,
            description: "the other Mac",
            intent: .normal,
            completion: { cancelledRouteCompletionCount += 1 }
        )

        let cancelledCompletions = state.beginTermination()

        XCTAssertTrue(state.isTerminating)
        XCTAssertEqual(cancelledRouteCompletionCount, 0)

        cancelledCompletions.forEach { $0() }

        XCTAssertEqual(cancelledRouteCompletionCount, 1)
    }

    func testManualFallbackCompletesWithoutLaunchingAProcess() {
        withDefaults { defaults in
            let monitor = MonitorController(defaults: defaults)
            monitor.automationEnabled = false
            var didComplete = false

            monitor.switchToLocal {
                didComplete = true
            }

            XCTAssertTrue(didComplete)
            XCTAssertTrue(monitor.status.contains("OSD"))
        }
    }

    func testPresetsPersistAcrossControllerInstances() {
        withDefaults { defaults in
            let first = MonitorController(defaults: defaults)
            first.applyAppleSiliconUSBPreset()

            let second = MonitorController(defaults: defaults)
            XCTAssertTrue(second.automationEnabled)
            XCTAssertEqual(second.localInput, .usbC)
            XCTAssertEqual(second.remoteInput, .hdmi1)
        }
    }

    private func withDefaults(
        _ body: (UserDefaults) -> Void
    ) {
        let suiteName = "MonitorControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        body(defaults)
    }
}
