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

    func testAddAndRemovePairing() {
        let registry = PairingRegistry(
            defaults: defaults,
            storageKey: "paired"
        )
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
        let registry = PairingRegistry(
            defaults: defaults,
            storageKey: "all"
        )
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
        let registry = PairingRegistry(
            defaults: defaults,
            storageKey: "generation"
        )
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

    func testPairingsPersistAcrossRegistryInstances() {
        let peerID = UUID()
        let peer = PeerIdentity(
            id: peerID,
            name: "Desk Mac",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )
        PairingRegistry(
            defaults: defaults,
            storageKey: "paired"
        ).add(peer)

        let reloaded = PairingRegistry(
            defaults: defaults,
            storageKey: "paired"
        )

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
        let registry = PairingRegistry(
            defaults: defaults,
            storageKey: "profiles"
        )

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

        let reloaded = PairingRegistry(
            defaults: defaults,
            storageKey: "profiles"
        )
        let profile = reloaded.profile(for: peerID)
        XCTAssertEqual(profile?.friendlyName, "Studio M5")
        XCTAssertEqual(profile?.model, "MacBookPro18,4")
        XCTAssertEqual(profile?.lastConnectedAt, secondConnection)
        XCTAssertEqual(
            profile?.keyFingerprint,
            PeerKeyFingerprint.string(for: peer.signingPublicKey)
        )
        XCTAssertEqual(profile?.keyFingerprint.split(separator: ":").count, 32)
    }

    func testLegacyPairingWithoutProfileDoesNotSynthesizePersistentMetadata() throws {
        let peerID = UUID()
        let publicKey = P256.Signing.PrivateKey()
            .publicKey.x963Representation
        defaults.set(
            try JSONEncoder().encode([peerID.uuidString: publicKey]),
            forKey: "legacy"
        )

        let registry = PairingRegistry(
            defaults: defaults,
            storageKey: "legacy"
        )

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
        let registry = PairingRegistry(
            defaults: defaults,
            storageKey: "legacy-profile"
        )

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
        let registry = PairingRegistry(
            defaults: defaults,
            storageKey: "profile-removal"
        )
        registry.add(peer, model: "MacBookPro16,1")
        XCTAssertNotNil(registry.profile(for: peer.id))

        registry.remove(peer.id)

        XCTAssertNil(registry.profile(for: peer.id))
        XCTAssertTrue(registry.pairedPeerProfiles.isEmpty)
    }

    func testConcurrentAddsPreserveEveryPeer() {
        let registry = PairingRegistry(
            defaults: defaults,
            storageKey: "concurrent"
        )
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

    func testCorruptPreferencesWithCaseVariantUUIDsDoNotCrash() throws {
        let peerID = UUID()
        let firstKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let secondKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let stored = [
            peerID.uuidString: firstKey,
            peerID.uuidString.lowercased(): secondKey,
        ]
        defaults.set(try JSONEncoder().encode(stored), forKey: "corrupt")

        let registry = PairingRegistry(
            defaults: defaults,
            storageKey: "corrupt"
        )

        XCTAssertNoThrow(_ = registry.pairedPeers)
        XCTAssertTrue(registry.pairedPeerIDs.isEmpty)
        XCTAssertFalse(registry.contains(peerID))
    }
}
