import AppKit
import CryptoKit
import XCTest
@testable import MacKVM
@testable import MacKVMCore

/// Covers the `SecureSessionService` sleep/wake state machine itself rather
/// than only the notification plumbing: reconnect intent across sleep, the
/// guards that suppress reconnect scheduling, the wake retry ordering, and the
/// latch's recovery paths.
final class SecureSessionSleepLifecycleTests: XCTestCase {
    private final class InMemoryPrivateKeyStore: DevicePrivateKeyStore {
        private var keyData: Data?

        func load() throws -> Data? { keyData }
        func save(_ keyData: Data) throws { self.keyData = keyData }
        func delete() throws { keyData = nil }
    }

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "app.mackvm.sleep-lifecycle-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Fixture

    private func makeService(
        powerNotificationCenter: NotificationCenter? = nil,
        systemSleepLatchTimeout: TimeInterval =
            SecureSessionService.defaultSystemSleepLatchTimeout
    ) throws -> SecureSessionService {
        let credentials = try DeviceCredentialsStore.load(
            from: defaults,
            fallbackName: "Test Mac",
            keyStore: InMemoryPrivateKeyStore()
        )
        let registry = PairingRegistry(
            testDefaults: defaults,
            storageKey: "paired-peers",
            persistenceApplicationID: suiteName
        )
        return SecureSessionService(
            credentials: credentials,
            registry: registry,
            localModel: "Mac16,1",
            powerNotificationCenter: powerNotificationCenter,
            // Keep Bonjour out of the unit test; the sleep lifecycle is the
            // subject, not the listener and browser it restarts.
            networkServicesEnabled: false,
            systemSleepLatchTimeout: systemSleepLatchTimeout
        )
    }

    // MARK: - Reconnect intent

    func testSleepKeepsReconnectIntentAndPausesScheduling() throws {
        let service = try makeService()
        let peerID = UUID()

        service.connect(to: peerID)
        service.prepareForSleep()

        let snapshot = service.sleepLifecycleSnapshot
        XCTAssertTrue(snapshot.isSystemSleeping)
        // The user's selected peer survives sleep so wake can resume it, but
        // no reconnect may remain armed while the transport is torn down.
        XCTAssertEqual(snapshot.desiredPeerID, peerID)
        XCTAssertFalse(snapshot.hasScheduledReconnect)
        XCTAssertEqual(snapshot.reconnectAttempt, 0)
    }

    func testDeliberateDisconnectIsNotResumedByWake() throws {
        let service = try makeService()

        service.connect(to: UUID())
        service.disconnect()
        service.prepareForSleep()
        service.resumeAfterWake()

        let snapshot = service.sleepLifecycleSnapshot
        XCTAssertFalse(snapshot.isSystemSleeping)
        // Disconnect cleared the intent, so waking must not create a session.
        XCTAssertNil(snapshot.desiredPeerID)
        XCTAssertFalse(snapshot.hasScheduledReconnect)
    }

    // MARK: - Wake reconnect ordering

    func testWakeSkipsTheGuaranteedEmptyZeroDelayReconnect() throws {
        let service = try makeService()
        let peerID = UUID()

        service.connect(to: peerID)
        service.prepareForSleep()
        service.resumeAfterWake()

        let snapshot = service.sleepLifecycleSnapshot
        XCTAssertFalse(snapshot.isSystemSleeping)
        XCTAssertEqual(snapshot.desiredPeerID, peerID)
        XCTAssertTrue(snapshot.hasScheduledReconnect)
        // prepareForSleep() emptied the peer table and the browser is only
        // restarting now, so attempt 0 (a zero-delay retry) would always find
        // no candidate and publish a false "service is not available" status.
        // Seeding attempt 1 leaves the counter at 2 after scheduling; a
        // zero-delay first attempt would leave it at 1.
        XCTAssertEqual(snapshot.reconnectAttempt, 2)
    }

    func testResumeWithoutASleepIsANoOp() throws {
        let service = try makeService()

        service.resumeAfterWake()
        drainMainQueue()

        let snapshot = service.sleepLifecycleSnapshot
        XCTAssertFalse(snapshot.isSystemSleeping)
        XCTAssertEqual(snapshot.reconnectAttempt, 0)
        XCTAssertFalse(snapshot.hasScheduledReconnect)
        // A wake that was never preceded by a sleep must not announce a
        // resume the user never triggered.
        XCTAssertEqual(service.status, "Secure session idle")
    }

    func testRepeatedSleepNotificationsDoNotReArmTheTeardown() throws {
        let service = try makeService()
        let peerID = UUID()

        service.connect(to: peerID)
        service.prepareForSleep()
        service.prepareForSleep()
        service.resumeAfterWake()

        let snapshot = service.sleepLifecycleSnapshot
        XCTAssertFalse(snapshot.isSystemSleeping)
        XCTAssertEqual(snapshot.desiredPeerID, peerID)
        XCTAssertEqual(snapshot.reconnectAttempt, 2)
    }

    // MARK: - Latch recovery

    func testSleepLatchSelfClearsWhenWakeNeverArrives() throws {
        let service = try makeService(systemSleepLatchTimeout: 0.05)
        let peerID = UUID()

        service.connect(to: peerID)
        service.prepareForSleep()
        XCTAssertTrue(service.sleepLifecycleSnapshot.isSystemSleeping)

        // A willSleep with no matching didWake must not gate secure
        // networking for the rest of the process lifetime.
        waitUntil { !service.sleepLifecycleSnapshot.isSystemSleeping }
        XCTAssertEqual(service.sleepLifecycleSnapshot.desiredPeerID, peerID)
    }

    func testUserConnectClearsALatchedSleepFlag() throws {
        let service = try makeService()
        let peerID = UUID()

        service.prepareForSleep()
        XCTAssertTrue(service.sleepLifecycleSnapshot.isSystemSleeping)

        service.connect(to: peerID)

        // An explicit Connect is the user's own recovery action; it must not
        // be silently dropped by a stale sleep latch.
        let snapshot = service.sleepLifecycleSnapshot
        XCTAssertFalse(snapshot.isSystemSleeping)
        XCTAssertEqual(snapshot.desiredPeerID, peerID)
    }

    // MARK: - Workspace notification wiring

    func testWorkspaceNotificationsDriveTheSessionLifecycle() throws {
        let notificationCenter = NotificationCenter()
        let service = try makeService(
            powerNotificationCenter: notificationCenter
        )
        let peerID = UUID()
        service.start()
        service.connect(to: peerID)
        // Reading the snapshot synchronizes on the session queue, so the
        // observer registration queued by start() has run before the post.
        XCTAssertEqual(service.sleepLifecycleSnapshot.desiredPeerID, peerID)

        notificationCenter.post(
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        XCTAssertTrue(service.sleepLifecycleSnapshot.isSystemSleeping)

        notificationCenter.post(
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        let snapshot = service.sleepLifecycleSnapshot
        XCTAssertFalse(snapshot.isSystemSleeping)
        XCTAssertEqual(snapshot.desiredPeerID, peerID)

        service.stop()
    }

    // MARK: - Helpers

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition())
    }

    private func drainMainQueue() {
        let drained = expectation(description: "Drain main queue")
        DispatchQueue.main.async {
            drained.fulfill()
        }
        wait(for: [drained], timeout: 1)
    }
}
