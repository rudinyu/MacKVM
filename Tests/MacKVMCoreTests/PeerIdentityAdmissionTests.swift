import CryptoKit
import XCTest
@testable import MacKVMCore

final class PeerIdentityAdmissionTests: XCTestCase {
    func testAcceptsUniqueAndSameKeyDuplicates() {
        let key = P256.Signing.PrivateKey()
        let candidate = PeerIdentity(
            name: "Mac",
            signingPublicKey: key.publicKey.x963Representation
        )

        XCTAssertEqual(
            PeerIdentityAdmission.collision(for: candidate, existing: nil),
            .unique
        )
        XCTAssertEqual(
            PeerIdentityAdmission.collision(for: candidate, existing: candidate),
            .duplicate
        )
    }

    func testRejectsConflictingKeyForTheSameUUID() {
        let firstKey = P256.Signing.PrivateKey()
        let secondKey = P256.Signing.PrivateKey()
        let candidate = PeerIdentity(
            name: "Mac",
            signingPublicKey: firstKey.publicKey.x963Representation
        )
        let conflicting = PeerIdentity(
            id: candidate.id,
            name: "Mac",
            signingPublicKey: secondKey.publicKey.x963Representation
        )

        XCTAssertEqual(
            PeerIdentityAdmission.collision(
                for: conflicting,
                existing: candidate
            ),
            .conflictingKey
        )
    }

    func testResolveKeepsDuplicatesButDropsConflictingIdentity() {
        let firstKey = P256.Signing.PrivateKey()
        let duplicateKey = firstKey
        let conflictingKey = P256.Signing.PrivateKey()
        let first = PeerIdentity(
            name: "First",
            signingPublicKey: firstKey.publicKey.x963Representation
        )
        let duplicate = PeerIdentity(
            id: first.id,
            name: "Same key",
            signingPublicKey: duplicateKey.publicKey.x963Representation
        )
        let conflicting = PeerIdentity(
            id: first.id,
            name: "Conflicting key",
            signingPublicKey: conflictingKey.publicKey.x963Representation
        )
        let unique = PeerIdentity(
            name: "Unique",
            signingPublicKey: P256.Signing.PrivateKey()
                .publicKey.x963Representation
        )

        let resolved = PeerIdentityAdmission.resolve(
            [
                (first, "first"),
                (duplicate, "duplicate"),
                (conflicting, "conflicting"),
                (unique, "unique")
            ],
            identity: { $0.0 }
        )

        XCTAssertNil(resolved[first.id])
        XCTAssertEqual(resolved[unique.id]?.1, "unique")
    }

    func testResolvePinnedKeepsTrustedEndpointsAndDropsConflictingTXTKeys() {
        let pinnedKey = P256.Signing.PrivateKey()
        let conflictingKey = P256.Signing.PrivateKey()
        let identity = PeerIdentity(
            name: "Trusted Mac",
            signingPublicKey: pinnedKey.publicKey.x963Representation
        )
        let sameKeyDuplicate = PeerIdentity(
            id: identity.id,
            name: "Trusted Mac duplicate",
            signingPublicKey: pinnedKey.publicKey.x963Representation
        )
        let conflicting = PeerIdentity(
            id: identity.id,
            name: "Spoofed Mac",
            signingPublicKey: conflictingKey.publicKey.x963Representation
        )

        let resolved = PeerIdentityAdmission.resolvePinned(
            [
                (conflicting, "spoofed endpoint"),
                (sameKeyDuplicate, "trusted endpoint"),
                (identity, "second trusted endpoint")
            ],
            pinnedKeys: [identity.id: identity.signingPublicKey],
            maximumCandidatesPerID: 2,
            identity: { $0.0 }
        )

        XCTAssertEqual(
            resolved[identity.id]?.map(\.1),
            ["trusted endpoint", "second trusted endpoint"]
        )
    }
}
