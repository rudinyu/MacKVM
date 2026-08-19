import Foundation

/// Defines the signed evidence required before a pairing is persisted. The
/// Both Macs must explicitly confirm the displayed verification code before
/// either peer is considered locally accepted. Both signed completion messages
/// must cross the connection, the peer must acknowledge the completion we
/// sent, and the close barrier must have peer-confirmed transport evidence
/// before trust is saved.
enum PairingCompletionPolicy {
    static func allowsPersistence(
        localAccepted: Bool,
        remoteAccepted: Bool,
        localCompletionSent: Bool,
        remoteCompletionReceived: Bool,
        acknowledgementReceived: Bool,
        acknowledgementDelivered: Bool,
        closeBarrierConfirmedByPeer: Bool
    ) -> Bool {
        return localAccepted
            && remoteAccepted
            && localCompletionSent
            && remoteCompletionReceived
            && acknowledgementReceived
            && acknowledgementDelivered
            && closeBarrierConfirmedByPeer
    }
}
