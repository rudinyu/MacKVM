import Foundation

public final class PairingRegistry {
    private let defaults: UserDefaults
    private let storageKey: String
    private var profileStorageKey: String { "\(storageKey).profiles" }
    private let lock = NSLock()
    private var revocationGenerations: [UUID: UInt64] = [:]

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "MacKVM.pairedPeers"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public var pairedPeerIDs: Set<UUID> {
        Set(pairedPeers.keys)
    }

    public var pairedPeers: [UUID: Data] {
        lock.lock()
        defer { lock.unlock() }
        return loadPairedPeers()
    }

    public var pairedPeerProfiles: [UUID: PairedPeerProfile] {
        lock.lock()
        defer { lock.unlock() }
        let peers = loadPairedPeers()
        return loadProfiles(for: peers)
    }

    public func contains(_ peerID: UUID) -> Bool {
        publicKey(for: peerID) != nil
    }

    public func publicKey(for peerID: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return loadPairedPeers()[peerID]
    }

    public func profile(for peerID: UUID) -> PairedPeerProfile? {
        lock.lock()
        defer { lock.unlock() }
        let peers = loadPairedPeers()
        guard peers[peerID] != nil else { return nil }
        return loadProfiles(for: peers)[peerID]
    }

    public func add(_ peer: PeerIdentity, model: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        addLocked(peer, model: model)
    }

    @discardableResult
    public func add(
        _ peer: PeerIdentity,
        ifGeneration generation: UInt64,
        model: String? = nil
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revocationGenerations[peer.id, default: 0] == generation else {
            return false
        }
        addLocked(peer, model: model)
        return true
    }

    @discardableResult
    public func recordConnection(
        for peerID: UUID,
        model: String? = nil,
        at date: Date = Date()
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let peers = loadPairedPeers()
        guard let publicKey = peers[peerID] else { return false }
        let existing = loadProfiles(for: peers)[peerID]
        let profile = PairedPeerProfile(
            peerID: peerID,
            friendlyName: existing?.friendlyName ?? "Mac \(peerID.uuidString.prefix(8))",
            model: preferredModel(model, existing: existing?.model),
            lastConnectedAt: date,
            signingPublicKey: publicKey
        )
        mergeAndPersistProfiles([peerID: profile], into: loadStoredProfiles())
        return true
    }

    @discardableResult
    public func updateFriendlyName(
        for peerID: UUID,
        friendlyName: String
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let peers = loadPairedPeers()
        guard let publicKey = peers[peerID],
              let validatedName = PeerIdentity.validatedDisplayName(
                  friendlyName
              ) else {
            return false
        }
        let existing = loadProfiles(for: peers)[peerID]
        let profile = PairedPeerProfile(
            peerID: peerID,
            friendlyName: validatedName,
            model: existing?.model,
            lastConnectedAt: existing?.lastConnectedAt,
            signingPublicKey: publicKey
        )
        mergeAndPersistProfiles([peerID: profile], into: loadStoredProfiles())
        return true
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
        defer { lock.unlock() }
        let nextGeneration = revocationGenerations[peerID, default: 0] &+ 1
        revocationGenerations[peerID] = nextGeneration
        var peers = loadPairedPeers()
        peers.removeValue(forKey: peerID)
        persist(peers)
        var profiles = loadStoredProfiles()
        profiles.removeValue(forKey: peerID.uuidString)
        persistProfiles(profiles)
        return nextGeneration
    }

    public func remove(_ peerID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var peers = loadPairedPeers()
        peers.removeValue(forKey: peerID)
        persist(peers)
        var profiles = loadStoredProfiles()
        profiles.removeValue(forKey: peerID.uuidString)
        persistProfiles(profiles)
    }

    /// Clears every locally trusted peer. This is used only by the explicit
    /// identity-recovery flow, which requires pairing again after relaunch.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        revocationGenerations.removeAll()
        persist([:])
        persistProfiles([:])
    }

    private func loadPairedPeers() -> [UUID: Data] {
        guard let storedData = defaults.data(forKey: storageKey),
              let storedPeers = try? JSONDecoder().decode(
                  [String: Data].self,
                  from: storedData
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

    private func addLocked(_ peer: PeerIdentity, model: String?) {
        var peers = loadPairedPeers()
        peers[peer.id] = peer.signingPublicKey
        persist(peers)
        // `loadProfiles` supplies a display fallback for peers that have no
        // stored profile. That fallback must not replace the name received
        // during a new pairing, so only reuse a validated persisted profile.
        let existing = storedProfile(
            for: peer.id,
            publicKey: peer.signingPublicKey
        )
        let profile = PairedPeerProfile(
            peerID: peer.id,
            friendlyName: existing?.friendlyName ?? peer.name,
            model: preferredModel(model, existing: existing?.model),
            lastConnectedAt: existing?.lastConnectedAt,
            signingPublicKey: peer.signingPublicKey
        )
        mergeAndPersistProfiles([peer.id: profile], into: loadStoredProfiles())
    }

    private func persist(_ peers: [UUID: Data]) {
        let storedPeers = Dictionary(
            uniqueKeysWithValues: peers.map { ($0.key.uuidString, $0.value) }
        )
        guard let encodedPeers = try? JSONEncoder().encode(storedPeers) else {
            return
        }
        defaults.set(encodedPeers, forKey: storageKey)
    }

    private func loadStoredProfiles() -> [String: PairedPeerProfile] {
        guard let storedData = defaults.data(forKey: profileStorageKey),
              let profiles = try? JSONDecoder().decode(
                  [String: PairedPeerProfile].self,
                  from: storedData
              ) else {
            return [:]
        }
        return profiles
    }

    private func loadProfiles(
        for peers: [UUID: Data]
    ) -> [UUID: PairedPeerProfile] {
        return peers.reduce(into: [:]) { result, entry in
            let (peerID, publicKey) = entry
            if let profile = storedProfile(
                for: peerID,
                publicKey: publicKey
            ) {
                result[peerID] = profile
            } else {
                result[peerID] = PairedPeerProfile(
                    peerID: peerID,
                    friendlyName: "Mac \(peerID.uuidString.prefix(8))",
                    model: nil,
                    signingPublicKey: publicKey
                )
            }
        }
    }

    private func storedProfile(
        for peerID: UUID,
        publicKey: Data
    ) -> PairedPeerProfile? {
        let profile = loadStoredProfiles()[peerID.uuidString]
        guard profile?.peerID == peerID,
              profile?.signingPublicKey == publicKey else {
            return nil
        }
        return profile
    }

    private func mergeAndPersistProfiles(
        _ profiles: [UUID: PairedPeerProfile],
        into existing: [String: PairedPeerProfile] = [:]
    ) {
        var merged = existing
        profiles.forEach { merged[$0.key.uuidString] = $0.value }
        guard let encodedProfiles = try? JSONEncoder().encode(merged) else {
            return
        }
        defaults.set(encodedProfiles, forKey: profileStorageKey)
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

    private func persistProfiles(_ profiles: [String: PairedPeerProfile]) {
        guard let encodedProfiles = try? JSONEncoder().encode(profiles) else {
            return
        }
        defaults.set(encodedProfiles, forKey: profileStorageKey)
    }
}
