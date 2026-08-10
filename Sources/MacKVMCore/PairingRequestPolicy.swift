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
        maximumPendingRequests: Int,
        activeUnpairedRequestCount: Int = 0,
        maximumUnpairedPendingRequests: Int = 1
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
        // A self-signed identity is cheap to mint until the user confirms the
        // verification code. Keep that untrusted pool separate so a burst of
        // unsolicited pairing requests cannot consume every slot needed by a
        // legitimate request from an already-paired peer.
        if pinnedPublicKey == nil,
           activeUnpairedRequestCount >= maximumUnpairedPendingRequests {
            return .rejectAtCapacity
        }
        let unpairedCapacity = max(0, maximumPendingRequests - 1)
        if pinnedPublicKey == nil,
           activeRequestCount >= unpairedCapacity {
            return .rejectAtCapacity
        }
        if activeRequestCount >= maximumPendingRequests {
            return .rejectAtCapacity
        }
        return .allow
    }
}
