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
}

/// `RemoteInputSink` calls this from its private background injection queue.
/// The layout identifier is served from a lock-protected cache so every
/// keyDown does not need a main-thread round trip. macOS posts
/// `kTISNotifySelectedKeyboardInputSourceChanged` through the distributed
/// notification center when the selected source changes. The observer first
/// invalidates the cache on the posting thread, then schedules the Carbon
/// refresh on the main thread. Once that notification has been delivered, if
/// an input arrives in the interval before the main refresh,
/// `currentIdentifier()` performs that same refresh synchronously before
/// returning, so a pending callback can never make an old layout appear
/// current. The reverse map is still built synchronously on the main thread
/// because its exhaustive `TISGetInputSourceProperty`/`UCKeyTranslate` work
/// must not run concurrently with the capture-side Carbon calls. As with any
/// notification-driven cache, the OS can only invalidate this value once its
/// distributed notification reaches the process; eliminating that separate
/// delivery window would require a Carbon query for every keyDown.
struct CarbonKeyboardLayoutProvider: KeyboardLayoutProviding {
    private let identifierCache: CarbonKeyboardLayoutIdentifierCache

    init() {
        if Thread.isMainThread {
            identifierCache = CarbonKeyboardLayoutIdentifierCache()
        } else {
            identifierCache = DispatchQueue.main.sync {
                CarbonKeyboardLayoutIdentifierCache()
            }
        }
    }

    func currentIdentifier() -> String? {
        identifierCache.currentIdentifier()
    }

    func currentReverseMap() -> KeyboardLayoutReverseMap? {
        if Thread.isMainThread {
            return buildReverseMapOnMain()
        }
        return DispatchQueue.main.sync { buildReverseMapOnMain() }
    }

    private func buildReverseMapOnMain() -> KeyboardLayoutReverseMap? {
        guard let translator = CarbonKeyboardLayout.currentTranslator() else {
            return nil
        }
        // UCKeyTranslate/TISGetInputSourceProperty is performed while still
        // on the main thread. Returning the finished value, rather than a
        // translator that the caller will invoke later, is what prevents
        // Carbon from being accessed concurrently by the input capture and
        // injection paths.
        return KeyboardLayoutReverseMap(translator: translator)
    }
}

/// Maintains the current physical keyboard-layout identifier without making
/// the injection queue synchronously call Carbon for every new keyDown. The
/// identifier source is injected so the generation and stale-refresh logic
/// can be tested without depending on a particular host's TIS state.
/// `TISGetInputSourceProperty` is called once during main-thread
/// initialization and when a notification invalidates the cache. The
/// notification observer itself only flips the invalidation bit, so it is
/// safe for it to run on the posting thread; all Carbon reads remain on the
/// main thread. Background readers copy the short String under the lock and
/// immediately continue while the cache is fresh.
final class CarbonKeyboardLayoutIdentifierCache {
    private let lock = NSLock()
    private let identifierSource: () -> String?
    private var identifier: String?
    // Start stale so the observer is installed before the first Carbon read.
    // This prevents an input-source change in between those two operations
    // from being missed permanently.
    private var needsRefresh = true
    private var invalidationGeneration: UInt64 = 0
    private var notificationToken: NSObjectProtocol?

    init(
        identifierSource: @escaping () -> String? = {
            CarbonKeyboardLayout.currentIdentifier()
        }
    ) {
        precondition(Thread.isMainThread)
        self.identifierSource = identifierSource
        let notificationName = Notification.Name(
            kTISNotifySelectedKeyboardInputSourceChanged as String
        )
        notificationToken = DistributedNotificationCenter.default().addObserver(
            forName: notificationName,
            object: nil,
            // Do not enqueue invalidation on `.main`: an input event could
            // otherwise observe the old identifier while this callback is
            // waiting behind other main-thread work. The callback does no
            // Carbon work and only marks the value stale before scheduling
            // the main-thread refresh.
            queue: nil
        ) { [weak self] _ in
            self?.invalidate()
        }
        // The observer is live before the initial lookup. A transiently
        // unavailable TIS source leaves the cache stale, so later reads retry
        // instead of permanently publishing nil.
        _ = refreshOnMainThread()
    }

    deinit {
        if let notificationToken {
            DistributedNotificationCenter.default().removeObserver(
                notificationToken
            )
        }
    }

    func currentIdentifier() -> String? {
        lock.lock()
        let stale = needsRefresh
        let cachedIdentifier = identifier
        lock.unlock()

        guard stale else { return cachedIdentifier }
        return refreshSynchronouslyOnMainThread()
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

        DispatchQueue.main.async { [weak self] in
            _ = self?.refreshOnMainThread()
        }
    }

    private func refreshSynchronouslyOnMainThread() -> String? {
        if Thread.isMainThread {
            return refreshOnMainThread()
        }
        return DispatchQueue.main.sync {
            refreshOnMainThread()
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
