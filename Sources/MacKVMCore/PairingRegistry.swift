import Foundation

public final class PairingRegistry {
    private let defaults: UserDefaults
    private let storageKey: String
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

    public func contains(_ peerID: UUID) -> Bool {
        publicKey(for: peerID) != nil
    }

    public func publicKey(for peerID: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return loadPairedPeers()[peerID]
    }

    public func add(_ peer: PeerIdentity) {
        lock.lock()
        defer { lock.unlock() }
        addLocked(peer)
    }

    @discardableResult
    public func add(
        _ peer: PeerIdentity,
        ifGeneration generation: UInt64
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard revocationGenerations[peer.id, default: 0] == generation else {
            return false
        }
        addLocked(peer)
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
        return nextGeneration
    }

    public func remove(_ peerID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var peers = loadPairedPeers()
        peers.removeValue(forKey: peerID)
        persist(peers)
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

    private func addLocked(_ peer: PeerIdentity) {
        var peers = loadPairedPeers()
        peers[peer.id] = peer.signingPublicKey
        persist(peers)
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
}
