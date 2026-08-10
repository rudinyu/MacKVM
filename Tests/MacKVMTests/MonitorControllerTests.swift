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

    func testAutomaticSwitchingRequiresAVerifiedMA270USelection() {
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
                displaySelector: "verified-ma270u",
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
                displaySelector: "saved-ma270u",
                isDisplaySelectorVerified: false,
                hasCompletedDisplayDiscovery: false
            ),
            .waitForVerification
        )
        XCTAssertEqual(
            MonitorController.automaticSwitchDecision(
                displaySelector: "saved-ma270u",
                isDisplaySelectorVerified: false,
                hasCompletedDisplayDiscovery: true
            ),
            .useManualFallback
        )
        XCTAssertEqual(
            MonitorController.automaticSwitchDecision(
                displaySelector: "saved-ma270u",
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

    func testParsesM1DDCDisplayListWithStableIdentifiers() {
        let displays = M1DDCDisplayListParser.displays(
            from: """
            [1] BenQ MA270U (10ACB8A0-0000-0000-1419-0104A2435078)
            [2] (null) (37D8832A-2D66-02CA-B9F7-8F30A301B230)
            """
        )

        XCTAssertEqual(displays.count, 2)
        XCTAssertEqual(displays[0].index, 1)
        XCTAssertEqual(displays[0].name, "BenQ MA270U")
        XCTAssertEqual(
            displays[0].selector,
            "10ACB8A0-0000-0000-1419-0104A2435078"
        )
        XCTAssertEqual(displays[1].name, "(null)")
        XCTAssertTrue(
            displays[1].matches(
                selector: "37D8832A-2D66-02CA-B9F7-8F30A301B230"
            )
        )
    }

    func testNumericDisplayIndexCannotMatchOrSelectForAutomaticDDC() {
        let stableDisplay = M1DDCDisplay(
            index: 1,
            name: "BenQ MA270U",
            stableIdentifier: "10ACB8A0-0000-0000-1419-0104A2435078"
        )
        let indexOnlyDisplay = M1DDCDisplay(
            index: 2,
            name: "BenQ MA270U",
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

    func testStableIdentifierReplacesAnOlderNumericSelector() {
        let display = M1DDCDisplay(
            index: 1,
            name: "BenQ MA270U",
            stableIdentifier: "10ACB8A0-0000-0000-1419-0104A2435078"
        )

        XCTAssertEqual(
            display.stableSelectorReplacing("1"),
            "10ACB8A0-0000-0000-1419-0104A2435078"
        )
        XCTAssertNil(
            display.stableSelectorReplacing(
                "10ACB8A0-0000-0000-1419-0104A2435078"
            )
        )
        XCTAssertNil(display.stableSelectorReplacing("2"))
        XCTAssertNil(
            display.stableSelectorReplacing(
                "22222222-2222-2222-2222-222222222222"
            )
        )
    }

    func testPrefersUniqueMA270UOverAnotherExternalDisplay() {
        let displays = M1DDCDisplayListParser.displays(
            from: """
            [1] Dell U2720Q (11111111-1111-1111-1111-111111111111)
            [2] BenQ MA270U (22222222-2222-2222-2222-222222222222)
            """
        )

        XCTAssertEqual(
            M1DDCDisplayListParser.recommendedDisplay(from: displays)?.selector,
            "22222222-2222-2222-2222-222222222222"
        )
    }

    func testDoesNotRecommendAnAmbiguousDisplayList() {
        let displays = M1DDCDisplayListParser.displays(
            from: """
            [1] Dell U2720Q (11111111-1111-1111-1111-111111111111)
            [2] LG UltraFine (22222222-2222-2222-2222-222222222222)
            """
        )

        XCTAssertNil(M1DDCDisplayListParser.recommendedDisplay(from: displays))
    }

    func testDoesNotRecommendASingleNonMA270UDisplay() {
        let displays = M1DDCDisplayListParser.displays(
            from: "[1] BenQ PD2705U (11111111-1111-1111-1111-111111111111)"
        )

        XCTAssertFalse(displays[0].isLikelyMA270U)
        XCTAssertNil(M1DDCDisplayListParser.recommendedDisplay(from: displays))
    }

    func testDoesNotRecommendMA270UWithoutAStableIdentifier() {
        let displays = [
            M1DDCDisplay(
                index: 1,
                name: "BenQ MA270U",
                stableIdentifier: nil
            )
        ]

        XCTAssertNil(M1DDCDisplayListParser.recommendedDisplay(from: displays))
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

    func testMissingExecutableUsesFallbackAndCompletes() {
        withDefaults { defaults in
            let monitor = MonitorController(defaults: defaults)
            monitor.automationEnabled = true
            monitor.executablePath = "/nonexistent/m1ddc"
            var didComplete = false

            monitor.switchToLocal {
                didComplete = true
            }

            XCTAssertTrue(didComplete)
            XCTAssertTrue(monitor.status.contains("OSD"))
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
