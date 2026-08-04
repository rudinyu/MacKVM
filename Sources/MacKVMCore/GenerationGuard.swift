import Foundation

/// Thread-safe monotonically increasing generations for invalidating stale
/// asynchronous work. A generation is scoped to one logical key, so callers
/// can invalidate one peer/request without disturbing unrelated work. Removed
/// keys can be purged separately once the caller has removed all asynchronous
/// work that could still hold the prior generation value.
public final class GenerationGuard<Key: Hashable>: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [Key: UInt64] = [:]

    public init() {}

    public func current(for key: Key) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generations[key] ?? 0
    }

    @discardableResult
    public func advance(for key: Key) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let next = (generations[key] ?? 0) &+ 1
        generations[key] = next
        return next
    }

    public func set(_ generation: UInt64, for key: Key) {
        lock.lock()
        let applied = max(generations[key] ?? 0, generation)
        generations[key] = applied
        lock.unlock()
    }

    /// Invalidates a key while retaining its tombstone for stale callbacks.
    @discardableResult
    public func invalidate(for key: Key) -> UInt64 {
        advance(for: key)
    }

    /// Purges a key after its asynchronous work has been cancelled/retired.
    public func remove(for key: Key) {
        lock.lock()
        generations.removeValue(forKey: key)
        lock.unlock()
    }

    public func removeAll() {
        lock.lock()
        generations.removeAll()
        lock.unlock()
    }

    public func prune(keeping keys: Set<Key>) {
        lock.lock()
        generations = generations.filter { keys.contains($0.key) }
        lock.unlock()
    }
}

/// A single-key generation guard for lifecycle-wide invalidation.
public final class EpochGuard: @unchecked Sendable {
    private let storage = GenerationGuard<Bool>()

    public init() {}

    @discardableResult
    public func advance() -> UInt64 {
        storage.advance(for: false)
    }

    public func current() -> UInt64 {
        storage.current(for: false)
    }
}
