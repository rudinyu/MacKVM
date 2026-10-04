import CryptoKit
import Foundation
import XCTest
@testable import MacKVMCore

final class PairingRevocationFailureTests: XCTestCase {
    private final class FailureSwitch {
        private let lock = NSLock()
        private var value = false

        var fails: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    func testFailedRevocationKeepsRuntimeRevokedAndRetryRemovesDurableTrust() throws {
        let suiteName = "PairingRevocationFailureTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let failure = FailureSwitch()
        let registry = PairingRegistry(
            testDefaults: defaults,
            storageKey: "peers",
            persistenceApplicationID: suiteName,
            shouldFailPersistence: { failure.fails }
        )
        let peer = makePeer()
        let oldGeneration = registry.generation(for: peer.id)
        XCTAssertTrue(registry.add(peer, ifGeneration: oldGeneration))
        let oldPeers = try XCTUnwrap(defaults.data(forKey: "peers"))
        let oldProfiles = try XCTUnwrap(defaults.data(forKey: "peers.profiles"))

        failure.fails = true
        let result = registry.revokeWithPersistenceResult(peer.id)

        XCTAssertFalse(result.persisted)
        XCTAssertEqual(result.generation, oldGeneration + 1)
        XCTAssertEqual(registry.generation(for: peer.id), result.generation)
        XCTAssertFalse(registry.contains(peer.id))
        XCTAssertNil(registry.profile(for: peer.id))
        XCTAssertFalse(registry.seamlessControlAuthorized(for: peer.id))
        XCTAssertFalse(registry.add(peer, ifGeneration: oldGeneration))
        XCTAssertEqual(defaults.data(forKey: "peers"), oldPeers)
        XCTAssertEqual(defaults.data(forKey: "peers.profiles"), oldProfiles)
        XCTAssertTrue(PairingRegistry(
            testDefaults: defaults,
            storageKey: "peers",
            persistenceApplicationID: suiteName
        ).contains(peer.id))

        failure.fails = false
        let retry = registry.revokeWithPersistenceResult(peer.id)

        XCTAssertTrue(retry.persisted)
        XCTAssertEqual(retry.generation, result.generation + 1)
        let reloaded = PairingRegistry(
            testDefaults: defaults,
            storageKey: "peers",
            persistenceApplicationID: suiteName
        )
        XCTAssertFalse(reloaded.contains(peer.id))
        XCTAssertNil(reloaded.profile(for: peer.id))
    }

    func testSingleAndAllRemovalExposePersistenceFailureWithoutRestoringRuntimeTrust() throws {
        let suiteName = "PairingRevocationFailureTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let failure = FailureSwitch()
        let registry = PairingRegistry(
            testDefaults: defaults,
            storageKey: "peers",
            persistenceApplicationID: suiteName,
            shouldFailPersistence: { failure.fails }
        )
        let first = makePeer()
        let second = makePeer()
        XCTAssertTrue(registry.add(first, ifGeneration: 0))
        XCTAssertTrue(registry.add(second, ifGeneration: 0))
        let oldPeers = defaults.data(forKey: "peers")
        let oldProfiles = defaults.data(forKey: "peers.profiles")

        failure.fails = true
        XCTAssertFalse(registry.removeWithPersistenceResult(first.id))
        XCTAssertFalse(registry.contains(first.id))
        XCTAssertTrue(registry.contains(second.id))
        XCTAssertFalse(registry.removeAllWithPersistenceResult())
        XCTAssertTrue(registry.pairedPeerIDs.isEmpty)
        XCTAssertTrue(registry.pairedPeerProfiles.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "peers"), oldPeers)
        XCTAssertEqual(defaults.data(forKey: "peers.profiles"), oldProfiles)

        failure.fails = false
        XCTAssertTrue(registry.removeAllWithPersistenceResult())
        let reloaded = PairingRegistry(
            testDefaults: defaults,
            storageKey: "peers",
            persistenceApplicationID: suiteName
        )
        XCTAssertTrue(reloaded.pairedPeerIDs.isEmpty)
        XCTAssertTrue(reloaded.pairedPeerProfiles.isEmpty)
    }

    func testConditionalRollbackCannotOvertakeFailedForgetOrRevokeNewTrust() throws {
        let suiteName = "PairingRevocationFailureTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let failure = FailureSwitch()
        let registry = PairingRegistry(
            testDefaults: defaults, storageKey: "peers",
            persistenceApplicationID: suiteName,
            shouldFailPersistence: { failure.fails }
        )
        let peer = makePeer()
        XCTAssertTrue(registry.add(peer, ifGeneration: 0))
        failure.fails = true
        let forgotten = registry.revokeWithPersistenceResult(peer.id)

        XCTAssertNil(registry.revokeWithPersistenceResult(
            peer.id, ifGeneration: 0, publicKey: peer.signingPublicKey
        ))
        XCTAssertFalse(forgotten.persisted)
        XCTAssertEqual(registry.generation(for: peer.id), forgotten.generation)
        XCTAssertFalse(registry.contains(peer.id))

        failure.fails = false
        let newPeer = PeerIdentity(
            id: peer.id, name: "New key",
            signingPublicKey: P256.Signing.PrivateKey().publicKey.x963Representation
        )
        XCTAssertTrue(registry.add(newPeer, ifGeneration: forgotten.generation))
        XCTAssertNil(registry.revokeWithPersistenceResult(
            peer.id, ifGeneration: forgotten.generation, publicKey: peer.signingPublicKey
        ))
        XCTAssertEqual(registry.publicKey(for: peer.id), newPeer.signingPublicKey)
        XCTAssertEqual(registry.generation(for: peer.id), forgotten.generation)
    }

    private func makePeer() -> PeerIdentity {
        PeerIdentity(
            name: "Test Mac",
            signingPublicKey: P256.Signing.PrivateKey().publicKey.x963Representation
        )
    }
}
