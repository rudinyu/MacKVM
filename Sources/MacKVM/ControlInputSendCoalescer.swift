import Foundation
import MacKVMCore

/// Keeps the control wire ordered while replacing redundant absolute pointer
/// positions. A move or drag is a snapshot, not an edge: when several
/// snapshots of the same pointer stream are waiting behind the same request,
/// only the newest position has observable value. Keyboard, button, scroll,
/// and lifecycle messages always flush the pending pointer first so they
/// cannot be reordered across it.
struct ControlInputMessageBuffer {
    private var pendingPointerMove: ControlMessage?

    var hasPendingPointerMove: Bool {
        pendingPointerMove != nil
    }

    mutating func enqueue(_ message: ControlMessage) -> [ControlMessage] {
        guard Self.isCoalesciblePointer(message) else {
            return flush() + [message]
        }

        guard let pendingPointerMove else {
            self.pendingPointerMove = message
            return []
        }

        guard pendingPointerMove.requestID == message.requestID,
              pendingPointerMove.input?.kind == message.input?.kind,
              pendingPointerMove.input?.kind != .otherMouseDragged
                || pendingPointerMove.input?.buttonNumber
                    == message.input?.buttonNumber else {
            self.pendingPointerMove = message
            return [pendingPointerMove]
        }

        // The latest absolute position supersedes the earlier one.
        self.pendingPointerMove = message
        return []
    }

    mutating func flush() -> [ControlMessage] {
        guard let pendingPointerMove else { return [] }
        self.pendingPointerMove = nil
        return [pendingPointerMove]
    }

    mutating func reset() {
        pendingPointerMove = nil
    }

    private static func isCoalesciblePointer(_ message: ControlMessage) -> Bool {
        guard message.kind == .input, let input = message.input else {
            return false
        }
        switch input.kind {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged,
             .otherMouseDragged:
            return true
        default:
            return false
        }
    }
}

/// A small, bounded-latency sender-side coalescer for high-rate pointer
/// events. The secure transport remains the owner of encryption and socket
/// ordering; this class only reduces redundant absolute mouse snapshots before
/// they enter that transport's pending payload queue.
final class ControlInputSendCoalescer {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let flushInterval: DispatchTimeInterval
    private let sendMessage: (ControlMessage) -> Void
    private var buffer = ControlInputMessageBuffer()
    private var flushTimer: DispatchSourceTimer?
    private var stopped = false

    init(
        label: String = "app.mackvm.control-input-coalescer",
        flushInterval: DispatchTimeInterval = .milliseconds(4),
        sendMessage: @escaping (ControlMessage) -> Void
    ) {
        queue = DispatchQueue(label: label, qos: .userInteractive)
        queue.setSpecific(key: queueKey, value: ())
        self.flushInterval = flushInterval
        self.sendMessage = sendMessage
    }

    /// Processes messages synchronously so lifecycle messages are observable
    /// by callers in their original order. The only delayed path is a pending
    /// pointer snapshot, which is released by the short timer below.
    func send(_ message: ControlMessage) {
        syncOnQueue {
            guard !stopped else { return }
            let immediate = buffer.enqueue(message)
            immediate.forEach(sendMessage)
            if buffer.hasPendingPointerMove {
                scheduleFlushLocked()
            }
        }
    }

    /// Flushes a pending pointer snapshot before a control end, disconnect, or
    /// test assertion. It is safe to call repeatedly.
    func flush() {
        syncOnQueue {
            guard !stopped else { return }
            flushPendingLocked()
        }
    }

    /// Drops a snapshot that belongs to a connection which is no longer
    /// usable. This prevents a stale movement from being sent after a later
    /// session starts.
    func reset() {
        syncOnQueue {
            guard !stopped else { return }
            cancelTimerLocked()
            buffer.reset()
        }
    }

    deinit {
        syncOnQueue {
            stopped = true
            cancelTimerLocked()
            buffer.reset()
        }
    }

    /// A timer callback may be the last owner of this object, which means
    /// deinit can run on the coalescer queue itself. DispatchQueue.sync would
    /// deadlock in that case; execute inline when the queue-specific marker is
    /// already present.
    private func syncOnQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            work()
        } else {
            queue.sync(execute: work)
        }
    }

    private func scheduleFlushLocked() {
        guard flushTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + flushInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            flushPendingLocked()
        }
        flushTimer = timer
        timer.resume()
    }

    private func flushPendingLocked() {
        cancelTimerLocked()
        buffer.flush().forEach(sendMessage)
    }

    private func cancelTimerLocked() {
        flushTimer?.cancel()
        flushTimer = nil
    }
}
