import Foundation

public enum PeerIdentityCollision: Equatable, Sendable {
    case unique
    case duplicate
    case conflictingKey
}

/// Resolves duplicate Bonjour identities without allowing result order to
/// select a different signing key for the same UUID.
public enum PeerIdentityAdmission {
    public static func collision(
        for candidate: PeerIdentity,
        existing: PeerIdentity?
    ) -> PeerIdentityCollision {
        guard let existing else { return .unique }
        return existing.signingPublicKey == candidate.signingPublicKey
            ? .duplicate
            : .conflictingKey
    }

    /// Keeps one candidate per UUID and rejects every candidate for a UUID
    /// once different signing keys are observed. This makes Bonjour result
    /// ordering unable to select a key for a conflicting identity.
    public static func resolve<S: Sequence>(
        _ candidates: S,
        identity: (S.Element) -> PeerIdentity
    ) -> [UUID: S.Element] {
        var accepted: [UUID: S.Element] = [:]
        var acceptedIdentities: [UUID: PeerIdentity] = [:]
        var conflictingIDs = Set<UUID>()

        for candidate in candidates {
            let candidateIdentity = identity(candidate)
            let id = candidateIdentity.id
            guard !conflictingIDs.contains(id) else { continue }
            switch collision(
                for: candidateIdentity,
                existing: acceptedIdentities[id]
            ) {
            case .unique:
                accepted[id] = candidate
                acceptedIdentities[id] = candidateIdentity
            case .duplicate:
                continue
            case .conflictingKey:
                accepted.removeValue(forKey: id)
                acceptedIdentities.removeValue(forKey: id)
                conflictingIDs.insert(id)
            }
        }
        return accepted
    }
}
