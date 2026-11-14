import Combine
import Foundation
import MacKVMCore

/// Coordinates outbound control hand-offs while keeping target selection
/// independent from the secure session's single-active-peer transport.
@MainActor
final class InputTargetRouter: ObservableObject {
    struct Actions {
        let connectedPeerID: () -> UUID?
        let isConnected: (UUID) -> Bool
        let isConnecting: (UUID) -> Bool
        let selectPeer: (UUID) -> Void
        let connect: (UUID) -> Void
        let stopControl: (String) -> Void
        let stopControlForTargetSwitch: (String) -> Void
        let isControlActive: () -> Bool
        let requestControl: () -> Bool
    }

    @Published private(set) var orderedPeerIDs: [UUID] = []
    @Published private(set) var selectedPeerID: UUID?

    private let actions: Actions
    private var availablePeerIDs = Set<UUID>()
    private var operationGeneration: UInt64 = 0
    private var pendingTarget: (peerID: UUID, generation: UInt64)?

    init(actions: Actions) {
        self.actions = actions
    }

    func updateTargets(
        orderedPeerIDs: [UUID],
        availablePeerIDs: Set<UUID>
    ) {
        var seen = Set<UUID>()
        self.orderedPeerIDs = orderedPeerIDs.filter {
            seen.insert($0).inserted
        }
        self.availablePeerIDs = availablePeerIDs

        if let selectedPeerID,
           !self.orderedPeerIDs.contains(selectedPeerID) {
            operationGeneration &+= 1
            pendingTarget = nil
            self.selectedPeerID = self.orderedPeerIDs.first
        } else if selectedPeerID == nil {
            selectedPeerID = self.orderedPeerIDs.first
        }

        if let pendingTarget,
           !self.orderedPeerIDs.contains(pendingTarget.peerID)
            || !availablePeerIDs.contains(pendingTarget.peerID) {
            operationGeneration &+= 1
            self.pendingTarget = nil
        }
    }

    func cycleToNextOnlineTarget() {
        guard let peerID = InputTargetSelectionPolicy.nextTarget(
            orderedPeerIDs: orderedPeerIDs,
            currentPeerID: selectedPeerID,
            availablePeerIDs: availablePeerIDs
        ) else {
            return
        }
        select(peerID: peerID)
    }

    func selectTarget(atOneBasedSlot slot: Int) {
        guard let peerID = InputTargetSelectionPolicy.target(
            atOneBasedSlot: slot,
            orderedPeerIDs: orderedPeerIDs,
            availablePeerIDs: availablePeerIDs
        ) else {
            return
        }
        select(peerID: peerID)
    }

    func activateSelectedTarget() {
        guard let selectedPeerID,
              availablePeerIDs.contains(selectedPeerID) else {
            return
        }
        select(peerID: selectedPeerID)
    }

    /// Handles authenticated connection publications. A late connection for
    /// an older hand-off cannot request control because only the most recent
    /// target and operation generation are eligible here.
    func connectionChanged(to peerID: UUID?) {
        guard let pendingTarget,
              pendingTarget.generation == operationGeneration,
              peerID == pendingTarget.peerID,
              availablePeerIDs.contains(pendingTarget.peerID),
              actions.isConnected(pendingTarget.peerID),
              actions.connectedPeerID() == pendingTarget.peerID else {
            return
        }
        self.pendingTarget = nil
        _ = actions.requestControl()
    }

    /// Ends local outbound control and invalidates any in-flight target
    /// switch. The secure session may stay connected, but no later connection
    /// callback can restart remote input without another user action.
    func returnInputLocally() {
        operationGeneration &+= 1
        pendingTarget = nil
        actions.stopControl("Input returned to this Mac")
    }

    func invalidatePendingSwitch() {
        operationGeneration &+= 1
        pendingTarget = nil
    }

    func toggleSelectedTarget() {
        if actions.isControlActive() {
            invalidatePendingSwitch()
            actions.stopControl("Hotkey returned input locally")
            return
        }
        guard let selectedPeerID,
              availablePeerIDs.contains(selectedPeerID) else {
            return
        }
        select(peerID: selectedPeerID)
    }

    private func select(peerID: UUID) {
        guard orderedPeerIDs.contains(peerID),
              availablePeerIDs.contains(peerID) else {
            return
        }

        if pendingTarget?.peerID == peerID {
            return
        }

        let isNewTarget = selectedPeerID != peerID
        selectedPeerID = peerID
        operationGeneration &+= 1
        let generation = operationGeneration

        if !isNewTarget,
           actions.connectedPeerID() == peerID,
           actions.isConnected(peerID) {
            pendingTarget = nil
            guard !actions.isControlActive() else { return }
            _ = actions.requestControl()
            return
        }

        pendingTarget = (peerID, generation)
        if actions.isControlActive() {
            actions.stopControlForTargetSwitch(
                "Switching input to the selected client"
            )
        }
        actions.selectPeer(peerID)
        if !actions.isConnected(peerID), !actions.isConnecting(peerID) {
            actions.connect(peerID)
        }
    }
}
