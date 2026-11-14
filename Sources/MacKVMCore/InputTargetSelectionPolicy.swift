import Foundation

/// Pure ordering and destination-selection rules for the paired input targets.
/// The caller persists the returned order so display names and discovery
/// ordering never change a client's direct-hotkey slot.
public enum InputTargetSelectionPolicy {
    /// Seeds a new installation with a repeatable order. UUID ordering is used
    /// only once; newly paired clients are appended by `updatingOrder`.
    public static func seededOrder(peerIDs: Set<UUID>) -> [UUID] {
        peerIDs.sorted { $0.uuidString < $1.uuidString }
    }

    /// Removes forgotten peers and appends newly paired peers in a stable
    /// order while preserving every existing slot.
    public static func updatingOrder(
        _ existingOrder: [UUID],
        pairedPeerIDs: Set<UUID>
    ) -> [UUID] {
        var seen = Set<UUID>()
        let retained = existingOrder.filter {
            pairedPeerIDs.contains($0) && seen.insert($0).inserted
        }
        let added = pairedPeerIDs
            .subtracting(seen)
            .sorted { $0.uuidString < $1.uuidString }
        return retained + added
    }

    /// Moves one paired client to slot 1 while preserving the relative order
    /// of all remaining clients.
    public static func makingPrimary(
        _ peerID: UUID,
        in order: [UUID]
    ) -> [UUID] {
        guard order.contains(peerID) else { return order }
        return [peerID] + order.filter { $0 != peerID }
    }

    /// Returns a one-based direct-select slot only when it exists and is
    /// currently online.
    public static func target(
        atOneBasedSlot slot: Int,
        orderedPeerIDs: [UUID],
        availablePeerIDs: Set<UUID>
    ) -> UUID? {
        guard slot > 0,
              orderedPeerIDs.indices.contains(slot - 1) else {
            return nil
        }
        let peerID = orderedPeerIDs[slot - 1]
        return availablePeerIDs.contains(peerID) ? peerID : nil
    }

    /// Cycles after the current slot and wraps, skipping paired clients that
    /// are not currently discoverable. A single online target may be returned
    /// again after a full cycle.
    public static func nextTarget(
        orderedPeerIDs: [UUID],
        currentPeerID: UUID?,
        availablePeerIDs: Set<UUID>
    ) -> UUID? {
        guard !orderedPeerIDs.isEmpty, !availablePeerIDs.isEmpty else {
            return nil
        }
        let currentIndex = currentPeerID.flatMap(orderedPeerIDs.firstIndex)
            ?? -1
        for offset in 1...orderedPeerIDs.count {
            let index = (currentIndex + offset) % orderedPeerIDs.count
            let candidate = orderedPeerIDs[index]
            if availablePeerIDs.contains(candidate) {
                return candidate
            }
        }
        return nil
    }
}
