import Foundation

/// Shared admission limits for unauthenticated Bonjour/TCP listeners.
public enum ConnectionAdmissionPolicy {
    public static let maximumUnauthenticatedConnectionsPerWindow = 32
    public static let unauthenticatedConnectionWindow: TimeInterval = 10
    public static let maximumUnauthenticatedConnectionsPerSource = 2
    public static let maximumAcceptsPerSourcePerWindow = 4
    public static let sourceAdmissionWindow: TimeInterval = 10
}

/// Per-host admission state for the pairing listener. It bounds both active
/// unauthenticated transports and accepted connections over a sliding window.
/// Callers keep it on their serial network queue.
public struct PerSourceConnectionAdmissionLimiter: Sendable {
    private struct SourceState: Sendable {
        var activeConnectionIDs = Set<ObjectIdentifier>()
        var eventTimes: [UInt64] = []
        var firstLiveEventIndex = 0

        mutating func expireEvents(at now: UInt64, windowNanoseconds: UInt64) {
            let cutoff = now > windowNanoseconds
                ? now - windowNanoseconds
                : 0
            while firstLiveEventIndex < eventTimes.count,
                  eventTimes[firstLiveEventIndex] <= cutoff {
                firstLiveEventIndex += 1
            }
            compactExpiredPrefixIfNeeded()
        }

        var liveEventCount: Int {
            eventTimes.count - firstLiveEventIndex
        }

        mutating func compactExpiredPrefixIfNeeded() {
            guard firstLiveEventIndex > 0,
                  firstLiveEventIndex >= 64
                    || firstLiveEventIndex * 2 >= eventTimes.count else {
                return
            }
            eventTimes.removeFirst(firstLiveEventIndex)
            firstLiveEventIndex = 0
        }
    }

    private let maximumConcurrentConnections: Int
    private let maximumAccepts: Int
    private let windowNanoseconds: UInt64
    private var sourceStates: [String: SourceState] = [:]
    private var sourceByConnectionID: [ObjectIdentifier: String] = [:]

    public init(
        maximumConcurrentConnections: Int =
            ConnectionAdmissionPolicy.maximumUnauthenticatedConnectionsPerSource,
        maximumAccepts: Int =
            ConnectionAdmissionPolicy.maximumAcceptsPerSourcePerWindow,
        window: TimeInterval = ConnectionAdmissionPolicy.sourceAdmissionWindow
    ) {
        self.maximumConcurrentConnections = max(1, maximumConcurrentConnections)
        self.maximumAccepts = max(1, maximumAccepts)
        windowNanoseconds = max(1, UInt64(max(0, window) * 1_000_000_000))
    }

    /// Records an accepted connection only when both source limits allow it.
    /// A rejected connection does not consume an active slot or rate-window
    /// event. `connectionID` must be unique among currently accepted sockets.
    public mutating func allows(
        connectionID: ObjectIdentifier,
        sourceKey: String,
        eventAt now: UInt64
    ) -> Bool {
        guard sourceByConnectionID[connectionID] == nil else { return false }
        expireOldSources(at: now)

        var state = sourceStates[sourceKey] ?? SourceState()
        state.expireEvents(at: now, windowNanoseconds: windowNanoseconds)
        guard state.activeConnectionIDs.count < maximumConcurrentConnections,
              state.liveEventCount < maximumAccepts else {
            sourceStates[sourceKey] = state
            return false
        }

        state.activeConnectionIDs.insert(connectionID)
        state.eventTimes.append(now)
        sourceStates[sourceKey] = state
        sourceByConnectionID[connectionID] = sourceKey
        return true
    }

    public mutating func remove(connectionID: ObjectIdentifier) {
        guard let sourceKey = sourceByConnectionID.removeValue(
            forKey: connectionID
        ), var state = sourceStates[sourceKey] else {
            return
        }
        state.activeConnectionIDs.remove(connectionID)
        sourceStates[sourceKey] = state
    }

    public mutating func reset() {
        sourceStates.removeAll(keepingCapacity: true)
        sourceByConnectionID.removeAll(keepingCapacity: true)
    }

    private mutating func expireOldSources(at now: UInt64) {
        for sourceKey in Array(sourceStates.keys) {
            guard var state = sourceStates[sourceKey] else { continue }
            state.expireEvents(at: now, windowNanoseconds: windowNanoseconds)
            if state.activeConnectionIDs.isEmpty && state.liveEventCount == 0 {
                sourceStates.removeValue(forKey: sourceKey)
            } else {
                sourceStates[sourceKey] = state
            }
        }
    }
}
