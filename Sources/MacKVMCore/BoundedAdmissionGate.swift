import Foundation

/// A lock-protected admission gate for stateful asynchronous work.
/// Reservations carry their generation so work from an invalidated session
/// cannot decrement the count of a newer session.
public final class BoundedAdmissionGate: @unchecked Sendable {
    public static let defaultCapacity = 256

    public struct Reservation: Equatable, Sendable {
        public let generation: UInt64?
        public let shouldSignalFailure: Bool

        public var accepted: Bool { generation != nil }

        fileprivate init(
            generation: UInt64?,
            shouldSignalFailure: Bool
        ) {
            self.generation = generation
            self.shouldSignalFailure = shouldSignalFailure
        }
    }

    private let capacity: Int
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pendingByGeneration: [UInt64: Int] = [:]
    private var pendingReservationCount = 0
    private var isEnabled: Bool
    private var isLatchedClosed = false
    private var failureSignalled = false

    public init(
        capacity: Int = BoundedAdmissionGate.defaultCapacity,
        initiallyEnabled: Bool = false
    ) {
        self.capacity = max(0, capacity)
        self.isEnabled = initiallyEnabled
    }

    public func begin() {
        lock.lock()
        // Wrapping is intentional; reaching 2^64 transport generations is
        // not realistic, while &+= keeps this safety primitive total.
        generation &+= 1
        isEnabled = true
        isLatchedClosed = false
        failureSignalled = false
        lock.unlock()
    }

    /// Enables the current transport generation, advancing only when the
    /// previous generation was invalidated or overflowed. This lets an
    /// authenticated transport signal readiness before its UI publisher has
    /// delivered the corresponding connected-peer event.
    public func activate() {
        lock.lock()
        if !isEnabled {
            guard !isLatchedClosed else {
                lock.unlock()
                return
            }
            // See begin(): generation wrap is practically unreachable and
            // wrapping keeps the guard usable for its entire process life.
            generation &+= 1
            isEnabled = true
            failureSignalled = false
        }
        lock.unlock()
    }

    public func invalidate() {
        invalidate(ifCurrentGeneration: nil)
    }

    /// Invalidates the gate only when the caller still refers to the current
    /// generation. UI connection publishers can deliver a stale disconnect
    /// after a newer authenticated session has already begun; in that case
    /// the stale event must not close the new session's admission window.
    public func invalidate(ifCurrentGeneration expectedGeneration: UInt64?) {
        lock.lock()
        if let expectedGeneration, expectedGeneration != generation {
            lock.unlock()
            return
        }
        generation &+= 1
        isEnabled = false
        isLatchedClosed = false
        lock.unlock()
    }

    public func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    public func reserve() -> Reservation {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled else {
            return Reservation(generation: nil, shouldSignalFailure: false)
        }
        let pending = pendingByGeneration[generation] ?? 0
        guard pendingReservationCount < capacity else {
            // Older generations may still have callbacks queued on the main
            // queue. Signal the transport once rather than silently dropping
            // a stateful message; the disconnect path will invalidate this
            // generation while the old reservations drain.
            guard pending >= capacity else {
                let shouldSignal = !failureSignalled
                failureSignalled = true
                return Reservation(
                    generation: nil,
                    shouldSignalFailure: shouldSignal
                )
            }
            isEnabled = false
            isLatchedClosed = true
            let shouldSignal = !failureSignalled
            failureSignalled = true
            return Reservation(
                generation: nil,
                shouldSignalFailure: shouldSignal
            )
        }
        pendingByGeneration[generation] = pending + 1
        pendingReservationCount += 1
        return Reservation(generation: generation, shouldSignalFailure: false)
    }

    public func isCurrent(_ reservation: Reservation) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let reservationGeneration = reservation.generation else {
            return false
        }
        // An admission overflow stops accepting new work, but it must not
        // invalidate work that was already admitted. Only begin/invalidate
        // advances the generation and makes queued work stale.
        return reservationGeneration == generation
    }

    public func release(_ reservation: Reservation) {
        guard let reservationGeneration = reservation.generation else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        guard let pending = pendingByGeneration[reservationGeneration] else {
            return
        }
        if pending <= 1 {
            pendingByGeneration.removeValue(forKey: reservationGeneration)
        } else {
            pendingByGeneration[reservationGeneration] = pending - 1
        }
        pendingReservationCount -= 1
    }
}
