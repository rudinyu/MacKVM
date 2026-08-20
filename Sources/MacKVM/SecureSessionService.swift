import Combine
import CryptoKit
import Foundation
import MacKVMCore
import Network

enum SecureSessionRevocationPolicy {
    static func removesActiveContext(
        activeContextID: ObjectIdentifier?,
        revokedContextIDs: Set<ObjectIdentifier>
    ) -> Bool {
        guard let activeContextID else { return false }
        return revokedContextIDs.contains(activeContextID)
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
    private var desiredPeerID: UUID?
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private let reconnectBackoff = ReconnectBackoffPolicy()

    init(
        credentials: DeviceCredentials,
        registry: PairingRegistry,
        localModel: String = MacHardwareInfo.currentModel
    ) {
        self.credentials = credentials
        self.registry = registry
        self.localModel = PeerMetadataValidation.validatedModel(localModel)
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            startPathMonitor()
            startMissingNetworkServices()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            connectionEpoch.advance()
            desiredPeerID = nil
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
        queue.async { [weak self] in
            guard let self else { return }
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
                    logSecurePhase(
                        "connect.rejected-existing-session",
                        peerID: peerID,
                        detail: "desired-peer-preserved-pending-handshake"
                    )
                    publishStatus("Disconnect the current secure session first")
                    return
                }
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

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            logSecurePhase("disconnect.requested")
            desiredPeerID = nil
            cancelReconnect(resetAttempt: true)
            connectionEpoch.advance()
            // Disconnect is a session-wide local safety action. Cancel every
            // context, including handshakes that have not selected a peer,
            // so no stale callback can promote an old session afterward.
            let hadActiveContext = activeContextID != nil
            for context in Array(contexts.values) {
                context.connection.cancel()
                remove(context)
            }
            if hadActiveContext {
                // remove(_:) already published the generation-tagged nil
                // connection event; avoid a second untagged disconnect.
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
        guard networkPathSatisfied else {
            logSecurePhase("connect.waiting-for-network", peerID: peerID)
            publishStatus("Network unavailable; waiting to reconnect")
            return
        }
        guard activeContextID == nil,
              !contexts.values.contains(where: { $0.localRole == .initiator }) else {
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
        guard networkRecoveryWorkItem == nil else { return }
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
        guard desiredPeerID != nil,
              networkPathSatisfied,
              activeContextID == nil,
              !contexts.values.contains(where: { $0.localRole == .initiator }) else {
            return
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard let peerID = desiredPeerID,
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

    private func publishReconnecting(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.isReconnecting = value
        }
    }

    private func startListener() {
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
            fail(context, message: "Rejected invalid secure session data")
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
            // Bind the responder context before collision arbitration. The
            // removal of a losing outbound attempt can then see the winning
            // incoming peer and defer reconnect until this handshake settles.
            context.expectedPeer = handshake.sender
            context.peerEpoch = peerEpochs.current(for: handshake.sender.id)
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
        context.partialFrameDeadline = nil
        contexts.removeValue(forKey: contextID)
        if removedActiveContext {
            let admissionGeneration = context.admissionGeneration
            activeContextID = nil
            publishConnection(
                peerID: nil,
                status: "Secure session disconnected",
                admissionGeneration: admissionGeneration
            )
        }
        let shouldRetry = removedActiveContext
            || context.localRole == .initiator
            || (context.retriesAfterRemoval
                && desiredPeerID == peerID)
        if shouldRetry && !preferredIncomingPending {
            retryConnectionIfNeeded()
        }
        logSecurePhase(
            "context.removed",
            peerID: peerID,
            context: context,
            detail: "active=\(removedActiveContext) retry=\(shouldRetry && !preferredIncomingPending)"
        )
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
    var buffer = Data()
    var handshakeTimeout: DispatchWorkItem?
    var partialFrameTimeout: DispatchWorkItem?
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
