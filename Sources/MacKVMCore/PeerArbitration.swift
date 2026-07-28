import Foundation

public enum PeerArbitration {
    public static func localIDWins(
        localID: UUID,
        remoteID: UUID
    ) -> Bool {
        localID.uuidString < remoteID.uuidString
    }
}
