import Combine
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

    func testArchitectureDefaultsMatchThePhysicalMonitorPorts() {
        XCTAssertEqual(
            MonitorController.defaultInputPreferences(isAppleSilicon: true).local,
            .usbC
        )
        XCTAssertEqual(
            MonitorController.defaultInputPreferences(isAppleSilicon: true).remote,
            .hdmi1
        )
        XCTAssertEqual(
            MonitorController.defaultInputPreferences(isAppleSilicon: false).local,
            .hdmi1
        )
        XCTAssertEqual(
            MonitorController.defaultInputPreferences(isAppleSilicon: false).remote,
            .usbC
        )
    }

    func testNativeDDCIsAvailableOnBothSupportedArchitectures() {
        withDefaults { defaults in
            XCTAssertTrue(MonitorController(defaults: defaults)
                .supportsAutomaticDDCSwitching)
        }
    }

    func testDisplaySleepLeaseRequiresASelectedVerifiedDisplay() {
        XCTAssertFalse(
            MonitorController.shouldKeepDisplayAwake(
                automationEnabled: true,
                displaySelector: "",
                detectedDisplays: [],
                confirmedRoute: nil,
                configurationGeneration: 0,
                transitionGraceActive: false
            )
        )
        XCTAssertFalse(
            MonitorController.shouldKeepDisplayAwake(
                automationEnabled: true,
                displaySelector: "native-ddc:1:2:3",
                detectedDisplays: [],
                confirmedRoute: nil,
                configurationGeneration: 0,
                transitionGraceActive: false
            )
        )
        XCTAssertTrue(
            MonitorController.shouldKeepDisplayAwake(
                automationEnabled: true,
                displaySelector: "native-ddc:1:2:3",
                detectedDisplays: [testDisplay()],
                confirmedRoute: nil,
                configurationGeneration: 0,
                transitionGraceActive: false
            )
        )
        XCTAssertTrue(
            MonitorController.shouldKeepDisplayAwake(
                automationEnabled: true,
                displaySelector: "NATIVE-DDC:1:2:3",
                detectedDisplays: [],
                confirmedRoute: ConfirmedDisplayRoute(
                    role: .remote,
                    selector: "native-ddc:1:2:3",
                    input: .hdmi1,
                    configurationGeneration: 0
                ),
                configurationGeneration: 0,
                transitionGraceActive: false
            )
        )
        XCTAssertFalse(
            MonitorController.shouldKeepDisplayAwake(
                automationEnabled: true,
                displaySelector: "native-ddc:1:2:3",
                detectedDisplays: [],
                confirmedRoute: ConfirmedDisplayRoute(
                    role: .local,
                    selector: "native-ddc:1:2:3",
                    input: .usbC,
                    configurationGeneration: 0
                ),
                configurationGeneration: 0,
                transitionGraceActive: false
            )
        )
        XCTAssertFalse(
            MonitorController.shouldKeepDisplayAwake(
                automationEnabled: true,
                displaySelector: "native-ddc:1:2:3",
                detectedDisplays: [],
                confirmedRoute: ConfirmedDisplayRoute(
                    role: .unknown,
                    selector: "native-ddc:1:2:3",
                    input: nil,
                    configurationGeneration: 0
                ),
                configurationGeneration: 0,
                transitionGraceActive: false
            )
        )
        XCTAssertFalse(
            MonitorController.shouldKeepDisplayAwake(
                automationEnabled: true,
                displaySelector: "native-ddc:1:2:3",
                detectedDisplays: [],
                confirmedRoute: ConfirmedDisplayRoute(
                    role: .remote,
                    selector: "native-ddc:1:2:3",
                    input: .hdmi1,
                    configurationGeneration: 1
                ),
                configurationGeneration: 0,
                transitionGraceActive: false
            )
        )
        XCTAssertFalse(
            MonitorController.shouldKeepDisplayAwake(
                automationEnabled: false,
                displaySelector: "native-ddc:1:2:3",
                detectedDisplays: [testDisplay()],
                confirmedRoute: nil,
                configurationGeneration: 0,
                transitionGraceActive: false
            )
        )
    }

    func testPreservedVerifiedFlagDoesNotKeepLeaseWithoutPhysicalDisplay() {
        XCTAssertFalse(
            MonitorController.shouldKeepDisplayAwake(
                automationEnabled: true,
                displaySelector: "native-ddc:1:2:3",
                detectedDisplays: [],
                confirmedRoute: nil,
                configurationGeneration: 0,
                transitionGraceActive: false
            )
        )
    }

    func testEmptyRoutineDiscoveryAfterRemoteRouteStillAllowsCachedLocalReturnOnly() {
        withDefaults { defaults in
            let ddc = FakeMonitorDDC(displays: [testDisplay()], currentInputValue: 17)
            let monitor = MonitorController(defaults: defaults, ddcOperations: ddc.operations)
            monitor.localInput = .usbC
            monitor.remoteInput = .hdmi1
            monitor.automationEnabled = true
            defer { monitor.automationEnabled = false }
            refreshAndWaitForDiscovery(monitor)
            XCTAssertTrue(monitor.isDisplaySelectorVerified)

            let remoteRoute = expectation(description: "Confirmed remote monitor route")
            monitor.switchToRemote(wakeDisplayForKVMSwitch: false) {
                remoteRoute.fulfill()
            }
            wait(for: [remoteRoute], timeout: 5)

            // A normal menu refresh has no preservation token, just as a
            // refresh after the short topology grace has expired does not.
            ddc.displays = []
            refreshAndWaitForDiscovery(monitor)
            XCTAssertEqual(monitor.detectedDisplays, [])
            XCTAssertFalse(monitor.isDisplaySelectorVerified)
            XCTAssertFalse(monitor.canStartAutomaticRemoteSwitching())

            let localRoute = expectation(description: "Cached native local return")
            monitor.switchToLocal(wakeDisplayForKVMSwitch: false) {
                localRoute.fulfill()
            }
            wait(for: [localRoute], timeout: 5)

            XCTAssertEqual(ddc.writeAttempts.map(\.input), [.usbC])
            XCTAssertEqual(ddc.writeAttempts.map(\.selector), [testDisplay().selector])
            XCTAssertTrue(monitor.status.contains("switched to"))
            XCTAssertFalse(monitor.isDisplaySelectorVerified)
            XCTAssertFalse(monitor.canStartAutomaticRemoteSwitching())

            let readsBeforeRemoteAttempt = ddc.readSelectors.count
            var remoteCompleted = false
            monitor.switchToRemote(wakeDisplayForKVMSwitch: false) {
                remoteCompleted = true
            }
            XCTAssertTrue(remoteCompleted)
            XCTAssertEqual(ddc.readSelectors.count, readsBeforeRemoteAttempt)
            XCTAssertEqual(ddc.writeAttempts.map(\.input), [.usbC])
        }
    }

    func testCachedLocalReturnFailsClosedWhenNativeDisplayHasReallyDisconnected() {
        withDefaults { defaults in
            let ddc = FakeMonitorDDC(displays: [testDisplay()], currentInputValue: 17)
            let monitor = MonitorController(defaults: defaults, ddcOperations: ddc.operations)
            monitor.automationEnabled = true
            defer { monitor.automationEnabled = false }
            refreshAndWaitForDiscovery(monitor)
            ddc.displays = []
            ddc.nativeDisplayUnavailable = true
            refreshAndWaitForDiscovery(monitor)

            let returned = expectation(description: "Disconnected local return resolves safely")
            monitor.switchToLocal(wakeDisplayForKVMSwitch: false) {
                returned.fulfill()
            }
            wait(for: [returned], timeout: 5)

            XCTAssertEqual(ddc.readSelectors, [testDisplay().selector])
            XCTAssertEqual(ddc.writeAttempts.map(\.selector), [testDisplay().selector])
            XCTAssertFalse(monitor.isDisplaySelectorVerified)
            XCTAssertFalse(monitor.canStartAutomaticRemoteSwitching())
            XCTAssertTrue(monitor.status.contains("Native DDC/CI switch failed"))
            XCTAssertNotNil(monitor.diagnostic)
        }
    }

    func testCachedIdentityCannotAuthorizeAnotherSelectorOrCreatePresenceLease() {
        XCTAssertEqual(
            MonitorController.automaticSwitchDecision(
                displaySelector: "native-ddc:9:9:9",
                isDisplaySelectorVerified: false,
                hasCompletedDisplayDiscovery: true,
                role: .local,
                cachedDisplay: testDisplay()
            ),
            .useManualFallback
        )
        XCTAssertEqual(
            MonitorController.automaticSwitchDecision(
                displaySelector: testDisplay().selector,
                isDisplaySelectorVerified: false,
                hasCompletedDisplayDiscovery: true,
                role: .remote,
                cachedDisplay: testDisplay()
            ),
            .useManualFallback
        )
        XCTAssertFalse(
            MonitorController.shouldKeepDisplayAwake(
                automationEnabled: true,
                displaySelector: testDisplay().selector,
                detectedDisplays: [],
                confirmedRoute: nil,
                configurationGeneration: 0,
                transitionGraceActive: false
            )
        )
    }

    func testDisplayRouteStateConfirmsNoOpAndMarksReadbackFailureUnknown() {
        var state = DisplayRouteState(localInput: .usbC, remoteInput: .hdmi1)
        let request = DisplayRouteSwitchRequest(
            role: .remote,
            selector: "native-ddc:1:2:3",
            input: .hdmi1,
            configuration: state.configuration
        )
        XCTAssertTrue(state.enqueue(request))

        XCTAssertTrue(
            state.apply(
                request: request,
                outcome: .confirmed,
                currentSelector: request.selector
            )
        )
        XCTAssertEqual(state.confirmedRoute?.role, .remote)

        XCTAssertTrue(state.enqueue(request))
        XCTAssertTrue(
            state.apply(
                request: request,
                outcome: .unknown,
                currentSelector: request.selector
            )
        )
        XCTAssertEqual(state.confirmedRoute?.role, .unknown)
    }

    func testDisplayRouteStateIgnoresStaleCompletionAfterRoleChange() {
        var state = DisplayRouteState(localInput: .usbC, remoteInput: .hdmi1)
        let remoteRequest = DisplayRouteSwitchRequest(
            role: .remote,
            selector: "native-ddc:1:2:3",
            input: .hdmi1,
            configuration: state.configuration
        )
        let localRequest = DisplayRouteSwitchRequest(
            role: .local,
            selector: "native-ddc:1:2:3",
            input: .usbC,
            configuration: state.configuration
        )

        XCTAssertTrue(state.enqueue(remoteRequest))
        XCTAssertTrue(state.enqueue(localRequest))
        XCTAssertFalse(
            state.apply(
                request: remoteRequest,
                outcome: .confirmed,
                currentSelector: remoteRequest.selector
            )
        )
        XCTAssertTrue(
            state.apply(
                request: localRequest,
                outcome: .confirmed,
                currentSelector: localRequest.selector
            )
        )
        XCTAssertEqual(state.confirmedRoute?.role, .local)
    }

    func testDisplayRouteStateIgnoresStaleCompletionAfterConfigurationChange() {
        var state = DisplayRouteState(localInput: .usbC, remoteInput: .hdmi1)
        let request = DisplayRouteSwitchRequest(
            role: .remote,
            selector: "native-ddc:1:2:3",
            input: .hdmi1,
            configuration: state.configuration
        )

        state.configurationDidChange(localInput: .hdmi1, remoteInput: .usbC)

        XCTAssertFalse(
            state.apply(
                request: request,
                outcome: .confirmed,
                currentSelector: request.selector
            )
        )
        XCTAssertNil(state.confirmedRoute)
    }

    func testDisplayRouteStateIgnoresStaleCompletionAfterSelectorChange() {
        var state = DisplayRouteState(localInput: .usbC, remoteInput: .hdmi1)
        let request = DisplayRouteSwitchRequest(
            role: .remote,
            selector: "native-ddc:1:2:3",
            input: .hdmi1,
            configuration: state.configuration
        )

        XCTAssertFalse(
            state.apply(
                request: request,
                outcome: .confirmed,
                currentSelector: "native-ddc:9:9:9"
            )
        )
        XCTAssertNil(state.confirmedRoute)
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

    func testRoutePreservationRefreshDefersWhileDiscoveryIsInFlight() {
        let now = Date()
        XCTAssertTrue(
            MonitorController.shouldDeferRoutePreservationRefresh(
                isDiscoveringDisplays: true,
                attemptDeadline: now.addingTimeInterval(1),
                now: now
            )
        )
        XCTAssertFalse(
            MonitorController.shouldDeferRoutePreservationRefresh(
                isDiscoveringDisplays: true,
                attemptDeadline: now.addingTimeInterval(-1),
                now: now
            )
        )
        XCTAssertFalse(
            MonitorController.shouldDeferRoutePreservationRefresh(
                isDiscoveringDisplays: false,
                attemptDeadline: now.addingTimeInterval(1),
                now: now
            )
        )
        XCTAssertFalse(
            MonitorController.shouldDeferRoutePreservationRefresh(
                isDiscoveringDisplays: true,
                attemptDeadline: nil,
                now: now
            )
        )
    }

    func testDeferredSwitchPreservesDisplayWakeIntent() {
        var state = DeferredAutomaticSwitchState()

        _ = state.deferSwitch(
            input: .hdmi1,
            description: "this Mac",
            intent: .normal,
            completion: nil,
            shouldWakeDisplayForKVMSwitch: true
        )

        XCTAssertTrue(
            state.takeDeferredSwitch()?.shouldWakeDisplayForKVMSwitch == true
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

    func testSingleDetectedDDCDisplayIsSelectedWhenThereIsNoSavedSelector() {
        let display = DDCDisplay(
            index: 4,
            name: "External display 4",
            stableIdentifier: "native-ddc:2513:32884:1684300"
        )

        XCTAssertEqual(
            MonitorController.automaticSelector(
                for: [display],
                existingSelector: ""
            ),
            display.selector
        )
        XCTAssertNil(
            MonitorController.automaticSelector(
                for: [display],
                existingSelector: "native-ddc:old:selector"
            )
        )
    }

    func testAutomaticDisplaySelectionStaysExplicitForAmbiguousOrNonDDCLists() {
        let first = DDCDisplay(
            index: 1,
            name: "Display 1",
            stableIdentifier: "native-ddc:1:1:1"
        )
        let second = DDCDisplay(
            index: 2,
            name: "Display 2",
            stableIdentifier: "native-ddc:2:2:2"
        )
        let nonDDC = DDCDisplay(
            index: 3,
            name: "External display",
            stableIdentifier: nil
        )

        XCTAssertNil(
            MonitorController.automaticSelector(
                for: [first, second],
                existingSelector: ""
            )
        )
        XCTAssertNil(
            MonitorController.automaticSelector(
                for: [nonDDC],
                existingSelector: ""
            )
        )
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
            description: "the other device",
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

    func testDeferredSwitchResultIsResolvedOnlyByTheActualRouteOutcome() {
        var state = DeferredAutomaticSwitchState()
        var completions = 0
        var results: [Bool] = []

        _ = state.deferSwitch(
            input: .hdmi1,
            description: "the other device",
            intent: .normal,
            completion: { completions += 1 },
            result: { results.append($0) }
        )

        let pending = state.takeDeferredSwitch()
        pending?.completeCompletions()
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(results.isEmpty)

        pending?.result?(true)
        XCTAssertEqual(results, [true])
    }

    func testDeferredDisplayFirstSwitchKeepsItsLocalRecoveryInput() {
        var state = DeferredAutomaticSwitchState()
        _ = state.deferSwitch(
            input: .hdmi1,
            description: "the other device",
            intent: .normal,
            completion: nil,
            result: { _ in },
            recoveryInputOnFailure: .usbC
        )

        let pending = state.takeDeferredSwitch()
        XCTAssertEqual(pending?.input, .hdmi1)
        XCTAssertEqual(pending?.recoveryInputOnFailure, .usbC)
    }

    func testTerminationKeepsOnlyTheFinalLocalDeferredRoute() {
        var state = DeferredAutomaticSwitchState()
        var completed: [String] = []

        _ = state.deferSwitch(
            input: .hdmi1,
            description: "the other device",
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
            description: "the other device",
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
            description: "the other device",
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

    private func refreshAndWaitForDiscovery(
        _ monitor: MonitorController,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let discovered = expectation(description: "Native display discovery publication")
        let observation = monitor.$status
            .dropFirst()
            .filter { $0.hasPrefix("Detected ") || $0.hasPrefix("No DDC-capable") }
            .prefix(1)
            .sink { _ in discovered.fulfill() }
        monitor.refreshDetectedDisplays()
        wait(for: [discovered], timeout: 5)
        withExtendedLifetime(observation) {}
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

    private func testDisplay() -> DDCDisplay {
        DDCDisplay(
            index: 1,
            name: "Test display",
            stableIdentifier: "native-ddc:1:2:3"
        )
    }
}

private final class FakeMonitorDDC {
    struct WriteAttempt {
        let selector: String
        let input: MonitorInputSource
    }

    private let lock = NSLock()
    private var discoveredDisplays: [DDCDisplay]
    private var inputValue: UInt32
    private var unavailable = false
    private var reads: [String] = []
    private var writes: [WriteAttempt] = []

    init(displays: [DDCDisplay], currentInputValue: UInt32) {
        discoveredDisplays = displays
        inputValue = currentInputValue
    }

    var displays: [DDCDisplay] {
        get { locked { discoveredDisplays } }
        set { locked { discoveredDisplays = newValue } }
    }

    var nativeDisplayUnavailable: Bool {
        get { locked { unavailable } }
        set { locked { unavailable = newValue } }
    }

    var readSelectors: [String] { locked { reads } }
    var writeAttempts: [WriteAttempt] { locked { writes } }

    var operations: MonitorDDCOperations {
        MonitorDDCOperations(
            discover: { self.displays },
            currentInputValue: { selector in
                try self.locked {
                    self.reads.append(selector)
                    if self.unavailable {
                        throw NativeDDCServiceError(message: "Test native display disconnected")
                    }
                    return self.inputValue
                }
            },
            switchInput: { selector, input, vendorID, productID in
                try self.locked {
                    self.writes.append(WriteAttempt(selector: selector, input: input))
                    if self.unavailable {
                        throw NativeDDCServiceError(message: "Test native display disconnected")
                    }
                    self.inputValue = UInt32(MonitorInputMapping.rawValue(
                        for: input,
                        vendorID: vendorID,
                        productID: productID,
                        nativeSelector: selector
                    ))
                }
            }
        )
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
