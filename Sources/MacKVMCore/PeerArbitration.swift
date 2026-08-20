import Foundation

public enum PeerArbitration {
    /// Equal UUIDs are invalid: two devices must never arbitrate a session
    /// against their own identity. Callers should reject this pair before
    /// selecting a winner.
    public static func isValidPeerPair(
        localID: UUID,
        remoteID: UUID
    ) -> Bool {
        localID != remoteID
    }

    public static func localIDWins(
        localID: UUID,
        remoteID: UUID
    ) -> Bool {
        isValidPeerPair(localID: localID, remoteID: remoteID)
            && localID.uuidString < remoteID.uuidString
    }
}
