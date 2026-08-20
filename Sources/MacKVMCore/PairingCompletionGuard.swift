import Foundation

/// Captures the identity and Forget generation for one pairing attempt.
/// A completion is accepted only if it still refers to the same request,
/// peer, and generation after asynchronous work returns to the queue.
public struct PairingCompletionGuard: Equatable, Sendable {
    public let requestID: UUID
    public let peerID: UUID
    public let generation: UInt64

    public init(
        requestID: UUID,
        peerID: UUID,
        generation: UInt64
    ) {
        self.requestID = requestID
        self.peerID = peerID
        self.generation = generation
    }

    public func permits(
        currentGeneration: UInt64,
        requestID: UUID,
        peerID: UUID
    ) -> Bool {
        self.requestID == requestID
            && self.peerID == peerID
            && generation == currentGeneration
    }
}
