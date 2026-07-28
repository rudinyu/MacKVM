import Foundation
import MacKVMCore
import XCTest
@testable import MacKVM

final class MonitorControllerTests: XCTestCase {
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
