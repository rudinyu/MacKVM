import Carbon
import Foundation
import MacKVMCore

/// Abstracts the current-layout lookup `RemoteInputSink` needs, so its
/// cross-layout remap logic — which caught five real bugs across two review
/// passes — is testable with a fake layout instead of whatever keyboard
/// layout happens to be active on the machine running the test. The
/// production implementation, `CarbonKeyboardLayoutProvider`, additionally
/// keeps a notification-driven identifier cache and marshals Carbon map
/// construction onto the main thread; see that type's documentation for why.
protocol KeyboardLayoutProviding {
    func currentIdentifier() -> String?
    /// Returns a reverse map whose Carbon/TIS work has already completed on
    /// the provider's platform-safe thread. Callers may perform lookups on a
    /// background queue without touching the underlying input source again.
    func currentReverseMap() -> KeyboardLayoutReverseMap?
    /// Returns the identifier and reverse map from one immutable generation.
    /// Production providers override this to make the read atomic; the
    /// protocol default keeps lightweight test doubles source-compatible.
    func currentSnapshot() -> KeyboardLayoutSnapshot?
}

extension KeyboardLayoutProviding {
    func currentSnapshot() -> KeyboardLayoutSnapshot? {
        guard let identifier = currentIdentifier(),
              let reverseMap = currentReverseMap() else {
            return nil
        }
        return KeyboardLayoutSnapshot(
            identifier: identifier,
            reverseMap: reverseMap
        )
    }
}

/// `RemoteInputSink` calls this from its private background injection queue.
/// The layout identifier and reverse map are served from lock-protected caches
/// so input processing never waits for the main thread. macOS posts
/// `kTISNotifySelectedKeyboardInputSourceChanged` through the distributed
/// notification center when the selected source changes. The observer marks
/// both values stale and schedules all Carbon/TIS work on the main thread. If
/// an input arrives before that refresh completes, the provider returns nil for
/// that event (fail closed) instead of synchronously dispatching to the main
/// thread. This removes a background-to-main wait from the input path and
/// prevents a queue cycle during app/network teardown.
struct CarbonKeyboardLayoutProvider: KeyboardLayoutProviding {
    private let snapshotCache: CarbonKeyboardLayoutSnapshotCache

    init() {
        snapshotCache = CarbonKeyboardLayoutSnapshotCache(
            snapshotMapSource: { () -> (
                reverseMap: KeyboardLayoutReverseMap,
                forwardMap: KeyboardLayoutForwardMap?
            )? in
                guard let translator = CarbonKeyboardLayout.currentTranslator()
                else { return nil }
                return (
                    KeyboardLayoutReverseMap(translator: translator),
                    KeyboardLayoutForwardMap(translator: translator)
                )
            }
        )
    }

    func currentIdentifier() -> String? {
        snapshotCache.currentIdentifier()
    }

    func currentReverseMap() -> KeyboardLayoutReverseMap? {
        snapshotCache.currentReverseMap()
    }

    func currentSnapshot() -> KeyboardLayoutSnapshot? {
        snapshotCache.currentSnapshot()
    }
}

struct KeyboardLayoutSnapshot {
    let identifier: String
    let reverseMap: KeyboardLayoutReverseMap
    let forwardMap: KeyboardLayoutForwardMap?

    init(
        identifier: String,
        reverseMap: KeyboardLayoutReverseMap,
        forwardMap: KeyboardLayoutForwardMap? = nil
    ) {
        self.identifier = identifier
        self.reverseMap = reverseMap
        self.forwardMap = forwardMap
    }
}

/// Publishes the layout identifier and its reverse map as one immutable
/// snapshot. Both values are read and rebuilt on the main thread under the
/// same invalidation generation; background input processing therefore cannot
/// observe a new identifier paired with an old reverse map (or the reverse).
/// The older individual cache types below remain small, independently tested
/// building blocks, but production input uses this combined cache.
final class CarbonKeyboardLayoutSnapshotCache {
    typealias SnapshotMaps = (
        reverseMap: KeyboardLayoutReverseMap,
        forwardMap: KeyboardLayoutForwardMap?
    )
    typealias SnapshotMapSource = () -> SnapshotMaps?
    private let lock = NSLock()
    private let identifierSource: () -> String?
    private let reverseMapSource: () -> KeyboardLayoutReverseMap?
    private let forwardMapSource: () -> KeyboardLayoutForwardMap?
    private let snapshotMapSource: SnapshotMapSource?
    private var snapshot: KeyboardLayoutSnapshot?
    private var needsRefresh = true
    private var invalidationGeneration: UInt64 = 0
    private var refreshScheduled = false
    private var notificationToken: NSObjectProtocol?

    init(
        identifierSource: @escaping () -> String? = {
            CarbonKeyboardLayout.currentIdentifier()
        },
        reverseMapSource: @escaping () -> KeyboardLayoutReverseMap? = {
            guard let translator = CarbonKeyboardLayout.currentTranslator()
            else { return nil }
            return KeyboardLayoutReverseMap(translator: translator)
        },
        forwardMapSource: @escaping () -> KeyboardLayoutForwardMap? = {
            nil
        },
        snapshotMapSource: SnapshotMapSource? = nil
    ) {
        self.identifierSource = identifierSource
        self.reverseMapSource = reverseMapSource
        self.forwardMapSource = forwardMapSource
        self.snapshotMapSource = snapshotMapSource
        let notificationName = Notification.Name(
            kTISNotifySelectedKeyboardInputSourceChanged as String
        )
        notificationToken = DistributedNotificationCenter.default().addObserver(
            forName: notificationName,
            object: nil,
            // Keep invalidation on the main queue so the Carbon/TIS observer
            // and the snapshot refresh share one thread. The callback only
            // flips the lock-protected stale bit; no Carbon work is done
            // until `refreshOnMainThread` runs.
            queue: OperationQueue.main
        ) { [weak self] _ in
            self?.invalidate()
        }
        if Thread.isMainThread {
            refreshOnMainThread()
        } else {
            scheduleRefreshOnMainThread()
        }
    }

    deinit {
        if let notificationToken {
            DistributedNotificationCenter.default().removeObserver(
                notificationToken
            )
        }
    }

    func currentIdentifier() -> String? {
        currentSnapshot()?.identifier
    }

    func currentReverseMap() -> KeyboardLayoutReverseMap? {
        currentSnapshot()?.reverseMap
    }

    func currentSnapshot() -> KeyboardLayoutSnapshot? {
        if Thread.isMainThread {
            refreshOnMainThread()
            lock.lock()
            let current = snapshot
            lock.unlock()
            return current
        }
        lock.lock()
        let stale = needsRefresh
        let current = snapshot
        lock.unlock()
        guard !stale else {
            scheduleRefreshOnMainThread()
            return nil
        }
        return current
    }

    private func invalidate() {
        lock.lock()
        needsRefresh = true
        invalidationGeneration &+= 1
        lock.unlock()
        scheduleRefreshOnMainThread()
    }

    private func scheduleRefreshOnMainThread() {
        lock.lock()
        guard !refreshScheduled else {
            lock.unlock()
            return
        }
        refreshScheduled = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.refreshScheduled = false
            self.lock.unlock()
            self.refreshOnMainThread()
        }
    }

    private func refreshOnMainThread() {
        precondition(Thread.isMainThread)
        lock.lock()
        guard needsRefresh else {
            lock.unlock()
            return
        }
        let generation = invalidationGeneration
        lock.unlock()

        // Keep both Carbon reads in the same main-thread refresh. If a
        // notification arrives during either read, discard the entire pair.
        let nextIdentifier = identifierSource()
        let maps: SnapshotMaps? = nextIdentifier.flatMap { _ in
            if let snapshotMapSource {
                return snapshotMapSource()
            }
            guard let reverseMap = reverseMapSource() else { return nil }
            return (reverseMap, forwardMapSource())
        }

        lock.lock()
        guard invalidationGeneration == generation else {
            lock.unlock()
            scheduleRefreshOnMainThread()
            return
        }
        guard let nextIdentifier, let maps else {
            snapshot = nil
            needsRefresh = true
            lock.unlock()
            return
        }
        snapshot = KeyboardLayoutSnapshot(
            identifier: nextIdentifier,
            reverseMap: maps.reverseMap,
            forwardMap: maps.forwardMap
        )
        needsRefresh = false
        lock.unlock()
    }
}

/// Maintains the current physical keyboard-layout identifier without making
/// the injection queue synchronously call Carbon for every new keyDown. The
/// identifier source is injected so the generation and stale-refresh logic
/// can be tested without depending on a particular host's TIS state.
/// `TISGetInputSourceProperty` is called once during main-thread
/// initialization and when a notification invalidates the cache. The
/// notification observer is delivered on the main queue and only flips the
/// invalidation bit; all Carbon reads remain on the main thread. Background
/// readers copy the short String under the lock and immediately continue
/// while the cache is fresh.
final class CarbonKeyboardLayoutIdentifierCache {
    private let lock = NSLock()
    private let identifierSource: () -> String?
    private var identifier: String?
    // Start stale so the observer is installed before the first Carbon read.
    // This prevents an input-source change in between those two operations
    // from being missed permanently.
    private var needsRefresh = true
    private var invalidationGeneration: UInt64 = 0
    private var refreshScheduled = false
    private var notificationToken: NSObjectProtocol?

    init(
        identifierSource: @escaping () -> String? = {
            CarbonKeyboardLayout.currentIdentifier()
        }
    ) {
        self.identifierSource = identifierSource
        let notificationName = Notification.Name(
            kTISNotifySelectedKeyboardInputSourceChanged as String
        )
        notificationToken = DistributedNotificationCenter.default().addObserver(
            forName: notificationName,
            object: nil,
            // The notification callback only invalidates the lock-protected
            // cache. Keep that callback on the main thread as required by
            // Carbon/TIS ownership; the actual map rebuild is also performed
            // by the main-thread refresh below.
            queue: OperationQueue.main
        ) { [weak self] _ in
            self?.invalidate()
        }
        // The observer is live before the initial lookup. A transiently
        // unavailable TIS source leaves the cache stale, so later reads retry
        // instead of permanently publishing nil. Construction can happen on
        // any queue; Carbon is queried only by the scheduled main-thread
        // refresh.
        if Thread.isMainThread {
            _ = refreshOnMainThread()
        } else {
            scheduleRefreshOnMainThread()
        }
    }

    deinit {
        if let notificationToken {
            DistributedNotificationCenter.default().removeObserver(
                notificationToken
            )
        }
    }

    func currentIdentifier() -> String? {
        if Thread.isMainThread {
            return refreshOnMainThread()
        }
        lock.lock()
        let stale = needsRefresh
        let cachedIdentifier = identifier
        lock.unlock()

        guard stale else { return cachedIdentifier }
        // Never synchronously dispatch from the injection queue to the main
        // thread. The pending refresh will update the cache; this event fails
        // closed while the layout identity is unknown.
        scheduleRefreshOnMainThread()
        return nil
    }

    /// Marks the cached identifier stale. Production calls this from the
    /// distributed-notification callback; keeping the transition explicit
    /// also lets deterministic tests model a notification at any point in a
    /// refresh without depending on the system notification daemon.
    func invalidate() {
        lock.lock()
        needsRefresh = true
        invalidationGeneration &+= 1
        lock.unlock()

        scheduleRefreshOnMainThread()
    }

    private func scheduleRefreshOnMainThread() {
        lock.lock()
        guard !refreshScheduled else {
            lock.unlock()
            return
        }
        refreshScheduled = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.refreshScheduled = false
            self.lock.unlock()
            _ = self.refreshOnMainThread()
        }
    }

    @discardableResult
    private func refreshOnMainThread() -> String? {
        precondition(Thread.isMainThread)

        lock.lock()
        guard needsRefresh else {
            let cachedIdentifier = identifier
            lock.unlock()
            return cachedIdentifier
        }
        let generation = invalidationGeneration
        lock.unlock()

        let nextIdentifier = identifierSource()
        lock.lock()
        guard let nextIdentifier else {
            // Keep the previous value (if any) but leave the cache stale. A
            // subsequent scheduled refresh or key event will retry Carbon.
            lock.unlock()
            return nil
        }
        identifier = nextIdentifier
        // A second layout notification may arrive while Carbon is being
        // queried. Preserve that newer invalidation so the queued refresh
        // cannot accidentally mark its older result as current.
        let isCurrentGeneration = invalidationGeneration == generation
        if isCurrentGeneration { needsRefresh = false }
        let refreshedIdentifier = identifier
        lock.unlock()
        // Do not let a caller use the result from an older generation. The
        // next queued refresh will publish the newer identifier; returning
        // nil here makes the remapping path fail closed for this one event.
        return isCurrentGeneration ? refreshedIdentifier : nil
    }
}

/// Caches the exhaustive reverse map built from Carbon's current keyboard
/// layout. The map is immutable and `Sendable`, so the injection queue can use
/// the completed value without touching TIS/UCKeyTranslate. Layout changes
/// invalidate the cache and rebuild it asynchronously on the main thread.
final class CarbonKeyboardLayoutReverseMapCache {
    private let lock = NSLock()
    private var reverseMap: KeyboardLayoutReverseMap?
    private var needsRefresh = true
    private var invalidationGeneration: UInt64 = 0
    private var refreshScheduled = false
    private var notificationToken: NSObjectProtocol?

    init() {
        let notificationName = Notification.Name(
            kTISNotifySelectedKeyboardInputSourceChanged as String
        )
        notificationToken = DistributedNotificationCenter.default().addObserver(
            forName: notificationName,
            object: nil,
            queue: OperationQueue.main
        ) { [weak self] _ in
            self?.invalidate()
        }
        if Thread.isMainThread {
            refreshOnMainThread()
        } else {
            scheduleRefreshOnMainThread()
        }
    }

    deinit {
        if let notificationToken {
            DistributedNotificationCenter.default().removeObserver(
                notificationToken
            )
        }
    }

    func currentMap() -> KeyboardLayoutReverseMap? {
        lock.lock()
        let stale = needsRefresh
        let map = reverseMap
        lock.unlock()
        guard !stale else {
            scheduleRefreshOnMainThread()
            return nil
        }
        return map
    }

    private func invalidate() {
        lock.lock()
        needsRefresh = true
        invalidationGeneration &+= 1
        lock.unlock()
        scheduleRefreshOnMainThread()
    }

    private func scheduleRefreshOnMainThread() {
        lock.lock()
        guard !refreshScheduled else {
            lock.unlock()
            return
        }
        refreshScheduled = true
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.refreshScheduled = false
            self.lock.unlock()
            self.refreshOnMainThread()
        }
    }

    private func refreshOnMainThread() {
        precondition(Thread.isMainThread)
        lock.lock()
        let generation = invalidationGeneration
        lock.unlock()

        // Carbon/TIS calls and the exhaustive map construction stay on the
        // main thread. Only the finished immutable map crosses to injection.
        let nextMap: KeyboardLayoutReverseMap?
        if let translator = CarbonKeyboardLayout.currentTranslator() {
            nextMap = KeyboardLayoutReverseMap(translator: translator)
        } else {
            nextMap = nil
        }

        lock.lock()
        guard invalidationGeneration == generation else {
            lock.unlock()
            scheduleRefreshOnMainThread()
            return
        }
        reverseMap = nextMap
        needsRefresh = nextMap == nil
        lock.unlock()
    }
}

/// The macOS keyboard-layout input source, read fresh on every call rather
/// than cached, since the user can switch layouts or input methods at any
/// time and this must always reflect what is active right now.
enum CarbonKeyboardLayout {
    /// The physical keyboard layout identifier, independent of any input
    /// method (Zhuyin, Pinyin, ...) layered on top of it.
    ///
    /// `TISCopyCurrentKeyboardLayoutInputSource` is deliberately used instead
    /// of `TISCopyCurrentKeyboardInputSource`: the latter returns the active
    /// input method's own identifier (for example
    /// `com.apple.inputmethod.TCIM.Zhuyin`) while the underlying hardware
    /// layout it types through is unchanged. Comparing input-method
    /// identifiers between two Macs would treat switching an IME on or off as
    /// a layout change and end remote control for no real reason; comparing
    /// the underlying keyboard layout does not.
    static func currentIdentifier() -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?
            .takeRetainedValue(),
              let idPointer = TISGetInputSourceProperty(
                  source,
                  kTISPropertyInputSourceID
              ) else {
            return nil
        }
        let identifier = Unmanaged<CFString>
            .fromOpaque(idPointer)
            .takeUnretainedValue() as String
        let trimmed = identifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 256,
              trimmed.unicodeScalars.allSatisfy({
                  $0.value >= 0x20 && $0.value != 0x7F
              }) else {
            return nil
        }
        return trimmed
    }

    /// A translator backed by the layout identified by `currentIdentifier()`,
    /// for building a `KeyboardLayoutReverseMap` against what is active now.
    static func currentTranslator() -> UnicodeLayoutCharacterProviding? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?
            .takeRetainedValue() else {
            return nil
        }
        return CarbonUnicodeLayoutTranslator(inputSource: source)
    }
}

/// Wraps one `TISInputSource`'s Unicode layout data and exposes it through
/// `UnicodeLayoutCharacterProviding`, isolating every unsafe-pointer and
/// Carbon-modifier-bit detail behind the same small interface
/// `KeyboardLayoutReverseMap` already builds against in tests. The provider
/// constructs that map before returning it so no Carbon/TIS call is deferred
/// to the background injection queue.
private struct CarbonUnicodeLayoutTranslator: UnicodeLayoutCharacterProviding {
    let inputSource: TISInputSource

    func character(
        forKeyCode keyCode: UInt16,
        shift: Bool,
        option: Bool,
        capsLock: Bool
    ) -> String? {
        guard let layoutDataPointer = TISGetInputSourceProperty(
            inputSource,
            kTISPropertyUnicodeKeyLayoutData
        ) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>
            .fromOpaque(layoutDataPointer)
            .takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }

        var carbonModifiers: UInt32 = 0
        if shift { carbonModifiers |= UInt32(shiftKey) }
        if option { carbonModifiers |= UInt32(optionKey) }
        if capsLock { carbonModifiers |= UInt32(alphaLock) }
        // UCKeyTranslate expects the classic EventRecord modifier field,
        // shifted right 8 bits, not the raw shiftKey/optionKey/alphaLock
        // constants directly.
        let keyModifiers = (carbonModifiers >> 8) & 0xFF

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var actualLength = 0
        let status = bytes.withMemoryRebound(
            to: UCKeyboardLayout.self,
            capacity: 1
        ) { layout in
            UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDown),
                keyModifiers,
                // A modern `uchr` resource can still bundle distinct
                // sub-tables for ANSI/ISO/JIS hardware (they differ in the
                // position or presence of keys like the ISO "section" key),
                // selected by keyboard type. A fixed value here silently
                // picked the wrong sub-table on ISO/JIS hardware; the real
                // hardware type is required.
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &actualLength,
                &chars
            )
        }
        guard status == noErr, actualLength > 0 else {
            return nil
        }
        return String(utf16CodeUnits: chars, count: actualLength)
    }
}
