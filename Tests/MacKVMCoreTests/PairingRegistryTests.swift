import CryptoKit
import Foundation
import XCTest
@testable import MacKVMCore

final class PairingRegistryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PairingRegistryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func waitForPersistence(
        timeout: TimeInterval = 2,
        where condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition())
    }

    private func makeRegistry(storageKey: String) -> PairingRegistry {
        PairingRegistry(
            testDefaults: defaults,
            storageKey: storageKey,
            persistenceApplicationID: suiteName
        )
    }

    func testAddAndRemovePairing() {
        let registry = makeRegistry(storageKey: "paired")
        let peerID = UUID()
        let peer = PeerIdentity(
            id: peerID,
            name: "Desk Mac",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )

        registry.add(peer)
        XCTAssertTrue(registry.contains(peerID))
        XCTAssertEqual(
            registry.publicKey(for: peerID),
            peer.signingPublicKey
        )

        registry.remove(peerID)
        XCTAssertFalse(registry.contains(peerID))
    }

    func testRemoveAllClearsEveryPairing() {
        let registry = makeRegistry(storageKey: "all")
        let peers = (0..<3).map { index in
            PeerIdentity(
                name: "Mac \(index)",
                signingPublicKey: P256.Signing.PrivateKey()
                    .publicKey.x963Representation
            )
        }
        peers.forEach { registry.add($0) }
        XCTAssertEqual(registry.pairedPeerIDs, Set(peers.map(\.id)))

        registry.removeAll()

        XCTAssertTrue(registry.pairedPeerIDs.isEmpty)
    }

    func testRevocationGenerationRejectsAStaleAdd() {
        let registry = makeRegistry(storageKey: "generation")
        let peer = PeerIdentity(
            name: "Desk Mac",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )
        let generation = registry.generation(for: peer.id)

        registry.revoke(peer.id)

        XCTAssertFalse(registry.add(peer, ifGeneration: generation))
        XCTAssertFalse(registry.contains(peer.id))
        XCTAssertTrue(
            registry.add(
                peer,
                ifGeneration: registry.generation(for: peer.id)
            )
        )
        XCTAssertTrue(registry.contains(peer.id))
    }

    func testRevocationIsDurableBeforeReturning() {
        let peer = PeerIdentity(
            name: "Forget Me",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )
        let registry = makeRegistry(storageKey: "durable-revocation")
        registry.add(peer)

        registry.revoke(peer.id)

        let reloaded = makeRegistry(storageKey: "durable-revocation")
        XCTAssertFalse(reloaded.contains(peer.id))
        XCTAssertNil(reloaded.profile(for: peer.id))
    }

    func testPairingsPersistAcrossRegistryInstances() {
        let peerID = UUID()
        let peer = PeerIdentity(
            id: peerID,
            name: "Desk Mac",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )
        makeRegistry(storageKey: "paired").add(peer)
        waitForPersistence {
            self.defaults.data(forKey: "paired") != nil
        }

        let reloaded = makeRegistry(storageKey: "paired")

        XCTAssertEqual(reloaded.pairedPeerIDs, [peerID])
        XCTAssertEqual(
            reloaded.publicKey(for: peerID),
            peer.signingPublicKey
        )
    }

    func testPairingProfilePersistsMetadataAndConnectionTime() {
        let peerID = UUID()
        let peer = PeerIdentity(
            id: peerID,
            name: "M5 Pro",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )
        let firstConnection = Date(timeIntervalSince1970: 1_700_000_000)
        let secondConnection = Date(timeIntervalSince1970: 1_700_000_123)
        let registry = makeRegistry(storageKey: "profiles")

        registry.add(peer, model: "MacBookPro18,3")
        XCTAssertEqual(registry.profile(for: peerID)?.friendlyName, "M5 Pro")
        XCTAssertEqual(registry.profile(for: peerID)?.model, "MacBookPro18,3")
        XCTAssertNil(registry.profile(for: peerID)?.lastConnectedAt)

        XCTAssertTrue(
            registry.recordConnection(
                for: peerID,
                at: firstConnection
            )
        )
        XCTAssertEqual(
            registry.profile(for: peerID)?.lastConnectedAt,
            firstConnection
        )
        XCTAssertTrue(
            registry.updateFriendlyName(
                for: peerID,
                friendlyName: "Studio M5"
            )
        )
        XCTAssertTrue(
            registry.recordConnection(
                for: peerID,
                model: "MacBookPro18,4",
                friendlyName: "Advertised Mac",
                at: secondConnection
            )
        )

        waitForPersistence {
            guard let data = self.defaults.data(forKey: "profiles.profiles"),
                  let profiles = try? JSONDecoder().decode(
                      [String: PairedPeerProfile].self,
                      from: data
                  ) else {
                return false
            }
            return profiles.values.contains {
                $0.friendlyName == "Studio M5"
                    && $0.model == "MacBookPro18,4"
                    && $0.lastConnectedAt == secondConnection
            }
        }

        let reloaded = makeRegistry(storageKey: "profiles")
        let profile = reloaded.profile(for: peerID)
        XCTAssertEqual(profile?.friendlyName, "Studio M5")
        XCTAssertEqual(profile?.model, "MacBookPro18,4")
        XCTAssertEqual(profile?.lastConnectedAt, secondConnection)
        XCTAssertTrue(profile?.seamlessControlAuthorized ?? false)
        XCTAssertEqual(
            profile?.keyFingerprint,
            PeerKeyFingerprint.string(for: peer.signingPublicKey)
        )
        XCTAssertEqual(profile?.keyFingerprint.split(separator: ":").count, 32)
    }

    func testSeamlessControlAuthorizationIsPerPeerAndPersists() {
        let first = PeerIdentity(
            name: "M5 Pro",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )
        let second = PeerIdentity(
            name: "Intel Mac",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )
        let registry = makeRegistry(storageKey: "seamless")
        registry.add(first)
        registry.add(second)
        XCTAssertTrue(
            registry.updateSeamlessControlAuthorization(
                for: second.id,
                authorized: false
            )
        )

        XCTAssertTrue(registry.seamlessControlAuthorized(for: first.id))
        XCTAssertFalse(registry.seamlessControlAuthorized(for: second.id))
        XCTAssertTrue(
            registry.updateSeamlessControlAuthorization(
                for: first.id,
                authorized: true
            )
        )

        XCTAssertTrue(registry.seamlessControlAuthorized(for: first.id))
        XCTAssertFalse(registry.seamlessControlAuthorized(for: second.id))

        let reloaded = makeRegistry(storageKey: "seamless")
        XCTAssertTrue(reloaded.seamlessControlAuthorized(for: first.id))

        reloaded.revoke(first.id)
        XCTAssertFalse(reloaded.seamlessControlAuthorized(for: first.id))
    }

    func testReplacingSigningKeyDoesNotReuseTheOldProfileAuthorization() {
        let peerID = UUID()
        let first = PeerIdentity(
            id: peerID,
            name: "Old Mac",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )
        let replacement = PeerIdentity(
            id: peerID,
            name: "Replacement Mac",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )
        let registry = makeRegistry(storageKey: "profile-key-replacement")

        registry.add(first)
        XCTAssertTrue(
            registry.updateSeamlessControlAuthorization(
                for: peerID,
                authorized: false
            )
        )

        registry.add(replacement)

        XCTAssertEqual(
            registry.profile(for: peerID)?.friendlyName,
            replacement.name
        )
        XCTAssertTrue(registry.seamlessControlAuthorized(for: peerID))
        XCTAssertEqual(
            registry.profile(for: peerID)?.signingPublicKey,
            replacement.signingPublicKey
        )
    }

    func testLegacyProfileDefaultsSeamlessAuthorizationToFalse() throws {
        let peerID = UUID()
        let publicKey = P256.Signing.PrivateKey()
            .publicKey.x963Representation
        let legacyProfile = PairedPeerProfile(
            peerID: peerID,
            friendlyName: "Legacy Mac",
            model: "MacBookPro16,1",
            signingPublicKey: publicKey
        )
        let encoded = try JSONEncoder().encode(legacyProfile)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var withoutNewField = object
        withoutNewField.removeValue(forKey: "seamlessControlAuthorized")
        let decoded = try JSONDecoder().decode(
            PairedPeerProfile.self,
            from: JSONSerialization.data(withJSONObject: withoutNewField)
        )
        XCTAssertFalse(decoded.seamlessControlAuthorized)
    }

    func testLegacyPairingWithoutProfileDoesNotSynthesizePersistentMetadata() throws {
        let peerID = UUID()
        let publicKey = P256.Signing.PrivateKey()
            .publicKey.x963Representation
        defaults.set(
            try JSONEncoder().encode([peerID.uuidString: publicKey]),
            forKey: "legacy"
        )

        let registry = makeRegistry(storageKey: "legacy")

        XCTAssertTrue(registry.contains(peerID))
        XCTAssertNil(registry.profile(for: peerID))
        XCTAssertTrue(registry.pairedPeerProfiles.isEmpty)
        XCTAssertTrue(
            registry.recordConnection(
                for: peerID,
                model: "MacBookPro18,3",
                friendlyName: "Trusted Studio Mac"
            )
        )
        XCTAssertEqual(
            registry.profile(for: peerID)?.friendlyName,
            "Trusted Studio Mac"
        )
    }

    func testAuthenticatedNameReplacesPersistedGeneratedFallback() {
        let peerID = UUID()
        let peer = PeerIdentity(
            id: peerID,
            name: "Trusted Studio Mac",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )
        let registry = makeRegistry(storageKey: "legacy-profile")

        registry.add(peer)
        let generatedName = "Mac \(peerID.uuidString.prefix(8))"
        XCTAssertTrue(
            registry.updateFriendlyName(
                for: peerID,
                friendlyName: generatedName
            )
        )
        XCTAssertTrue(
            registry.recordConnection(
                for: peerID,
                friendlyName: peer.name
            )
        )

        XCTAssertEqual(
            registry.profile(for: peerID)?.friendlyName,
            peer.name
        )
    }

    func testProfileMetadataIsRemovedWhenPairingIsRemoved() {
        let peer = PeerIdentity(
            name: "Desk Mac",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )
        let registry = makeRegistry(storageKey: "profile-removal")
        registry.add(peer, model: "MacBookPro16,1")
        XCTAssertNotNil(registry.profile(for: peer.id))

        registry.remove(peer.id)

        XCTAssertNil(registry.profile(for: peer.id))
        XCTAssertTrue(registry.pairedPeerProfiles.isEmpty)
    }

    func testConcurrentAddsPreserveEveryPeer() {
        let registry = makeRegistry(storageKey: "concurrent")
        let peers = (0..<32).map { index in
            PeerIdentity(
                name: "Mac \(index)",
                signingPublicKey: P256.Signing.PrivateKey()
                    .publicKey.x963Representation
            )
        }
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "PairingRegistryTests.concurrent",
            attributes: .concurrent
        )

        for peer in peers {
            group.enter()
            queue.async {
                registry.add(peer)
                group.leave()
            }
        }
        group.wait()

        XCTAssertEqual(registry.pairedPeerIDs, Set(peers.map(\.id)))
    }

    func testAsynchronousAddPublishesTrustBeforeTheDefaultsWriteCompletes() {
        let peer = PeerIdentity(
            name: "Async Pairing Mac",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )
        let registry = makeRegistry(storageKey: "async-pairing")

        XCTAssertTrue(
            registry.add(
                peer,
                ifGeneration: registry.generation(for: peer.id),
                persistImmediately: false
            )
        )
        XCTAssertEqual(registry.publicKey(for: peer.id), peer.signingPublicKey)
        XCTAssertEqual(registry.profile(for: peer.id)?.friendlyName, peer.name)

        let persisted = expectation(description: "asynchronous pairing write")
        DispatchQueue.global().async {
            for _ in 0..<200 {
                if self.defaults.data(forKey: "async-pairing") != nil {
                    persisted.fulfill()
                    return
                }
                usleep(10_000)
            }
        }
        wait(for: [persisted], timeout: 3)

        let reloaded = makeRegistry(storageKey: "async-pairing")
        XCTAssertEqual(reloaded.publicKey(for: peer.id), peer.signingPublicKey)
    }

    func testCorruptPreferencesWithCaseVariantUUIDsDoNotCrash() throws {
        let peerID = UUID()
        let firstKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let secondKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let stored = [
            peerID.uuidString: firstKey,
            peerID.uuidString.lowercased(): secondKey,
        ]
        defaults.set(try JSONEncoder().encode(stored), forKey: "corrupt")

        let registry = makeRegistry(storageKey: "corrupt")

        XCTAssertNoThrow(_ = registry.pairedPeers)
        XCTAssertTrue(registry.pairedPeerIDs.isEmpty)
        XCTAssertFalse(registry.contains(peerID))
    }
}
