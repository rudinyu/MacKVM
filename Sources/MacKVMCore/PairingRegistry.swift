import Foundation

/// Stores the locally pinned peer keys and their support metadata.
///
/// Reads are served from an in-memory snapshot. UserDefaults is only used for
/// initial loading; writes use the Core Foundation preferences API on a
/// serialized queue, never while the registry lock is held by a reader. This
/// is important for the menu-bar app: SwiftUI can rebuild the menu on the main
/// thread while a pairing completion is writing its trust record in the
/// background without synchronously re-entering SwiftUI's preferences
/// observer.
public final class PairingRegistry {
    private struct PersistenceSnapshot: Sendable {
        let peers: [UUID: Data]
        let profiles: [String: PairedPeerProfile]
    }

    /// A single ordered snapshot write. The once gate lets callers safely
    /// wait for an immediate write without accidentally running the same
    /// snapshot twice when the queue worker reaches it.
    private final class PersistenceWork: @unchecked Sendable {
        private let completion = DispatchGroup()
        private let lock = NSLock()
        private var didRun = false
        private var succeeded = true
        private let action: () -> Bool

        init(action: @escaping () -> Bool) {
            self.action = action
            completion.enter()
        }

        func run() {
            lock.lock()
            guard !didRun else {
                lock.unlock()
                return
            }
            didRun = true
            lock.unlock()
            let succeeded = action()
            lock.lock()
            self.succeeded = succeeded
            lock.unlock()
            completion.leave()
        }

        func wait() -> Bool {
            completion.wait()
            lock.lock()
            defer { lock.unlock() }
            return succeeded
        }
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var profileStorageKey: String { "\(storageKey).profiles" }
    private let persistenceQueue: DispatchQueue
    private let persistenceQueueKey = DispatchSpecificKey<Void>()

    private enum PersistenceDomain: Sendable {
        case currentApplication
        case application(String)
    }

    private let persistenceDomain: PersistenceDomain
    private let lock = NSLock()
    private var cachedPeers: [UUID: Data]
    private var cachedProfiles: [UUID: PairedPeerProfile]
    private var revocationGenerations: [UUID: UInt64] = [:]

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "MacKVM.pairedPeers",
        persistenceApplicationID: String? = nil
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if defaults === UserDefaults.standard {
            guard persistenceApplicationID == nil else {
                preconditionFailure(
                    "persistenceApplicationID is only valid with a custom UserDefaults suite"
                )
            }
            persistenceDomain = .currentApplication
        } else {
            guard let persistenceApplicationID,
                  !persistenceApplicationID.isEmpty else {
                preconditionFailure(
                    "A custom UserDefaults suite requires its suite name as persistenceApplicationID"
                )
            }
            persistenceDomain = .application(persistenceApplicationID)
        }
        persistenceQueue = DispatchQueue(
            label: "app.mackvm.pairing-registry.persistence",
            qos: .utility
        )
        persistenceQueue.setSpecific(key: persistenceQueueKey, value: ())
        let peers = Self.decodePairedPeers(
            defaults.data(forKey: storageKey)
        )
        cachedPeers = peers
        cachedProfiles = Self.decodeProfiles(
            defaults.data(forKey: "\(storageKey).profiles"),
            for: peers
        )
    }

    public var pairedPeerIDs: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return Set(cachedPeers.keys)
    }

    public var pairedPeers: [UUID: Data] {
        lock.lock()
        defer { lock.unlock() }
        return cachedPeers
    }

    public var pairedPeerProfiles: [UUID: PairedPeerProfile] {
        lock.lock()
        defer { lock.unlock() }
        return cachedProfiles
    }

    public func contains(_ peerID: UUID) -> Bool {
        publicKey(for: peerID) != nil
    }

    public func publicKey(for peerID: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return cachedPeers[peerID]
    }

    public func profile(for peerID: UUID) -> PairedPeerProfile? {
        lock.lock()
        defer { lock.unlock() }
        guard cachedPeers[peerID] != nil else { return nil }
        return cachedProfiles[peerID]
    }

    public func add(
        _ peer: PeerIdentity,
        model: String? = nil,
        persistImmediately: Bool = true
    ) {
        lock.lock()
        let previousPeers = cachedPeers
        let previousProfiles = cachedProfiles
        addLocked(peer, model: model)
        let persistence = enqueuePersistenceLocked(immediately: persistImmediately)
        _ = finishPersistenceLocked(
            persistence,
            previousPeers: previousPeers,
            previousProfiles: previousProfiles,
            rollbackOnFailure: true
        )
        lock.unlock()
    }

    @discardableResult
    public func add(
        _ peer: PeerIdentity,
        ifGeneration generation: UInt64,
        model: String? = nil,
        persistImmediately: Bool = true
    ) -> Bool {
        lock.lock()
        guard revocationGenerations[peer.id, default: 0] == generation else {
            lock.unlock()
            return false
        }
        let previousPeers = cachedPeers
        let previousProfiles = cachedProfiles
        addLocked(peer, model: model)
        let persistence = enqueuePersistenceLocked(immediately: persistImmediately)
        let saved = finishPersistenceLocked(
            persistence,
            previousPeers: previousPeers,
            previousProfiles: previousProfiles,
            rollbackOnFailure: true
        )
        lock.unlock()
        return saved
    }

    @discardableResult
    public func recordConnection(
        for peerID: UUID,
        model: String? = nil,
        friendlyName: String? = nil,
        at date: Date = Date(),
        persistImmediately: Bool = true
    ) -> Bool {
        lock.lock()
        guard let publicKey = cachedPeers[peerID] else {
            lock.unlock()
            return false
        }
        let previousPeers = cachedPeers
        let previousProfiles = cachedProfiles
        let existing = cachedProfiles[peerID]
        let generatedName = generatedFriendlyName(for: peerID)
        let authenticatedName = PeerIdentity.validatedDisplayName(
            friendlyName ?? ""
        )
        let retainedName: String
        if let existingName = existing?.friendlyName,
           existingName != generatedName {
            // Keep an explicitly chosen name, including one that happens to
            // differ from the currently advertised signed identity name.
            retainedName = existingName
        } else {
            // Older releases persisted this generated fallback on first
            // connection. Replace that exact value once a signed connection
            // supplies the peer's validated name.
            retainedName = authenticatedName ?? generatedName
        }
        cachedProfiles[peerID] = PairedPeerProfile(
            peerID: peerID,
            friendlyName: retainedName,
            model: preferredModel(model, existing: existing?.model),
            lastConnectedAt: date,
            seamlessControlAuthorized: existing?.seamlessControlAuthorized ?? false,
            signingPublicKey: publicKey
        )
        let persistence = enqueuePersistenceLocked(immediately: persistImmediately)
        let saved = finishPersistenceLocked(
            persistence,
            previousPeers: previousPeers,
            previousProfiles: previousProfiles,
            rollbackOnFailure: true
        )
        lock.unlock()
        return saved
    }

    @discardableResult
    public func updateFriendlyName(
        for peerID: UUID,
        friendlyName: String,
        persistImmediately: Bool = true
    ) -> Bool {
        lock.lock()
        guard let publicKey = cachedPeers[peerID],
              let validatedName = PeerIdentity.validatedDisplayName(
                  friendlyName
              ) else {
            lock.unlock()
            return false
        }
        let previousPeers = cachedPeers
        let previousProfiles = cachedProfiles
        let existing = cachedProfiles[peerID]
        cachedProfiles[peerID] = PairedPeerProfile(
            peerID: peerID,
            friendlyName: validatedName,
            model: existing?.model,
            lastConnectedAt: existing?.lastConnectedAt,
            seamlessControlAuthorized: existing?.seamlessControlAuthorized ?? false,
            signingPublicKey: publicKey
        )
        let persistence = enqueuePersistenceLocked(immediately: persistImmediately)
        let saved = finishPersistenceLocked(
            persistence,
            previousPeers: previousPeers,
            previousProfiles: previousProfiles,
            rollbackOnFailure: true
        )
        lock.unlock()
        return saved
    }

    /// Returns the receiver-side one-time control authorization for a peer.
    /// The profile lookup also verifies that the profile's signing key still
    /// matches the currently pinned key, so stale profile data cannot grant
    /// control after a key change or partial preference corruption.
    public func seamlessControlAuthorized(for peerID: UUID) -> Bool {
        profile(for: peerID)?.seamlessControlAuthorized ?? false
    }

    /// Updates the local one-time control authorization for a currently pinned
    /// peer. This setting is intentionally not part of any wire message.
    @discardableResult
    public func updateSeamlessControlAuthorization(
        for peerID: UUID,
        authorized: Bool,
        persistImmediately: Bool = true
    ) -> Bool {
        lock.lock()
        guard let publicKey = cachedPeers[peerID] else {
            lock.unlock()
            return false
        }
        let previousPeers = cachedPeers
        let previousProfiles = cachedProfiles
        let existing = cachedProfiles[peerID]
        cachedProfiles[peerID] = PairedPeerProfile(
            peerID: peerID,
            friendlyName: existing?.friendlyName
                ?? generatedFriendlyName(for: peerID),
            model: existing?.model,
            lastConnectedAt: existing?.lastConnectedAt,
            seamlessControlAuthorized: authorized,
            signingPublicKey: publicKey
        )
        let persistence = enqueuePersistenceLocked(immediately: persistImmediately)
        let saved = finishPersistenceLocked(
            persistence,
            previousPeers: previousPeers,
            previousProfiles: previousProfiles,
            rollbackOnFailure: true
        )
        lock.unlock()
        return saved
    }

    public func generation(for peerID: UUID) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revocationGenerations[peerID, default: 0]
    }

    /// Atomically advances a peer's in-memory trust generation and removes
    /// its persisted key, preventing stale completions from re-adding it.
    @discardableResult
    public func revoke(_ peerID: UUID) -> UInt64 {
        lock.lock()
        let nextGeneration = revocationGenerations[peerID, default: 0] &+ 1
        revocationGenerations[peerID] = nextGeneration
        cachedPeers.removeValue(forKey: peerID)
        cachedProfiles.removeValue(forKey: peerID)
        // Queue the durable removal before releasing the lock so snapshots
        // retain mutation order, but never wait for UserDefaults while this
        // lock is held. UserDefaults posts its change notification
        // synchronously; SwiftUI may re-enter the registry from that
        // notification on the main thread.
        let persistence = enqueuePersistenceLocked(immediately: true)
        lock.unlock()
        _ = waitForPersistence(persistence)
        return nextGeneration
    }

    public func remove(_ peerID: UUID) {
        lock.lock()
        cachedPeers.removeValue(forKey: peerID)
        cachedProfiles.removeValue(forKey: peerID)
        let persistence = enqueuePersistenceLocked(immediately: true)
        lock.unlock()
        _ = waitForPersistence(persistence)
    }

    /// Clears every locally trusted peer. This is used only by the explicit
    /// identity-recovery flow, which requires pairing again after relaunch.
    public func removeAll() {
        lock.lock()
        revocationGenerations.removeAll()
        cachedPeers.removeAll()
        cachedProfiles.removeAll()
        // Submit the empty snapshot while holding the registry lock so a
        // concurrent mutation cannot enqueue a newer snapshot before this
        // clear operation. The persistence queue remains the single ordered
        // writer for UserDefaults. Wait only after releasing the lock.
        let persistence = enqueuePersistenceLocked(immediately: true)
        lock.unlock()
        _ = waitForPersistence(persistence)
    }

    private func addLocked(_ peer: PeerIdentity, model: String?) {
        cachedPeers[peer.id] = peer.signingPublicKey
        // Only reuse a profile whose key still matches this pairing. A newly
        // completed pairing otherwise receives the signed peer name.
        let existing = cachedProfiles[peer.id].flatMap { profile in
            profile.signingPublicKey == peer.signingPublicKey ? profile : nil
        }
        cachedProfiles[peer.id] = PairedPeerProfile(
            peerID: peer.id,
            friendlyName: existing?.friendlyName ?? peer.name,
            model: preferredModel(model, existing: existing?.model),
            lastConnectedAt: existing?.lastConnectedAt,
            // A newly completed pairing is an explicit user trust decision,
            // so make daily switching seamless immediately. Preserve an
            // existing local opt-out when the same pinned peer is refreshed.
            seamlessControlAuthorized: existing?.seamlessControlAuthorized ?? true,
            signingPublicKey: peer.signingPublicKey
        )
    }

    private func persistenceSnapshotLocked() -> PersistenceSnapshot {
        PersistenceSnapshot(
            peers: cachedPeers,
            profiles: Dictionary(
                uniqueKeysWithValues: cachedProfiles.map {
                    ($0.key.uuidString, $0.value)
                }
            )
        )
    }

    /// Enqueue while holding the registry lock so persistence snapshots are
    /// ordered exactly like the in-memory mutations. The returned work item
    /// may be waited on after the lock is released.
    private func enqueuePersistenceLocked(
        immediately: Bool
    ) -> PersistenceWork? {
        let snapshot = persistenceSnapshotLocked()
        let storageKey = self.storageKey
        let profileStorageKey = self.profileStorageKey
        let persistenceDomain = self.persistenceDomain
        let work = PersistenceWork {
            Self.persist(
                snapshot,
                storageKey: storageKey,
                profileStorageKey: profileStorageKey,
                persistenceDomain: persistenceDomain
            )
        }
        // Every domain is written by the same serial queue. Core Foundation
        // preferences do not synchronously post UserDefaults.didChangeNotification,
        // so this queue cannot form the SwiftUI/registry lock cycle seen when
        // UserDefaults.set was called while the registry lock was held.
        persistenceQueue.async {
            work.run()
        }
        return immediately ? work : nil
    }

    /// Wait for an immediate write. Mutating callers may hold the registry lock
    /// while waiting so a failed write can roll back before another mutation
    /// snapshots the uncommitted state. CFPreferences does not synchronously
    /// notify SwiftUI, so this cannot recreate the old lock cycle.
    /// CFPreferences does not synchronously post UserDefaults.didChangeNotification,
    /// so it is safe to wait for the ordered barrier even from SwiftUI's main
    /// thread. Calls made from the persistence queue itself are already at the
    /// barrier and must not wait recursively.
    private func waitForPersistence(_ work: PersistenceWork?) -> Bool {
        guard let work else {
            return true
        }
        if DispatchQueue.getSpecific(key: persistenceQueueKey) != nil {
            // The work was already enqueued on this serial queue. Run it now
            // rather than waiting recursively for the queue to become free.
            work.run()
        }
        return work.wait()
    }

    /// Completes an immediate mutation while the registry lock is held. A
    /// failed durable write must not leave a newly trusted peer or a newer
    /// profile in the live cache. Restore the previous snapshot and enqueue a
    /// corrective write before releasing the lock so a later snapshot cannot
    /// accidentally re-persist the failed mutation.
    @discardableResult
    private func finishPersistenceLocked(
        _ persistence: PersistenceWork?,
        previousPeers: [UUID: Data],
        previousProfiles: [UUID: PairedPeerProfile],
        rollbackOnFailure: Bool
    ) -> Bool {
        let saved = waitForPersistence(persistence)
        guard !saved, rollbackOnFailure else {
            return saved
        }
        cachedPeers = previousPeers
        cachedProfiles = previousProfiles
        let rollback = enqueuePersistenceLocked(immediately: true)
        _ = waitForPersistence(rollback)
        return false
    }

    private static func persist(
        _ snapshot: PersistenceSnapshot,
        storageKey: String,
        profileStorageKey: String,
        persistenceDomain: PersistenceDomain
    ) -> Bool {
        let storedPeers = Dictionary(
            uniqueKeysWithValues: snapshot.peers.map {
                ($0.key.uuidString, $0.value)
            }
        )
        guard let encodedPeers = try? JSONEncoder().encode(storedPeers),
              let encodedProfiles = try? JSONEncoder().encode(
                  snapshot.profiles
              ) else {
            return false
        }

        let applicationID: CFString
        switch persistenceDomain {
        case .currentApplication:
            applicationID = kCFPreferencesCurrentApplication
        case let .application(identifier):
            applicationID = identifier as CFString
        }
        CFPreferencesSetAppValue(
            storageKey as CFString,
            encodedPeers as CFPropertyList,
            applicationID
        )
        CFPreferencesSetAppValue(
            profileStorageKey as CFString,
            encodedProfiles as CFPropertyList,
            applicationID
        )
        // This is intentionally a synchronous barrier. Unlike
        // UserDefaults.set, CFPreferencesSetAppValue does not emit the
        // SwiftUI-observed didChange notification inline.
        return CFPreferencesAppSynchronize(applicationID)
    }

    private static func decodePairedPeers(_ data: Data?) -> [UUID: Data] {
        guard let data,
              let storedPeers = try? JSONDecoder().decode(
                  [String: Data].self,
                  from: data
              ) else {
            return [:]
        }

        var peers: [UUID: Data] = [:]
        var conflictingIDs = Set<UUID>()
        // Sort textual keys before normalizing UUIDs so malformed preferences
        // are handled deterministically across launches. Conflicting records
        // are discarded rather than selecting an arbitrary trust anchor.
        for entry in storedPeers.sorted(by: { $0.key < $1.key }) {
            guard let peerID = UUID(uuidString: entry.key),
                  !conflictingIDs.contains(peerID) else { continue }
            guard let existingKey = peers[peerID] else {
                peers[peerID] = entry.value
                continue
            }
            if existingKey != entry.value {
                peers.removeValue(forKey: peerID)
                conflictingIDs.insert(peerID)
            }
        }
        return peers
    }

    private static func decodeProfiles(
        _ data: Data?,
        for peers: [UUID: Data]
    ) -> [UUID: PairedPeerProfile] {
        guard let data,
              let storedProfiles = try? JSONDecoder().decode(
                  [String: PairedPeerProfile].self,
                  from: data
              ) else {
            return [:]
        }
        return storedProfiles.reduce(into: [:]) { result, entry in
            let (rawID, profile) = entry
            guard let peerID = UUID(uuidString: rawID),
                  profile.peerID == peerID,
                  peers[peerID] == profile.signingPublicKey else {
                return
            }
            result[peerID] = profile
        }
    }

    private func preferredModel(
        _ candidate: String?,
        existing: String?
    ) -> String {
        guard let candidate else {
            return existing ?? PeerMetadataValidation.unknownModel
        }
        let validated = PeerMetadataValidation.validatedModel(candidate)
        if validated == PeerMetadataValidation.unknownModel,
           let existing,
           existing != PeerMetadataValidation.unknownModel {
            return existing
        }
        return validated
    }

    private func generatedFriendlyName(for peerID: UUID) -> String {
        "Mac \(peerID.uuidString.prefix(8))"
    }
}
