import AppKit
import XCTest
@testable import MacKVM

final class SystemPowerLifecycleObserverTests: XCTestCase {
    func testForwardsWorkspaceSleepAndWakeNotifications() {
        let notificationCenter = NotificationCenter()
        var sleepCount = 0
        var wakeCount = 0
        let observer = SystemPowerLifecycleObserver(
            notificationCenter: notificationCenter,
            onWillSleep: { sleepCount += 1 },
            onDidWake: { wakeCount += 1 }
        )

        notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        XCTAssertEqual(sleepCount, 1)
        XCTAssertEqual(wakeCount, 1)
        withExtendedLifetime(observer) {}
    }
}
