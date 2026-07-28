import Foundation

public enum PairingRequestDecision: Equatable {
    case allow
    case rejectChangedKey
    case rejectDuplicateRequest
    case rejectDuplicateSender
    case rejectAtCapacity
}

public enum PairingRequestPolicy {
    public static func keepOutboundDuringCollision(
        localID: UUID,
        remoteID: UUID
    ) -> Bool {
        PeerArbitration.localIDWins(
            localID: localID,
            remoteID: remoteID
        )
    }

    public static func acceptsDiscoveredPeer(
        _ peer: PeerIdentity,
        pinnedPublicKey: Data?
    ) -> Bool {
        guard let pinnedPublicKey else { return true }
        return pinnedPublicKey == peer.signingPublicKey
    }

    public static func evaluate(
        request: PairingEnvelope,
        pinnedPublicKey: Data?,
        activeRequestIDs: Set<UUID>,
        pendingSenderIDs: Set<UUID>,
        activeRequestCount: Int,
        maximumPendingRequests: Int
    ) -> PairingRequestDecision {
        if let pinnedPublicKey,
           pinnedPublicKey != request.sender.signingPublicKey {
            return .rejectChangedKey
        }
        if activeRequestIDs.contains(request.requestID) {
            return .rejectDuplicateRequest
        }
        if pendingSenderIDs.contains(request.sender.id) {
            return .rejectDuplicateSender
        }
        if activeRequestCount >= maximumPendingRequests {
            return .rejectAtCapacity
        }
        return .allow
    }
}
