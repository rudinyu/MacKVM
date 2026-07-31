import Foundation
import XCTest
@testable import MacKVMCore

final class PeerIdentityTests: XCTestCase {
    func testCredentialsPersistAcrossLoads() throws {
        let suiteName = "PeerIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keyStore = InMemoryPrivateKeyStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let first = try DeviceCredentialsStore.load(
            from: defaults,
            fallbackName: "Rudin's MacBook Pro",
            keyStore: keyStore
        )
        let second = try DeviceCredentialsStore.load(
            from: defaults,
            fallbackName: "Another Name",
            keyStore: keyStore
        )

        XCTAssertEqual(first.identity, second.identity)
        XCTAssertEqual(
            first.privateKey.rawRepresentation,
            second.privateKey.rawRepresentation
        )
        XCTAssertFalse(first.wasLoadedFromStorage)
        XCTAssertTrue(second.wasLoadedFromStorage)
        XCTAssertEqual(first.identity.name, "Rudin's MacBook Pro")
        XCTAssertEqual(
            first.identity.serviceName,
            "MacKVM-\(first.identity.id.uuidString)"
        )
    }

    func testMissingPrivateKeyDoesNotSilentlyRotateIdentity() throws {
        let suiteName = "PeerIdentityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let keyStore = InMemoryPrivateKeyStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        _ = try DeviceCredentialsStore.load(
            from: defaults,
            keyStore: keyStore
        )
        keyStore.remove()

        XCTAssertThrowsError(
            try DeviceCredentialsStore.load(
                from: defaults,
                keyStore: keyStore
            )
        ) { error in
            XCTAssertEqual(
                error as? DeviceCredentialError,
                .identityKeyMismatch
            )
        }
    }

    func testSharedPeerArbitrationUsesLowerUUID() {
        let lower = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let higher = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!

        XCTAssertTrue(
            PeerArbitration.localIDWins(
                localID: lower,
                remoteID: higher
            )
        )
        XCTAssertFalse(
            PeerArbitration.localIDWins(
                localID: higher,
                remoteID: lower
            )
        )
    }
}

private final class InMemoryPrivateKeyStore: DevicePrivateKeyStore {
    private var data: Data?

    func load() throws -> Data? {
        data
    }

    func save(_ keyData: Data) throws {
        data = keyData
    }

    func remove() {
        data = nil
    }
}
