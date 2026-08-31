import AppKit
import Combine
import CryptoKit
import Foundation
import MacKVMCore
import Network

/// One-shot latch so a connection that reports both `.failed` and `.cancelled`
/// leaves the sleep flush group exactly once.
private final class SleepFlushLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = true

    func close() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { return false }
        isOpen = false
        return true
    }
}

enum SecureSessionRevocationPolicy {
    static func removesActiveContext(
        activeContextID: ObjectIdentifier?,
        revokedContextIDs: Set<ObjectIdentifier>
    ) -> Bool {
        guard let activeContextID else { return false }
        return revokedContextIDs.contains(activeContextID)
    }
}

enum SecureSessionCompatibilityDecision: Equatable {
    case compatible
    case requiresPeerUpgrade
}

enum SecureSessionCompatibilityPolicy {
    /// The encrypted disconnect marker is part of the current secure-session
    /// contract. A peer without its signed capability must not be admitted via
    /// a weaker EOF fallback, because an on-path party could strip the
    /// extension and silently downgrade the disconnect behavior.
    static func decision(
        for disconnectSignalVersion: Int?
    ) -> SecureSessionCompatibilityDecision {
        disconnectSignalVersion
            == SecureSessionHandshake.currentDisconnectSignalVersion
            ? .compatible
            : .requiresPeerUpgrade
    }
}

enum SecureSessionDisconnectPolicy {
    static func shouldRetryAfterRemoval(
        removedActiveContext: Bool,
        localRole: SecureSessionRole,
        retriesAfterRemoval: Bool,
        desiredPeerMatches: Bool,
        hasDesiredPeer: Bool,
        suppressesReconnect: Bool
    ) -> Bool {
        // A close marker suppresses recovery for the peer that was just
        // deliberately closed. `disconnect()` clears the desired peer before
        // the contexts are removed, so the common case reaches here with no
        // desired peer at all and must still be suppressed. Only a *different*
        // peer that remains the user's reconnect target keeps recovery alive.
        let suppressesThisPeer = suppressesReconnect
            && (desiredPeerMatches || !hasDesiredPeer)
        guard !suppressesThisPeer else { return false }
        return removedActiveContext
            || localRole == .initiator
            || (retriesAfterRemoval && desiredPeerMatches)
    }
}

final class SecureSessionService: ObservableObject, ControlSessionTransport {
    @Published private(set) var connectedPeerID: UUID?
    @Published private(set) var status = "Secure session idle"
    @Published private(set) var isReconnecting = false

    var onPayload: ((Data) -> Void)?
    var onAuthenticated: (() -> UInt64)?

    private let connectionPublicationSubject =
        PassthroughSubject<ControlConnectionPublication, Never>()

    var connectedPeerIDPublisher: AnyPublisher<UUID?, Never> {
        $connectedPeerID.eraseToAnyPublisher()
    }

    var connectionPublicationPublisher:
        AnyPublisher<ControlConnectionPublication, Never> {
        connectionPublicationSubject.eraseToAnyPublisher()
    }

    private static let serviceType = "_mackvm-secure._tcp"
    private static let maximumPendingConnections = 16
    private static let maximumPeerCandidatesPerID = 8
    private static let maximumPendingPayloads = 64
    // Accommodate high-polling-rate mice without turning ordinary movement
    // into a transport failure, while retaining a bounded per-session budget.
    private static let maximumInboundPacketsPerSecond = 8_192
    private static let maximumInboundBytesPerSecond = 8 * 1024 * 1024
    // A dropped didWake notification must not gate secure networking for the
    // rest of the process lifetime. DispatchTime does not advance while the
    // Mac is asleep, so this deadline measures awake time: a real sleep never
    // reaches it, while an aborted or unobserved wake self-clears.
    static let defaultSystemSleepLatchTimeout: TimeInterval = 60
    // Bounded wait so the transport's FIN reaches the peer before the
    // workspace acknowledges the sleep transition, without letting a stuck
    // socket delay that transition.
    private static let sleepTransportFlushTimeout: DispatchTimeInterval =
        .milliseconds(750)
    // Give an authenticated peer a bounded window to receive the encrypted
    // user-disconnect signal before the local socket is torn down.
    private static let disconnectTransportFlushTimeout: DispatchTimeInterval =
        .milliseconds(750)
    private static let partialFrameTimeout: TimeInterval = 5
    private static let partialFrameTimeoutNanoseconds =
        UInt64(partialFrameTimeout * 1_000_000_000)
    private static let maximumWireBufferLength =
        SecureSessionWireCodec.maximumFramePayloadLength + 4
    private static let keyConfirmation = Data(
        "MacKVM encrypted key confirmation v1".utf8
    )
    private let queue = DispatchQueue(label: "app.mackvm.secure-session")
    private let credentials: DeviceCredentials
    private let registry: PairingRegistry
    let localModel: String
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var networkRecoveryWorkItem: DispatchWorkItem?
    private var networkRecoveryAttempt = 0
    private var networkRecoveryGeneration: UInt64 = 0
    private var peersByID: [UUID: [SecureServicePeer]] = [:]
    private var peerCandidateIndices: [UUID: Int] = [:]
    private var preferredPeerEndpoints: [UUID: NWEndpoint] = [:]
    private var contexts: [ObjectIdentifier: SessionConnectionContext] = [:]
    private var activeContextID: ObjectIdentifier?
    private let connectionEpoch = EpochGuard()
    private let peerEpochs = GenerationGuard<UUID>()
    private var admissionLimiter =
        ConnectionAdmissionLimiter.unauthenticatedConnectionLimiter()
    private var pathMonitor: NWPathMonitor?
    private var networkPathSatisfied = true
    private var powerLifecycleObserver: SystemPowerLifecycleObserver?
    private var isSystemSleeping = false
    private var systemSleepLatchWorkItem: DispatchWorkItem?
    private var desiredPeerID: UUID?
    private var pendingConnectPeerID: UUID?
    /// Older peers cannot understand the encrypted disconnect marker. Keep
    /// them from immediately recreating a session after a local Disconnect;
    /// an explicit Connect or a newer pairing generation clears this gate.
    private var locallyDisconnectedPeerIDs = Set<UUID>()
    /// The trust generation present when each deliberate-disconnect gate was
    /// created. A later Forget-and-pair operation increments the generation,
    /// allowing that genuinely new pairing to auto-connect without allowing a
    /// stale completion callback from the old pairing to do so.
    private var locallyDisconnectedPeerGenerations: [UUID: UInt64] = [:]
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private let reconnectBackoff = ReconnectBackoffPolicy()
    private let powerNotificationCenterOverride: NotificationCenter?
    private let networkServicesEnabled: Bool
    private let systemSleepLatchTimeout: TimeInterval

    init(
        credentials: DeviceCredentials,
        registry: PairingRegistry,
        localModel: String = MacHardwareInfo.currentModel,
        // Test seams. Production uses the workspace notification center, the
        // real Bonjour components, and the default sleep-latch timeout.
        powerNotificationCenter: NotificationCenter? = nil,
        networkServicesEnabled: Bool = true,
        systemSleepLatchTimeout: TimeInterval =
            SecureSessionService.defaultSystemSleepLatchTimeout
    ) {
        self.credentials = credentials
        self.registry = registry
        self.localModel = PeerMetadataValidation.validatedModel(localModel)
        self.powerNotificationCenterOverride = powerNotificationCenter
        self.networkServicesEnabled = networkServicesEnabled
        self.systemSleepLatchTimeout = systemSleepLatchTimeout
    }

    func start() {
        // NSWorkspace is an AppKit singleton, so resolve it on the caller's
        // thread (the main thread in the app) instead of inside the
        // secure-session queue, where the first touch would initialize AppKit
        // state off the main thread.
        let powerNotificationCenter = powerNotificationCenterOverride
            ?? NSWorkspace.shared.notificationCenter
        queue.async { [weak self] in
            guard let self else { return }
            // A previous run must never leave the sleep guards latched on.
            clearSystemSleepLatch()
            startPowerLifecycleObserver(
                notificationCenter: powerNotificationCenter
            )
            startPathMonitor()
            startMissingNetworkServices()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            powerLifecycleObserver = nil
            clearSystemSleepLatch()
            connectionEpoch.advance()
            desiredPeerID = nil
            pendingConnectPeerID = nil
            locallyDisconnectedPeerIDs.removeAll()
            locallyDisconnectedPeerGenerations.removeAll()
            cancelReconnect(resetAttempt: true)
            networkRecoveryGeneration &+= 1
            networkRecoveryWorkItem?.cancel()
            networkRecoveryWorkItem = nil
            networkRecoveryAttempt = 0
            pathMonitor?.cancel()
            pathMonitor = nil
            listener?.cancel()
            browser?.cancel()
            let oldContexts = Array(contexts.values)
            let hadActiveContext = activeContextID != nil
            oldContexts.forEach {
                $0.connection.cancel()
                self.remove($0)
            }
            listener = nil
            browser = nil
            peersByID.removeAll()
            peerCandidateIndices.removeAll()
            preferredPeerEndpoints.removeAll()
            activeContextID = nil
            peerEpochs.removeAll()
            admissionLimiter.reset()
            if hadActiveContext {
                // remove(_:) already published the generation-tagged nil
                // connection event; update only the human-readable status.
                publishStatus("Secure session stopped")
            } else {
                publishConnection(peerID: nil, status: "Secure session stopped")
            }
        }
    }

    func connect(to peerID: UUID) {
        connect(to: peerID, automaticPairing: false)
    }

    /// Used only by the pairing-completion callback. A stale callback may be
    /// delivered after the user has pressed Disconnect, so it must not clear
    /// the deliberate-disconnect gate like an explicit Connect action does.
    func connectAutomaticallyAfterPairing(
        to peerID: UUID,
        pairingGeneration: UInt64? = nil
    ) {
        connect(
            to: peerID,
            automaticPairing: true,
            pairingGeneration: pairingGeneration
        )
    }

    private func connect(
        to peerID: UUID,
        automaticPairing: Bool,
        pairingGeneration: UInt64? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            // An explicit Connect is the user's own recovery action. Clear a
            // sleep latch that a missed didWake notification could otherwise
            // have left set, so the request is not silently dropped by the
            // sleep guards further down this path.
            if !automaticPairing {
                clearSystemSleepLatch()
            }
            guard PeerArbitration.isValidPeerPair(
                localID: credentials.identity.id,
                remoteID: peerID
            ) else {
                logSecurePhase(
                    "connect.rejected-self-identity",
                    peerID: peerID
                )
                publishStatus("Cannot connect to this Mac's own identity")
                return
            }
            if automaticPairing,
               locallyDisconnectedPeerIDs.contains(peerID) {
                let isFreshPairing = pairingGeneration.map {
                    $0 > (self.locallyDisconnectedPeerGenerations[peerID] ?? 0)
                } ?? false
                if isFreshPairing {
                    locallyDisconnectedPeerIDs.remove(peerID)
                    locallyDisconnectedPeerGenerations.removeValue(
                        forKey: peerID
                    )
                } else {
                    logSecurePhase(
                        "connect.ignored-stale-pairing-callback",
                        peerID: peerID,
                        detail: "explicit-disconnect-gate"
                    )
                    publishStatus("Secure session remains disconnected")
                    return
                }
            }
            let hasClosingContext = contexts.values.contains {
                $0.isClosing
            }
            if hasClosingContext {
                desiredPeerID = peerID
                pendingConnectPeerID = peerID
                cancelReconnect(resetAttempt: true)
                logSecurePhase(
                    "connect.queued-while-disconnecting",
                    peerID: peerID
                )
                publishStatus("Waiting for the secure session to close…")
                return
            }
            // A pairing completion can race with the automatic secure
            // connection it triggers. If authentication wins that race, the
            // active responder context is already established when this
            // callback arrives. Preserve the reconnect intent for that same
            // peer instead of rejecting it with no desiredPeerID; otherwise a
            // later network interruption would have no target to reconnect.
            let authenticatedContext = contexts.values.first {
                $0.isAuthenticated && $0.expectedPeer?.id == peerID
            }
            let hasExistingSession = activeContextID != nil
                || contexts.values.contains(where: {
                    $0.localRole == .initiator
                })
            if hasExistingSession {
                guard authenticatedContext != nil else {
                    // A pairing callback can race the very handshake it
                    // triggered. That in-flight context is the session this
                    // callback asked for, so record the intent instead of
                    // telling the user to disconnect a session they just
                    // created; otherwise this Mac ends up authenticated with
                    // no reconnect target at all.
                    if automaticPairing,
                       contexts.values.contains(
                           where: { $0.expectedPeer?.id == peerID }
                       ) {
                        desiredPeerID = peerID
                        cancelReconnect(resetAttempt: true)
                        logSecurePhase(
                            "connect.intent-recorded-pending-handshake",
                            peerID: peerID,
                            detail: "automatic-pairing-race"
                        )
                        return
                    }
                    logSecurePhase(
                        "connect.rejected-existing-session",
                        peerID: peerID,
                        detail: "desired-peer-preserved-pending-handshake"
                    )
                    publishStatus("Disconnect the current secure session first")
                    return
                }
                if !automaticPairing {
                    locallyDisconnectedPeerIDs.remove(peerID)
                    locallyDisconnectedPeerGenerations.removeValue(
                        forKey: peerID
                    )
                }
                pendingConnectPeerID = nil
                desiredPeerID = peerID
                cancelReconnect(resetAttempt: true)
                logSecurePhase(
                    "connect.intent-recorded-active-session",
                    peerID: peerID,
                    context: authenticatedContext,
                    detail: "automatic-pairing-race"
                )
                publishStatus("Secure session already connected; reconnect target saved")
                return
            }
            // Clear the deliberate-disconnect gate only once this explicit
            // request is actually eligible to establish a session. A Connect
            // rejected because another peer is active must leave the gate in
            // place, or a later automatic callback could undo Disconnect.
            if !automaticPairing {
                locallyDisconnectedPeerIDs.remove(peerID)
                locallyDisconnectedPeerGenerations.removeValue(
                    forKey: peerID
                )
            }
            pendingConnectPeerID = nil
            logSecurePhase("connect.requested", peerID: peerID)
            desiredPeerID = peerID
            cancelReconnect(resetAttempt: true)
            // Secure Bonjour intentionally filters out identities that are not
            // pinned yet. Pairing can therefore finish after the last browser
            // callback for this service; refresh discovery so the newly pinned
            // key is resolved without waiting for the peer to restart or emit
            // another mDNS change.
            if peersByID[peerID]?.isEmpty != false {
                refreshBrowserOnQueue()
            }
            connectOnQueue(to: peerID)
        }
    }

    /// Closes the transport before macOS suspends networking, while retaining
    /// the user's selected peer so the normal reconnect path can resume after
    /// wake. Without this explicit lifecycle boundary, a sleeping Mac can
    /// leave its peer's TCP connection half-open and both control coordinators
    /// continue to believe the old session is usable.
    func prepareForSleep() {
        let transportFlush = DispatchGroup()
        // The workspace acknowledges the sleep transition once this handler
        // returns, so the teardown has to run synchronously here instead of
        // being queued behind whatever the session queue is already doing.
        queue.sync {
            guard !isSystemSleeping else { return }
            isSystemSleeping = true
            scheduleSystemSleepLatchTimeout()
            logSecurePhase("power.will-sleep")
            cancelReconnect(resetAttempt: true)
            networkRecoveryGeneration &+= 1
            networkRecoveryWorkItem?.cancel()
            networkRecoveryWorkItem = nil
            networkRecoveryAttempt = 0
            connectionEpoch.advance()

            let oldContexts = Array(contexts.values)
            let hadActiveContext = activeContextID != nil
            oldContexts.forEach {
                // The context is about to be removed, so its own state
                // handler stops running. Report the terminal state into the
                // flush group instead, so this call can wait for the
                // cancellation to reach the wire.
                let latch = SleepFlushLatch()
                transportFlush.enter()
                $0.connection.stateUpdateHandler = { state in
                    switch state {
                    case .cancelled, .failed:
                        if latch.close() {
                            transportFlush.leave()
                        }
                    default:
                        break
                    }
                }
                $0.connection.cancel()
                self.remove($0)
            }

            listener?.cancel()
            browser?.cancel()
            listener = nil
            browser = nil
            peersByID.removeAll()
            peerCandidateIndices.removeAll()
            preferredPeerEndpoints.removeAll()

            if hadActiveContext {
                publishStatus("Secure session paused for system sleep")
            } else {
                publishConnection(
                    peerID: nil,
                    status: "Secure session paused for system sleep"
                )
            }
        }
        _ = transportFlush.wait(
            timeout: .now() + Self.sleepTransportFlushTimeout
        )
    }

    /// Restarts discovery and reconnects only the peer selected before sleep.
    /// A deliberate Disconnect clears `desiredPeerID`, so waking after that
    /// action cannot unexpectedly create a new session.
    func resumeAfterWake() {
        queue.async { [weak self] in
            guard let self else { return }
            resumeFromSystemSleepOnQueue(
                phase: "power.did-wake",
                reconnectingStatus:
                    "System woke; reconnecting to the paired Mac…"
            )
        }
    }

    private func resumeFromSystemSleepOnQueue(
        phase: String,
        reconnectingStatus: String
    ) {
        let wasSleeping = isSystemSleeping
        clearSystemSleepLatch()
        guard wasSleeping else { return }
        logSecurePhase(phase)
        networkRecoveryAttempt = 0
        startMissingNetworkServices()
        // prepareForSleep() emptied the peer table, and the browser is only
        // restarting now, so a zero-delay attempt is guaranteed to find no
        // candidate and publish a false "service is not available" status.
        // Start from the first backed-off step so discovery gets a turn.
        reconnectAttempt = max(reconnectAttempt, 1)
        retryConnectionIfNeeded()
        publishStatus(
            desiredPeerID == nil
                ? "Secure session services resumed"
                : reconnectingStatus
        )
    }

    /// Queue-synchronized view of the sleep lifecycle state, so tests can
    /// assert on it without racing the secure-session queue.
    struct SleepLifecycleSnapshot: Equatable {
        var isSystemSleeping: Bool
        var desiredPeerID: UUID?
        var reconnectAttempt: Int
        var hasScheduledReconnect: Bool
    }

    var sleepLifecycleSnapshot: SleepLifecycleSnapshot {
        queue.sync {
            SleepLifecycleSnapshot(
                isSystemSleeping: isSystemSleeping,
                desiredPeerID: desiredPeerID,
                reconnectAttempt: reconnectAttempt,
                hasScheduledReconnect: reconnectWorkItem != nil
            )
        }
    }

    /// Clears the sleep latch and its watchdog. Every guard added for sleep
    /// also blocks ordinary recovery, so the latch must never outlive the
    /// wake it was waiting for.
    private func clearSystemSleepLatch() {
        isSystemSleeping = false
        systemSleepLatchWorkItem?.cancel()
        systemSleepLatchWorkItem = nil
    }

    /// Arms the watchdog that recovers from a `willSleep` notification whose
    /// matching `didWake` never arrives — an aborted sleep, or a wake this
    /// process did not observe. Without it a single missed notification would
    /// leave secure networking gated off until the app is relaunched.
    private func scheduleSystemSleepLatchTimeout() {
        systemSleepLatchWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, isSystemSleeping else { return }
            resumeFromSystemSleepOnQueue(
                phase: "power.sleep-latch-expired",
                reconnectingStatus: "Reconnecting to the paired Mac…"
            )
        }
        systemSleepLatchWorkItem = workItem
        queue.asyncAfter(
            deadline: .now() + systemSleepLatchTimeout,
            execute: workItem
        )
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            logSecurePhase("disconnect.requested")
            let previouslyDesiredPeerID = desiredPeerID
            desiredPeerID = nil
            pendingConnectPeerID = nil
            cancelReconnect(resetAttempt: true)
            connectionEpoch.advance()
            // Disconnect is a session-wide local safety action. Cancel every
            // context, including handshakes that have not selected a peer,
            // so no stale callback can promote an old session afterward.
            locallyDisconnectedPeerIDs.formUnion(
                contexts.values.compactMap { $0.expectedPeer?.id }
            )
            for peerID in contexts.values.compactMap({ $0.expectedPeer?.id }) {
                locallyDisconnectedPeerGenerations[peerID] = registry.generation(
                    for: peerID
                )
            }
            if let previouslyDesiredPeerID {
                locallyDisconnectedPeerIDs.insert(previouslyDesiredPeerID)
                locallyDisconnectedPeerGenerations[previouslyDesiredPeerID] =
                    registry.generation(for: previouslyDesiredPeerID)
            }
            let activeContext = activeContextID.flatMap { self.contexts[$0] }
            // `disconnect()` advances the session epoch to invalidate stale
            // callbacks. The active context remains alive for the encrypted
            // close marker and acknowledgement, so move only that context
            // into the new close epoch before removing its active role.
            activeContext?.epoch = connectionEpoch.current()
            let hadActiveContext = activeContext != nil
            if let activeContext {
                // Publish the local disconnect immediately so ControlCoordinator
                // releases local input while the close signal is still being
                // flushed to the peer. The context remains installed only long
                // enough for that authenticated signal to reach the wire.
                activeContext.suppressesReconnect = true
                activeContextID = nil
                publishConnection(
                    peerID: nil,
                    status: "Secure session disconnected",
                    admissionGeneration: activeContext.admissionGeneration
                )
            }
            for context in Array(contexts.values) {
                // A channel is usable before the final key-confirmation
                // callback marks the context authenticated. If Disconnect
                // races that small window, send the authenticated close
                // marker after the already-queued handshake bytes instead of
                // turning the peer's EOF into an apparent network failure.
                context.epoch = connectionEpoch.current()
                if context.isClosing {
                    // An authenticated close is already in flight. Restarting
                    // it here would take the cancel path and hand the peer a
                    // bare EOF, which is exactly the ambiguity the close
                    // marker exists to remove: the peer would keep its
                    // reconnect intent and immediately rebuild the session.
                    context.suppressesReconnect = true
                    continue
                }
                if context.channel != nil {
                    context.suppressesReconnect = true
                    sendDisconnectSignal(for: context)
                } else {
                    context.connection.cancel()
                    remove(context)
                }
            }
            if hadActiveContext {
                // The generation-tagged nil connection event was published
                // before the wire close so local control is torn down without
                // waiting for Network.framework.
                publishStatus("Secure session disconnected")
            } else {
                publishConnection(
                    peerID: nil,
                    status: "Secure session disconnected"
                )
            }
        }
    }

    /// Revokes trust and intentionally cancels anonymous handshakes as well:
    /// before identity attribution, an in-flight context cannot be safely
    /// proven unrelated to the revoked peer.
    func revoke(
        _ peerID: UUID,
        trustAlreadyRevoked: Bool = false
    ) {
        MacKVMLogger.secureSession.info(
            "phase=trust.revoke.requested peer=\(MacKVMLogger.short(peerID)) trustAlreadyRevoked=\(trustAlreadyRevoked)"
        )
        // Remove trust before scheduling queue cleanup. Discovery and the
        // secure listener have independent serial queues, so a queued-only
        // removal would leave a window in which a revoked peer could finish
        // a new inbound handshake with the old pinned key. The app-level
        // Forget entry point performs that synchronous revoke once, then
        // passes trustAlreadyRevoked to this cleanup path.
        if !trustAlreadyRevoked {
            registry.revoke(peerID)
        }
        queue.async { [weak self] in
            guard let self else { return }
            logSecurePhase("trust.revoke.cleanup.begin", peerID: peerID)
            if desiredPeerID == peerID {
                desiredPeerID = nil
                cancelReconnect(resetAttempt: true)
            }
            peerEpochs.advance(for: peerID)
            preferredPeerEndpoints.removeValue(forKey: peerID)
            // Anonymous contexts cannot be safely attributed to a different
            // peer yet. Drop them as well so a handshake racing Forget cannot
            // establish trust before its identity is rechecked.
            let revokedContexts = contexts.values.filter {
                $0.expectedPeer?.id == peerID
                    || (!$0.isAuthenticated && $0.expectedPeer == nil)
            }
            let removedActiveContext =
                SecureSessionRevocationPolicy.removesActiveContext(
                    activeContextID: activeContextID,
                    revokedContextIDs: Set(
                        revokedContexts.map { ObjectIdentifier($0) }
                    )
                )
            revokedContexts.forEach {
                $0.connection.cancel()
                self.remove($0)
            }
            if removedActiveContext {
                // remove(_:) already published the generation-tagged nil
                // event; update only its status to keep the event associated
                // with the revoked session.
                publishStatus(
                    "Trust revoked; the active peer was disconnected"
                )
            } else if !revokedContexts.isEmpty {
                publishStatus("Trust revoked; an unrelated handshake was cancelled")
            }
            logSecurePhase(
                "trust.revoke.cleanup.finished",
                peerID: peerID,
                detail: "removed=\(revokedContexts.count)"
            )
        }
    }

    func send(_ payload: Data) {
        queue.async { [weak self] in
            guard let self,
                  let activeContextID,
                  let context = contexts[activeContextID],
                  context.channel != nil else {
                self?.logSecurePhase(
                    "payload.send.rejected",
                    detail: "no-active-session"
                )
                self?.publishStatus("No encrypted session is connected")
                return
            }
            guard payload.count <= SecureSessionChannel.maximumPlaintextLength else {
                logSecurePhase(
                    "payload.send.rejected",
                    context: context,
                    detail: "oversized"
                )
                publishStatus("Secure session rejected an oversized payload")
                return
            }
            guard context.pendingPayloads.count
                    < Self.maximumPendingPayloads else {
                logSecurePhase(
                    "payload.send.rejected",
                    context: context,
                    detail: "pending-queue-full"
                )
                fail(
                    context,
                    message: "Secure session disconnected because input could not keep up"
                )
                return
            }
            context.pendingPayloads.append(payload)
            flushPayloads(in: context)
        }
    }

    private func flushPayloads(in context: SessionConnectionContext) {
        guard !context.isSendingPayload,
              !context.pendingPayloads.isEmpty,
              let channel = context.channel else {
            return
        }
        let payload = context.pendingPayloads.removeFirst()
        context.isSendingPayload = true
        do {
            let packet = try channel.seal(payload)
            let data = try SecureSessionWireCodec.encode(packet: packet)
            send(data, on: context.connection) { [weak self, weak context] sent in
                guard let self, let context, self.isCurrent(context) else {
                    return
                }
                context.isSendingPayload = false
                guard sent else {
                    fail(context, message: "Encrypted input send failed")
                    return
                }
                flushPayloads(in: context)
            }
        } catch {
            context.isSendingPayload = false
            fail(
                context,
                message: "Could not encrypt session data: \(error.localizedDescription)"
            )
        }
    }

    private func connectOnQueue(to peerID: UUID) {
        guard !isSystemSleeping,
              networkPathSatisfied else {
            logSecurePhase("connect.waiting-for-network", peerID: peerID)
            publishStatus("Network unavailable; waiting to reconnect")
            return
        }
        guard activeContextID == nil else {
            logSecurePhase("connect.rejected-existing-session", peerID: peerID)
            publishStatus("Disconnect the current secure session first")
            return
        }
        if contexts.values.contains(where: { $0.isClosing }) {
            pendingConnectPeerID = peerID
            logSecurePhase(
                "connect.queued-while-disconnecting",
                peerID: peerID
            )
            publishStatus("Waiting for the secure session to close…")
            return
        }
        guard !contexts.values.contains(where: { $0.localRole == .initiator }) else {
            logSecurePhase("connect.rejected-existing-session", peerID: peerID)
            publishStatus("Disconnect the current secure session first")
            return
        }
        guard let candidates = peersByID[peerID], !candidates.isEmpty else {
            logSecurePhase("connect.waiting-for-discovery", peerID: peerID)
            publishStatus("The paired Mac's secure service is not available; waiting to reconnect")
            scheduleReconnect()
            return
        }
        let candidateIndex = min(
            peerCandidateIndices[peerID] ?? 0,
            candidates.count - 1
        )
        peerCandidateIndices[peerID] = candidateIndex
        let peer = candidates[candidateIndex]
        logSecurePhase(
            "connect.candidate",
            peerID: peerID,
            detail: "index=\(candidateIndex) count=\(candidates.count)"
        )
        guard registry.publicKey(for: peerID) == peer.identity.signingPublicKey else {
            logSecurePhase("connect.rejected-key-mismatch", peerID: peerID)
            publishStatus("The peer key does not match the pinned pairing")
            return
        }

        publishStatus("Connecting securely to \(peer.identity.name)…")

        // Keep the connect path aligned with the peer-to-peer Bonjour browser.
        // Without this, a service discovered over AWDL can be visible in the
        // menu while the subsequent authenticated TCP connection is canceled.
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: peer.endpoint, using: parameters)
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let hello = SecureSessionHandshake.make(
            role: .initiator,
            sender: credentials.identity,
            senderModel: localModel,
            ephemeralKey: ephemeralKey
        )
        let context = SessionConnectionContext(
            connection: connection,
            expectedPeer: peer.identity,
            localRole: .initiator,
            candidateEndpoint: peer.endpoint,
            localEphemeralKey: ephemeralKey,
            initiatorHandshake: hello,
            maximumPacketsPerSecond: Self.maximumInboundPacketsPerSecond,
            maximumBytesPerSecond: Self.maximumInboundBytesPerSecond
        )
        context.epoch = connectionEpoch.current()
        context.peerEpoch = peerEpochs.current(for: peerID)
        install(context)
        connection.stateUpdateHandler = { [weak self, weak context] state in
            guard let self, let context, self.isCurrent(context) else { return }
            switch state {
            case .ready:
                self.logSecurePhase("transport.ready", peerID: peerID, context: context)
                scheduleTimeout(
                    for: context,
                    after: 5,
                    message: "Secure handshake timed out"
                )
                do {
                    let data = try SecureSessionWireCodec.encode(
                        handshake: hello,
                        signingWith: credentials.privateKey
                    )
                    self.logSecurePhase("handshake.initiator.send", peerID: peerID, context: context)
                    send(data, on: connection) { [weak self, weak context] sent in
                        guard let self, let context, self.isCurrent(context) else {
                            return
                        }
                        self.logSecurePhase(
                            sent ? "handshake.initiator.send.confirmed" : "handshake.initiator.send.failed",
                            peerID: peerID,
                            context: context
                        )
                    }
                    receive(on: context)
                    publishStatus("Authenticating \(peer.identity.name)…")
                } catch {
                    self.logSecurePhase(
                        "handshake.initiator.encode-failed",
                        peerID: peerID,
                        context: context,
                        detail: error.localizedDescription
                    )
                    fail(context, message: "Could not start secure handshake")
                }
            case .failed(let error):
                self.logSecurePhase(
                    "transport.failed",
                    peerID: peerID,
                    context: context,
                    detail: error.localizedDescription
                )
                fail(
                    context,
                    message: "Secure connection failed: \(error.localizedDescription)"
                )
            case .cancelled:
                self.logSecurePhase("transport.cancelled", peerID: peerID, context: context)
                // A cancelled unauthenticated outbound connection can be a
                // send failure after the endpoint accepted TCP. Advance to
                // the next bounded Bonjour candidate so one broken endpoint
                // cannot pin reconnects forever. Intentional cancellations
                // remove the context synchronously first, making this branch
                // unreachable for disconnect/revoke/collision teardown.
                remove(
                    context,
                    advanceCandidate: context.localRole == .initiator
                        && !context.isAuthenticated
                )
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            networkPathSatisfied = path.status == .satisfied
            guard !isSystemSleeping else { return }
            if networkPathSatisfied {
                retryConnectionIfNeeded()
            } else {
                reconnectWorkItem?.cancel()
                reconnectWorkItem = nil
                publishReconnecting(true)
                publishStatus("Network unavailable; waiting to reconnect")
            }
        }
        pathMonitor = monitor
        monitor.start(queue: queue)
    }

    /// Starts only the secure discovery components that are missing. Bonjour
    /// listener and browser failures are independent, so one surviving
    /// component must not prevent recovery of the other.
    private func startMissingNetworkServices() {
        if listener == nil {
            startListener()
        }
        if browser == nil {
            startBrowser()
        }
    }

    private func scheduleNetworkRecovery() {
        guard !isSystemSleeping,
              networkRecoveryWorkItem == nil else { return }
        let delay = min(pow(2.0, Double(networkRecoveryAttempt)), 30.0)
        networkRecoveryAttempt = min(networkRecoveryAttempt + 1, 5)
        networkRecoveryGeneration &+= 1
        let recoveryGeneration = networkRecoveryGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.networkRecoveryGeneration == recoveryGeneration,
                  self.networkRecoveryWorkItem != nil else {
                return
            }
            self.networkRecoveryWorkItem = nil
            self.startMissingNetworkServices()
        }
        networkRecoveryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    @discardableResult
    private func noteNetworkServiceReady() -> Bool {
        guard listener != nil, browser != nil else { return false }
        let recoveredAfterFailure = networkRecoveryAttempt > 0
            || networkRecoveryWorkItem != nil
        networkRecoveryAttempt = 0
        networkRecoveryGeneration &+= 1
        networkRecoveryWorkItem?.cancel()
        networkRecoveryWorkItem = nil
        return recoveredAfterFailure
    }

    private func retryConnectionIfNeeded() {
        guard !isSystemSleeping,
              desiredPeerID != nil,
              networkPathSatisfied,
              activeContextID == nil,
              !contexts.values.contains(where: { $0.localRole == .initiator }) else {
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !isSystemSleeping,
              let peerID = desiredPeerID,
              networkPathSatisfied,
              activeContextID == nil,
              !contexts.values.contains(where: { $0.localRole == .initiator }),
              reconnectWorkItem == nil else {
            return
        }
        let delay = reconnectBackoff.delay(forAttempt: reconnectAttempt)
        reconnectAttempt += 1
        publishReconnecting(true)
        publishStatus(
            delay == 0
                ? "Reconnecting to the paired Mac…"
                : "Secure session lost; retrying in \(Int(ceil(delay)))s…"
        )
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  desiredPeerID == peerID,
                  networkPathSatisfied else {
                return
            }
            reconnectWorkItem = nil
            connectOnQueue(to: peerID)
        }
        reconnectWorkItem = workItem
        queue.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func cancelReconnect(resetAttempt: Bool) {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        if resetAttempt {
            reconnectAttempt = 0
        }
        publishReconnecting(false)
    }

    private func startPowerLifecycleObserver(
        notificationCenter: NotificationCenter
    ) {
        guard powerLifecycleObserver == nil else { return }
        powerLifecycleObserver = SystemPowerLifecycleObserver(
            notificationCenter: notificationCenter,
            onWillSleep: { [weak self] in
                self?.prepareForSleep()
            },
            onDidWake: { [weak self] in
                self?.resumeAfterWake()
            }
        )
    }

    private func publishReconnecting(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isReconnecting = value
        }
    }

    private func startListener() {
        guard networkServicesEnabled else { return }
        do {
            // Keep the secure listener aligned with the peer-to-peer Bonjour
            // browser and outbound connector so AWDL endpoints can accept
            // authenticated sessions on either Mac.
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                name: "\(credentials.identity.serviceName)-secure",
                type: Self.serviceType,
                txtRecord: NWTXTRecord([
                    "id": credentials.identity.id.uuidString,
                    "name": credentials.identity.name,
                    "model": localModel,
                    "key": credentials.identity.signingPublicKey.base64EncodedString()
                ])
            )
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    self?.noteNetworkServiceReady()
                case .failed(let error):
                    guard let self else { return }
                    self.publishStatus(
                        "Secure listener failed: \(error.localizedDescription)"
                    )
                    if self.listener === listener {
                        listener?.cancel()
                        self.listener = nil
                        self.scheduleNetworkRecovery()
                    }
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            publishStatus("Could not start secure listener: \(error.localizedDescription)")
            scheduleNetworkRecovery()
        }
    }

    private func startBrowser() {
        guard networkServicesEnabled else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, self.browser === browser else { return }
            let candidates = results.lazy.compactMap {
                (result) -> (PeerAdvertisement, SecureServicePeer)? in
                guard case let .bonjour(txtRecord) = result.metadata,
                      let advertisement = PeerIdentityTXTCodec.decodeAdvertisement(
                          txtRecord
                      ),
                      advertisement.identity.id != self.credentials.identity.id else {
                    return nil
                }
                return (
                    advertisement,
                    SecureServicePeer(
                        identity: advertisement.identity,
                        endpoint: result.endpoint
                    )
                )
            }
            let previousPeersByID = self.peersByID
            let resolvedPeersByID = PeerIdentityAdmission.resolvePinned(
                candidates,
                pinnedKeys: registry.pairedPeers,
                maximumCandidatesPerID: Self.maximumPeerCandidatesPerID,
                preferred: { candidate in
                    guard let preferredEndpoint =
                        self.preferredPeerEndpoints[candidate.0.identity.id]
                    else {
                        return false
                    }
                    return candidate.1.endpoint == preferredEndpoint
                },
                identity: { $0.0.identity }
            ).mapValues { $0.map(\.1) }
            self.peersByID = resolvedPeersByID
            // `resolvePinned` promotes an authenticated preferred endpoint to
            // index zero. Reset the cursor only when that promotion changes
            // the ordered list; preserving a non-zero cursor for an unchanged
            // list would bypass the endpoint that just authenticated.
            for (peerID, candidates) in resolvedPeersByID {
                guard let preferredEndpoint =
                    self.preferredPeerEndpoints[peerID],
                    candidates.first?.endpoint == preferredEndpoint else {
                    continue
                }
                if previousPeersByID[peerID]?.first?.endpoint
                        != preferredEndpoint {
                    self.peerCandidateIndices[peerID] = 0
                }
            }
            peerCandidateIndices = peerCandidateIndices.filter {
                self.peersByID[$0.key] != nil
            }
            retryConnectionIfNeeded()
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            switch state {
            case .ready:
                if let self, self.noteNetworkServiceReady() {
                    self.publishStatus("Secure discovery recovered")
                }
            case .failed(let error):
                guard let self else { return }
                self.publishStatus(
                    "Secure discovery failed: \(error.localizedDescription)"
                )
                if self.browser === browser {
                    self.browser = nil
                    self.scheduleNetworkRecovery()
                }
            default:
                break
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func refreshBrowserOnQueue() {
        browser?.cancel()
        browser = nil
        startBrowser()
    }

    private func accept(_ connection: NWConnection) {
        guard activeContextID == nil,
              !contexts.values.contains(where: { $0.isClosing }),
              contexts.count < Self.maximumPendingConnections,
              admissionLimiter.allows(
                  eventAt: DispatchTime.now().uptimeNanoseconds
              ) else {
            MacKVMLogger.secureSession.info(
                "phase=incoming.rejected detail=admission-limit"
            )
            connection.cancel()
            return
        }
        let context = SessionConnectionContext(
            connection: connection,
            expectedPeer: nil,
            localRole: .responder,
            maximumPacketsPerSecond: Self.maximumInboundPacketsPerSecond,
            maximumBytesPerSecond: Self.maximumInboundBytesPerSecond
        )
        context.epoch = connectionEpoch.current()
        install(context)
        connection.stateUpdateHandler = { [weak self, weak context] state in
            guard let self, let context, self.isCurrent(context) else { return }
            switch state {
            case .ready:
                self.logSecurePhase("transport.ready", context: context)
                scheduleTimeout(
                    for: context,
                    after: 5,
                    message: "Secure handshake timed out"
                )
                receive(on: context)
            case .failed(let error):
                self.logSecurePhase(
                    "transport.failed",
                    context: context,
                    detail: error.localizedDescription
                )
                fail(
                    context,
                    message: "Incoming secure connection failed: \(error.localizedDescription)"
                )
            case .cancelled:
                self.logSecurePhase("transport.cancelled", context: context)
                remove(context)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on context: SessionConnectionContext) {
        context.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self, weak context] data, _, complete, error in
            guard let self, let context, self.isCurrent(context) else { return }
            if let data, !data.isEmpty {
                context.buffer.append(data)
            }
            drainBufferedFrames(
                on: context,
                connectionEnded: complete || error != nil
            )
        }
    }

    private func drainBufferedFrames(
        on context: SessionConnectionContext,
        connectionEnded: Bool
    ) {
        guard isCurrent(context) else { return }
        do {
            let messages = try SecureSessionWireCodec.decodeAvailableFrames(
                from: &context.buffer
            )
            // Decode complete frames first. TCP can coalesce the tail of one
            // frame with complete subsequent frames; only bytes retained for
            // the next incomplete frame count against the memory budget. A
            // capped decode batch may leave complete frames in the buffer,
            // so do not count those already-valid frames against the cap.
            let hasCompleteFrame = SecureSessionWireCodec.hasCompleteFrame(
                in: context.buffer
            )
            guard BufferedFrameDrainPolicy.acceptsBufferedBytes(
                bufferCount: context.buffer.count,
                maximumBufferLength: Self.maximumWireBufferLength,
                hasCompleteFrame: hasCompleteFrame
            ) else {
                throw SecureSessionError.invalidFrame
            }
            try messages.forEach {
                try handle($0, in: context)
            }

            if !messages.isEmpty, context.partialFrameTimeout != nil {
                // The previous partial frame completed. A remaining partial
                // frame is a new lifetime and needs its own deadline.
                context.partialFrameTimeout?.cancel()
                context.partialFrameTimeout = nil
                context.partialFrameDeadline = nil
            }

            if context.buffer.isEmpty {
                context.partialFrameTimeout?.cancel()
                context.partialFrameTimeout = nil
                context.partialFrameDeadline = nil
                if connectionEnded {
                    logSecurePhase("transport.eof", context: context)
                    remove(context, advanceCandidate: true)
                } else {
                    receive(on: context)
                }
            } else if BufferedFrameDrainPolicy.shouldContinueDecoding(
                decodedFrameCount: messages.count,
                hasCompleteFrame: hasCompleteFrame
            ) {
                // Secure sessions intentionally do not apply pairing's
                // cumulative 16-message-per-delivery cap. The frame and
                // buffer limits plus inbound packet/byte budgets bound this
                // high-polling input path without dropping valid movement.
                // A capped decode batch left more complete frames buffered.
                // Drain the next batch on the serial queue without waiting
                // for another network read (TCP coalescing is valid).
                queue.async { [weak self, weak context] in
                    guard let self, let context, self.isCurrent(context) else {
                        return
                    }
                    self.drainBufferedFrames(
                        on: context,
                        connectionEnded: connectionEnded
                    )
                }
            } else {
                schedulePartialFrameTimeout(for: context)
                if connectionEnded {
                    logSecurePhase(
                        "transport.eof-with-partial-frame",
                        context: context,
                        detail: "buffer=\(context.buffer.count)"
                    )
                    remove(context, advanceCandidate: true)
                } else {
                    receive(on: context)
                }
            }
        } catch {
            logSecurePhase(
                "receive.rejected",
                context: context,
                detail: error.localizedDescription
            )
            let message: String
            if let secureError = error as? SecureSessionError,
               secureError == .peerRequiresUpgrade {
                message =
                    "Update MacKVM on both Macs before connecting securely"
            } else {
                message = "Rejected invalid secure session data"
            }
            fail(context, message: message)
        }
    }

    private func handle(
        _ message: SecureSessionWireMessage,
        in context: SessionConnectionContext
    ) throws {
        guard isCurrent(context) else {
            throw SecureSessionError.invalidFrame
        }
        switch message {
        case .handshake(let handshake):
            logSecurePhase(
                "handshake.received",
                peerID: handshake.sender.id,
                context: context
            )
            try handle(handshake, in: context)
        case .packet(let packet):
            guard let channel = context.channel else {
                throw SecureSessionError.invalidHandshake
            }
            let payload = try channel.open(packet)
            if SecureSessionControlSignal.isDisconnect(payload) {
                handleDisconnectSignal(in: context)
                return
            }
            if SecureSessionControlSignal.isDisconnectAcknowledgement(payload) {
                guard context.isClosing else {
                    logSecurePhase(
                        "disconnect.acknowledgement.rejected",
                        context: context,
                        detail: "unexpected"
                    )
                    throw SecureSessionError.invalidFrame
                }
                logSecurePhase(
                    "disconnect.acknowledgement.received",
                    context: context
                )
                context.disconnectTimeout?.cancel()
                context.disconnectTimeout = nil
                context.connection.cancel()
                remove(context)
                return
            }
            // A close marker can be coalesced with ordinary input in the same
            // TCP read. Do not deliver data that followed a user disconnect.
            guard !context.isClosing else { return }
            if !context.isAuthenticated {
                guard context.localRole == .responder,
                      payload == Self.keyConfirmation,
                      activeContextID == nil,
                      let peer = context.expectedPeer,
                      registry.publicKey(for: peer.id)
                        == peer.signingPublicKey else {
                    logSecurePhase(
                        "key-confirmation.rejected",
                        context: context,
                        detail: "invalid-or-unexpected"
                    )
                    throw SecureSessionError.invalidHandshake
                }
                context.isAuthenticated = true
                context.handshakeTimeout?.cancel()
                activeContextID = ObjectIdentifier(context)
                reconnectAttempt = 0
                cancelReconnect(resetAttempt: false)
                context.admissionGeneration = onAuthenticated?()
                updateConnectionProfile(
                    for: peer.id,
                    model: context.peerModel,
                    friendlyName: peer.name
                )
                publishConnection(
                    peerID: peer.id,
                    status: "Encrypted session connected to \(peer.name)",
                    admissionGeneration: context.admissionGeneration
                )
                logSecurePhase(
                    "session.authenticated",
                    peerID: peer.id,
                    context: context
                )
                return
            }
            guard context.inboundPayloadBudget.allows(
                bytes: payload.count,
                at: DispatchTime.now().uptimeNanoseconds
            ) else {
                throw SecureSessionError.invalidFrame
            }
            onPayload?(payload)
        }
    }

    private func handleDisconnectSignal(
        in context: SessionConnectionContext
    ) {
        logSecurePhase(
            "disconnect.received",
            context: context
        )
        context.suppressesReconnect = true
        context.pendingPayloads.removeAll()
        context.isSendingPayload = false
        let peerID = context.expectedPeer?.id
        // Preserve an explicit Connect that was queued while the close was in
        // flight. A remote disconnect must cancel automatic reconnect intent,
        // but it must not erase the user's newer Connect request.
        if desiredPeerID == peerID, pendingConnectPeerID != peerID {
            desiredPeerID = nil
            cancelReconnect(resetAttempt: true)
        }
        let wasActive = activeContextID == ObjectIdentifier(context)
        if wasActive {
            // The local publication must clear immediately so input returns
            // to this Mac, but `remove(_:)` still needs to know that this
            // context was the active session when deciding whether another
            // selected peer should be retried after the close completes.
            context.wasActiveBeforeDisconnect = true
            activeContextID = nil
            publishConnection(
                peerID: nil,
                status: "Peer disconnected the secure session",
                admissionGeneration: context.admissionGeneration
            )
        }
        sendDisconnectAcknowledgement(for: context)
        publishStatus("Peer disconnected the secure session")
    }

    private func handle(
        _ handshake: SecureSessionHandshake,
        in context: SessionConnectionContext
    ) throws {
        guard context.channel == nil else {
            throw SecureSessionError.invalidHandshake
        }
        switch context.localRole {
        case .initiator:
            guard handshake.role == .responder,
                  let expectedPeer = context.expectedPeer,
                  PeerArbitration.isValidPeerPair(
                      localID: credentials.identity.id,
                      remoteID: expectedPeer.id
                  ),
                  handshake.sender == expectedPeer,
                  registry.publicKey(for: expectedPeer.id)
                    == handshake.sender.signingPublicKey,
                  let ephemeralKey = context.localEphemeralKey,
                  let initiatorHandshake = context.initiatorHandshake,
                  handshake.sessionID == initiatorHandshake.sessionID else {
                logSecurePhase(
                    "handshake.initiator.rejected",
                    context: context,
                    detail: "identity-or-session-mismatch"
                )
                throw SecureSessionError.invalidHandshake
            }
            // Require the current close contract only after the responder's
            // identity and pinned signing key have been authenticated. An
            // untrusted endpoint must not be able to clear reconnect intent
            // for the real paired peer, and a trusted older release must not
            // be silently downgraded to EOF teardown.
            guard SecureSessionCompatibilityPolicy.decision(
                for: handshake.disconnectSignalVersion
            ) == .compatible else {
                context.suppressesReconnect = true
                logSecurePhase(
                    "handshake.rejected-peer-upgrade-required",
                    peerID: expectedPeer.id,
                    context: context
                )
                throw SecureSessionError.peerRequiresUpgrade
            }
            context.responderHandshake = handshake
            context.peerModel = PeerMetadataValidation.validatedModel(
                handshake.senderModel
            )
            context.channel = try SecureSessionChannel(
                localRole: .initiator,
                localEphemeralKey: ephemeralKey,
                initiator: initiatorHandshake,
                responder: handshake
            )
            let confirmation = try context.channel?.seal(Self.keyConfirmation)
            guard let confirmation else {
                throw SecureSessionError.invalidHandshake
            }
            let confirmationData = try SecureSessionWireCodec.encode(
                packet: confirmation
            )
            logSecurePhase(
                "key-confirmation.send.begin",
                peerID: expectedPeer.id,
                context: context
            )
            send(confirmationData, on: context.connection) {
                [weak self, weak context] sent in
                guard let self, let context, self.isCurrent(context) else {
                    return
                }
                guard !context.isClosing else {
                    // A responder can request teardown before Network.framework
                    // reports that this final handshake packet was processed.
                    // The disconnect acknowledgement path owns cleanup; do
                    // not promote a context that is already closing.
                    self.logSecurePhase(
                        "key-confirmation.send.ignored-closing",
                        peerID: expectedPeer.id,
                        context: context
                    )
                    return
                }
                guard sent,
                      self.activeContextID == nil,
                      self.registry.publicKey(for: expectedPeer.id)
                        == expectedPeer.signingPublicKey else {
                    self.logSecurePhase(
                        "key-confirmation.send.failed",
                        peerID: expectedPeer.id,
                        context: context
                    )
                    self.fail(
                        context,
                        message: "Could not confirm the secure session key"
                    )
                    return
                }
                context.isAuthenticated = true
                context.handshakeTimeout?.cancel()
                if let endpoint = context.candidateEndpoint {
                    self.preferredPeerEndpoints[expectedPeer.id] = endpoint
                }
                self.activeContextID = ObjectIdentifier(context)
                self.reconnectAttempt = 0
                self.cancelReconnect(resetAttempt: false)
                context.admissionGeneration = self.onAuthenticated?()
                self.updateConnectionProfile(
                    for: expectedPeer.id,
                    model: context.peerModel,
                    friendlyName: expectedPeer.name
                )
                self.publishConnection(
                    peerID: expectedPeer.id,
                    status: "Encrypted session connected to \(expectedPeer.name)",
                    admissionGeneration: context.admissionGeneration
                )
                self.logSecurePhase(
                    "key-confirmation.send.confirmed",
                    peerID: expectedPeer.id,
                    context: context
                )
            }

        case .responder:
            guard handshake.role == .initiator,
                  PeerArbitration.isValidPeerPair(
                      localID: credentials.identity.id,
                      remoteID: handshake.sender.id
                  ),
                  registry.publicKey(for: handshake.sender.id)
                    == handshake.sender.signingPublicKey else {
                logSecurePhase(
                    "handshake.responder.rejected",
                    peerID: handshake.sender.id,
                    context: context,
                    detail: "identity-or-role-mismatch"
                )
                throw SecureSessionError.invalidHandshake
            }
            // Require the current close contract only after the initiator's
            // identity and pinned signing key have been authenticated. An
            // untrusted endpoint must not be able to clear reconnect intent
            // for the real paired peer, and a trusted older release must not
            // be silently downgraded to EOF teardown.
            guard SecureSessionCompatibilityPolicy.decision(
                for: handshake.disconnectSignalVersion
            ) == .compatible else {
                context.suppressesReconnect = true
                logSecurePhase(
                    "handshake.rejected-peer-upgrade-required",
                    peerID: handshake.sender.id,
                    context: context
                )
                throw SecureSessionError.peerRequiresUpgrade
            }
            // Bind the responder context before collision arbitration. The
            // removal of a losing outbound attempt can then see the winning
            // incoming peer and defer reconnect until this handshake settles.
            context.expectedPeer = handshake.sender
            context.peerEpoch = peerEpochs.current(for: handshake.sender.id)
            if contexts.values.contains(where: {
                $0 !== context
                    && $0.isClosing
                    && $0.expectedPeer?.id == handshake.sender.id
            }) {
                // Keep a peer from racing a user disconnect with a duplicate
                // incoming handshake. An explicit local Connect remains
                // queued and is started after the closing context is removed.
                context.suppressesReconnect = true
                logSecurePhase(
                    "handshake.responder.rejected-close-in-flight",
                    peerID: handshake.sender.id,
                    context: context
                )
                throw SecureSessionError.invalidHandshake
            }
            // Keep this gate for both legacy and current-capability peers. If
            // the encrypted marker is lost during a transport failure, the
            // peer may still retain automatic reconnect intent; only an
            // explicit local Connect is allowed to clear this block.
            guard !locallyDisconnectedPeerIDs.contains(handshake.sender.id) else {
                context.suppressesReconnect = true
                logSecurePhase(
                    "handshake.responder.rejected-local-disconnect",
                    peerID: handshake.sender.id,
                    context: context
                )
                throw SecureSessionError.invalidHandshake
            }
            try arbitrateSimultaneousConnection(
                incoming: context,
                peer: handshake.sender
            )
            let ephemeralKey = P256.KeyAgreement.PrivateKey()
            let response = SecureSessionHandshake.make(
                sessionID: handshake.sessionID,
                role: .responder,
                sender: credentials.identity,
                senderModel: localModel,
                ephemeralKey: ephemeralKey
            )
            context.peerModel = PeerMetadataValidation.validatedModel(
                handshake.senderModel
            )
            context.localEphemeralKey = ephemeralKey
            context.initiatorHandshake = handshake
            context.responderHandshake = response
            context.channel = try SecureSessionChannel(
                localRole: .responder,
                localEphemeralKey: ephemeralKey,
                initiator: handshake,
                responder: response
            )
            let data = try SecureSessionWireCodec.encode(
                handshake: response,
                signingWith: credentials.privateKey
            )
            logSecurePhase(
                "handshake.responder.send.begin",
                peerID: handshake.sender.id,
                context: context
            )
            send(data, on: context.connection) { [weak self, weak context] sent in
                guard let self, let context, self.isCurrent(context) else {
                    return
                }
                guard sent else {
                    self.logSecurePhase(
                        "handshake.responder.send.failed",
                        peerID: handshake.sender.id,
                        context: context
                    )
                    fail(context, message: "Could not complete secure handshake")
                    return
                }
                self.logSecurePhase(
                    "handshake.responder.send.confirmed",
                    peerID: handshake.sender.id,
                    context: context
                )
                publishStatus(
                    "Waiting for encrypted key confirmation from \(handshake.sender.name)…"
                )
            }
        }
    }

    private func install(_ context: SessionConnectionContext) {
        let contextID = ObjectIdentifier(context)
        contexts[contextID] = context
        scheduleTimeout(
            for: context,
            after: 15,
            message: "Secure connection timed out"
        )
    }

    private func isCurrent(_ context: SessionConnectionContext) -> Bool {
        let contextID = ObjectIdentifier(context)
        guard contexts[contextID] === context,
              context.epoch == connectionEpoch.current() else {
            return false
        }
        if let peerID = context.expectedPeer?.id {
            return context.peerEpoch == peerEpochs.current(for: peerID)
        }
        return true
    }

    private func schedulePartialFrameTimeout(
        for context: SessionConnectionContext
    ) {
        guard context.partialFrameTimeout == nil else { return }
        let deadline = PartialFrameTimeoutPolicy.deadline(
            now: DispatchTime.now().uptimeNanoseconds,
            timeoutNanoseconds: Self.partialFrameTimeoutNanoseconds
        )
        context.partialFrameDeadline = deadline
        let timeout = DispatchWorkItem { [weak self, weak context] in
            guard let self, let context,
                  self.isCurrent(context),
                  PartialFrameTimeoutPolicy.shouldExpire(
                      deadline: context.partialFrameDeadline,
                      hasPartialFrame: !context.buffer.isEmpty,
                      now: DispatchTime.now().uptimeNanoseconds
                  ) else { return }
            self.logSecurePhase(
                "receive.partial-frame-timeout",
                context: context
            )
            self.fail(
                context,
                message: "Secure session closed an incomplete frame that took too long"
            )
        }
        context.partialFrameTimeout = timeout
        queue.asyncAfter(
            deadline: .now() + Self.partialFrameTimeout,
            execute: timeout
        )
    }

    private func scheduleTimeout(
        for context: SessionConnectionContext,
        after seconds: TimeInterval,
        message: String
    ) {
        context.handshakeTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak context] in
            guard let self, let context, self.isCurrent(context),
                  !context.isAuthenticated else { return }
            self.logSecurePhase("handshake.timeout", context: context)
            fail(context, message: message)
        }
        context.handshakeTimeout = timeout
        queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    private func arbitrateSimultaneousConnection(
        incoming: SessionConnectionContext,
        peer: PeerIdentity
    ) throws {
        guard let outbound = contexts.values.first(where: {
            $0 !== incoming
                && $0.localRole == .initiator
                && $0.expectedPeer?.id == peer.id
        }) else {
            return
        }
        let preferredRole = SecureSessionCollisionPolicy.preferredRole(
            localID: credentials.identity.id,
            remoteID: peer.id
        )
        logSecurePhase(
            "connection.collision",
            peerID: peer.id,
            context: incoming,
            detail: "preferredRole=\(preferredRole == .initiator ? "initiator" : "responder")"
        )
        if preferredRole == .initiator {
            logSecurePhase(
                "connection.collision.rejected-incoming",
                peerID: peer.id,
                context: incoming
            )
            throw SecureSessionError.invalidHandshake
        }
        // The incoming responder is now the deterministic winner. Mark it
        // before removing the losing outbound context so remove(_:) does not
        // immediately start a second outbound attempt while this handshake is
        // still being authenticated. If the winning incoming context later
        // fails, its removal path will schedule one fresh retry.
        incoming.retriesAfterRemoval = true
        outbound.connection.cancel()
        logSecurePhase(
            "connection.collision.removing-outbound",
            peerID: peer.id,
            context: outbound
        )
        remove(outbound)
    }

    private func remove(
        _ context: SessionConnectionContext,
        advanceCandidate: Bool = false
    ) {
        let contextID = ObjectIdentifier(context)
        guard contexts[contextID] === context else { return }
        let removedActiveContext = activeContextID == contextID
            || context.wasActiveBeforeDisconnect
        let peerID = context.expectedPeer?.id
        logSecurePhase(
            "context.removing",
            peerID: peerID,
            context: context,
            detail: "active=\(removedActiveContext) advanceCandidate=\(advanceCandidate)"
        )
        let preferredIncomingPending = contexts.values.contains {
            $0 !== context
                && $0.localRole == .responder
                && $0.retriesAfterRemoval
                && $0.expectedPeer?.id == peerID
        }
        if advanceCandidate,
           context.localRole == .initiator,
           !context.isAuthenticated,
           let peerID = context.expectedPeer?.id {
            // A failed handshake may end with a clean EOF instead of an
            // NWConnection failure callback. Advance at the single removal
            // boundary so a spoofed endpoint cannot pin reconnects to the
            // first candidate forever. `fail` also funnels through here.
            advancePeerCandidate(for: peerID)
        }
        context.handshakeTimeout?.cancel()
        context.partialFrameTimeout?.cancel()
        context.disconnectTimeout?.cancel()
        context.disconnectTimeout = nil
        context.partialFrameDeadline = nil
        contexts.removeValue(forKey: contextID)
        if activeContextID == contextID {
            let admissionGeneration = context.admissionGeneration
            activeContextID = nil
            publishConnection(
                peerID: nil,
                status: "Secure session disconnected",
                admissionGeneration: admissionGeneration
            )
        }
        let startedPendingConnect = startPendingConnectIfReady()
        let shouldRetry = SecureSessionDisconnectPolicy.shouldRetryAfterRemoval(
            removedActiveContext: removedActiveContext,
            localRole: context.localRole,
            retriesAfterRemoval: context.retriesAfterRemoval,
            desiredPeerMatches: desiredPeerID == peerID,
            hasDesiredPeer: desiredPeerID != nil,
            suppressesReconnect: context.suppressesReconnect
        )
        if !startedPendingConnect && shouldRetry && !preferredIncomingPending {
            retryConnectionIfNeeded()
        }
        logSecurePhase(
            "context.removed",
            peerID: peerID,
            context: context,
            detail: "active=\(removedActiveContext) retry=\(shouldRetry && !preferredIncomingPending && !startedPendingConnect)"
        )
    }

    private func startPendingConnectIfReady() -> Bool {
        guard let peerID = pendingConnectPeerID,
              desiredPeerID == peerID,
              activeContextID == nil,
              contexts.isEmpty else {
            return false
        }
        pendingConnectPeerID = nil
        locallyDisconnectedPeerIDs.remove(peerID)
        locallyDisconnectedPeerGenerations.removeValue(forKey: peerID)
        if peersByID[peerID]?.isEmpty != false {
            refreshBrowserOnQueue()
        }
        connectOnQueue(to: peerID)
        return true
    }

    /// Sends an authenticated close marker before canceling the local socket.
    /// A plain TCP cancellation is indistinguishable from a network failure at
    /// the peer, so the peer would otherwise retain its reconnect intent and
    /// immediately recreate a session after a user pressed Disconnect.
    private func sendDisconnectSignal(for context: SessionConnectionContext) {
        guard !context.isClosing,
              let channel = context.channel else {
            context.connection.cancel()
            remove(context)
            return
        }
        context.isClosing = true
        context.pendingPayloads.removeAll()
        context.isSendingPayload = false
        do {
            let packet = try channel.seal(SecureSessionControlSignal.disconnect)
            let data = try SecureSessionWireCodec.encode(packet: packet)
            let timeout = DispatchWorkItem { [weak self, weak context] in
                guard let self,
                      let context,
                      self.contexts[ObjectIdentifier(context)] === context else {
                    return
                }
                context.disconnectTimeout = nil
                self.logSecurePhase(
                    "disconnect.flush-timeout",
                    context: context
                )
                context.connection.cancel()
                self.remove(context)
            }
            context.disconnectTimeout = timeout
            queue.asyncAfter(
                deadline: .now() + Self.disconnectTransportFlushTimeout,
                execute: timeout
            )
            send(data, on: context.connection) { [weak self, weak context] sent in
                guard let self,
                      let context,
                      self.contexts[ObjectIdentifier(context)] === context else {
                    return
                }
                guard sent else {
                    context.disconnectTimeout?.cancel()
                    context.disconnectTimeout = nil
                    context.connection.cancel()
                    self.remove(context)
                    return
                }
                // `contentProcessed` only confirms local Network.framework
                // processing. Keep the authenticated context until the peer
                // sends its encrypted acknowledgement, or the bounded timer
                // above expires.
                self.logSecurePhase(
                    "disconnect.sent-awaiting-ack",
                    context: context
                )
            }
        } catch {
            logSecurePhase(
                "disconnect.encode-failed",
                context: context,
                detail: error.localizedDescription
            )
            context.connection.cancel()
            remove(context)
        }
    }

    /// A disconnect acknowledgement is itself encrypted by the established
    /// channel. Keep the receiver alive briefly after the local send has been
    /// accepted so the sender can consume the acknowledgement before either
    /// side observes a normal transport EOF.
    private func sendDisconnectAcknowledgement(
        for context: SessionConnectionContext
    ) {
        guard isCurrent(context),
              !context.disconnectAcknowledgementSendStarted,
              let channel = context.channel else {
            return
        }
        context.disconnectAcknowledgementSendStarted = true
        context.isClosing = true
        do {
            let packet = try channel.seal(
                SecureSessionControlSignal.disconnectAcknowledgement
            )
            let data = try SecureSessionWireCodec.encode(packet: packet)
            context.disconnectTimeout?.cancel()
            let timeout = DispatchWorkItem { [weak self, weak context] in
                guard let self,
                      let context,
                      self.contexts[ObjectIdentifier(context)] === context else {
                    return
                }
                context.disconnectTimeout = nil
                self.logSecurePhase(
                    "disconnect.acknowledgement-timeout",
                    context: context
                )
                context.connection.cancel()
                self.remove(context)
            }
            context.disconnectTimeout = timeout
            queue.asyncAfter(
                deadline: .now() + Self.disconnectTransportFlushTimeout,
                execute: timeout
            )
            send(data, on: context.connection) { [weak self, weak context] sent in
                guard let self,
                      let context,
                      self.contexts[ObjectIdentifier(context)] === context else {
                    return
                }
                guard sent else {
                    context.disconnectTimeout?.cancel()
                    context.disconnectTimeout = nil
                    context.connection.cancel()
                    self.remove(context)
                    return
                }
                context.disconnectTimeout?.cancel()
                let grace = DispatchWorkItem { [weak self, weak context] in
                    guard let self,
                          let context,
                          self.contexts[ObjectIdentifier(context)] === context else {
                        return
                    }
                    context.disconnectTimeout = nil
                    self.logSecurePhase(
                        "disconnect.acknowledgement.grace-timeout",
                        context: context
                    )
                    context.connection.cancel()
                    self.remove(context)
                }
                context.disconnectTimeout = grace
                self.queue.asyncAfter(
                    deadline: .now() + Self.disconnectTransportFlushTimeout,
                    execute: grace
                )
            }
        } catch {
            logSecurePhase(
                "disconnect.acknowledgement.encode-failed",
                context: context,
                detail: error.localizedDescription
            )
            context.connection.cancel()
            remove(context)
        }
    }

    private func fail(
        _ context: SessionConnectionContext,
        message: String
    ) {
        logSecurePhase("session.failed", context: context, detail: message)
        publishStatus(message)
        context.connection.cancel()
        remove(context, advanceCandidate: true)
    }

    private func advancePeerCandidate(for peerID: UUID) {
        guard let candidates = peersByID[peerID], candidates.count > 1 else {
            return
        }
        let currentIndex = peerCandidateIndices[peerID] ?? 0
        peerCandidateIndices[peerID] =
            (currentIndex + 1) % candidates.count
    }

    private func send(
        _ data: Data,
        on connection: NWConnection,
        completion: ((Bool) -> Void)? = nil
    ) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                MacKVMLogger.secureSession.error(
                    "phase=wire.send.failed error=\(error.localizedDescription, privacy: .public)"
                )
                self?.publishStatus("Secure send failed: \(error.localizedDescription)")
                connection.cancel()
            }
            completion?(error == nil)
        })
    }

    /// Logs secure-session state transitions without recording endpoints,
    /// session identifiers, public/private keys, or encrypted payloads.
    /// Keeping the context identifier short makes two-device captures easy
    /// to correlate while avoiding a stable identifier outside this process.
    private func logSecurePhase(
        _ phase: String,
        peerID: UUID? = nil,
        context: SessionConnectionContext? = nil,
        detail: String? = nil
    ) {
        let resolvedPeerID = peerID ?? context?.expectedPeer?.id
        let contextID = context.map {
            String(describing: ObjectIdentifier($0))
        } ?? "none"
        var fields = [
            "phase=\(phase)",
            "peer=\(MacKVMLogger.short(resolvedPeerID))",
            "context=\(contextID)"
        ]
        if let context {
            fields.append("role=\(context.localRole == .initiator ? "initiator" : "responder")")
            fields.append("authenticated=\(context.isAuthenticated)")
        }
        if let detail {
            fields.append("detail=\(detail)")
        }
        MacKVMLogger.secureSession.info(
            "\(fields.joined(separator: " "), privacy: .public)"
        )
    }

    /// Publish connection metadata to the shared in-memory registry before the
    /// connection event reaches SwiftUI. `persistImmediately: false` keeps
    /// only the UserDefaults write asynchronous; the cache update is ordered
    /// before `publishConnection`, so the paired-device panel and copied
    /// support information observe the new model/timestamp immediately.
    private func updateConnectionProfile(
        for peerID: UUID,
        model: String?,
        friendlyName: String?
    ) {
        _ = registry.recordConnection(
            for: peerID,
            model: model,
            friendlyName: friendlyName,
            persistImmediately: false
        )
    }

    private func publishStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.status = message
        }
    }

    private func publishConnection(
        peerID: UUID?,
        status: String,
        admissionGeneration: UInt64? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.connectedPeerID = peerID
            self?.status = status
            self?.connectionPublicationSubject.send(
                ControlConnectionPublication(
                    peerID: peerID,
                    admissionGeneration: admissionGeneration
                )
            )
        }
    }
}

private struct SecureServicePeer {
    let identity: PeerIdentity
    let endpoint: NWEndpoint
}

private final class SessionConnectionContext {
    let connection: NWConnection
    var expectedPeer: PeerIdentity?
    let localRole: SecureSessionRole
    let candidateEndpoint: NWEndpoint?
    var peerModel: String?
    var localEphemeralKey: P256.KeyAgreement.PrivateKey?
    var initiatorHandshake: SecureSessionHandshake?
    var responderHandshake: SecureSessionHandshake?
    var channel: SecureSessionChannel?
    var isAuthenticated = false
    /// Set when this responder won a simultaneous-connect arbitration. It
    /// suppresses a retry while the losing initiator is being removed, then
    /// permits a retry if the preferred incoming handshake itself fails.
    var retriesAfterRemoval = false
    var isSendingPayload = false
    var pendingPayloads: [Data] = []
    var isClosing = false
    var disconnectAcknowledgementSendStarted = false
    var suppressesReconnect = false
    var wasActiveBeforeDisconnect = false
    var buffer = Data()
    var handshakeTimeout: DispatchWorkItem?
    var partialFrameTimeout: DispatchWorkItem?
    var disconnectTimeout: DispatchWorkItem?
    var partialFrameDeadline: UInt64?
    var admissionGeneration: UInt64?
    var epoch: UInt64 = 0
    var peerEpoch: UInt64 = 0
    var inboundPayloadBudget: InboundPayloadBudget

    init(
        connection: NWConnection,
        expectedPeer: PeerIdentity?,
        localRole: SecureSessionRole,
        candidateEndpoint: NWEndpoint? = nil,
        peerModel: String? = nil,
        localEphemeralKey: P256.KeyAgreement.PrivateKey? = nil,
        initiatorHandshake: SecureSessionHandshake? = nil,
        maximumPacketsPerSecond: Int,
        maximumBytesPerSecond: Int
    ) {
        self.connection = connection
        self.expectedPeer = expectedPeer
        self.localRole = localRole
        self.candidateEndpoint = candidateEndpoint
        self.peerModel = peerModel
        self.localEphemeralKey = localEphemeralKey
        self.initiatorHandshake = initiatorHandshake
        self.inboundPayloadBudget = InboundPayloadBudget(
            maximumPacketsPerSecond: maximumPacketsPerSecond,
            maximumBytesPerSecond: maximumBytesPerSecond
        )
    }
}
