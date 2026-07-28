import Foundation

public final class PairingRegistry {
    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

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
        var peers = loadPairedPeers()
        peers[peer.id] = peer.signingPublicKey
        persist(peers)
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

        return Dictionary(
            uniqueKeysWithValues: storedPeers.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            }
        )
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
