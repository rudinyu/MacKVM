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
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peersByID: [UUID: [SecureServicePeer]] = [:]
    private var peerCandidateIndices: [UUID: Int] = [:]
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
        registry: PairingRegistry
    ) {
        self.credentials = credentials
        self.registry = registry
    }

    func start() {
        queue.async { [weak self] in
            guard let self, listener == nil, browser == nil else { return }
            startPathMonitor()
            startListener()
            startBrowser()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            connectionEpoch.advance()
            desiredPeerID = nil
            cancelReconnect(resetAttempt: true)
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
            desiredPeerID = peerID
            cancelReconnect(resetAttempt: true)
            connectOnQueue(to: peerID)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
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
            if desiredPeerID == peerID {
                desiredPeerID = nil
                cancelReconnect(resetAttempt: true)
            }
            peerEpochs.advance(for: peerID)
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
        }
    }

    func send(_ payload: Data) {
        queue.async { [weak self] in
            guard let self,
                  let activeContextID,
                  let context = contexts[activeContextID],
                  context.channel != nil else {
                self?.publishStatus("No encrypted session is connected")
                return
            }
            guard payload.count <= SecureSessionChannel.maximumPlaintextLength else {
                publishStatus("Secure session rejected an oversized payload")
                return
            }
            guard context.pendingPayloads.count
                    < Self.maximumPendingPayloads else {
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
            publishStatus("Network unavailable; waiting to reconnect")
            return
        }
        guard activeContextID == nil,
              !contexts.values.contains(where: { $0.localRole == .initiator }) else {
            publishStatus("Disconnect the current secure session first")
            return
        }
        guard let candidates = peersByID[peerID], !candidates.isEmpty else {
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
        guard registry.publicKey(for: peerID) == peer.identity.signingPublicKey else {
            publishStatus("The peer key does not match the pinned pairing")
            return
        }

        let connection = NWConnection(to: peer.endpoint, using: .tcp)
        let ephemeralKey = P256.KeyAgreement.PrivateKey()
        let hello = SecureSessionHandshake.make(
            role: .initiator,
            sender: credentials.identity,
            ephemeralKey: ephemeralKey
        )
        let context = SessionConnectionContext(
            connection: connection,
            expectedPeer: peer.identity,
            localRole: .initiator,
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
                    send(data, on: connection)
                    receive(on: context)
                    publishStatus("Authenticating \(peer.identity.name)…")
                } catch {
                    fail(context, message: "Could not start secure handshake")
                }
            case .failed(let error):
                fail(
                    context,
                    message: "Secure connection failed: \(error.localizedDescription)"
                )
            case .cancelled:
                remove(context)
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
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(
                name: "\(credentials.identity.serviceName)-secure",
                type: Self.serviceType,
                txtRecord: NWTXTRecord([
                    "id": credentials.identity.id.uuidString,
                    "name": credentials.identity.name,
                    "key": credentials.identity.signingPublicKey.base64EncodedString()
                ])
            )
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                if case .failed(let error) = state {
                    guard let self else { return }
                    self.publishStatus(
                        "Secure listener failed: \(error.localizedDescription)"
                    )
                    if self.listener === listener {
                        self.listener = nil
                    }
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            publishStatus("Could not start secure listener: \(error.localizedDescription)")
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
            let candidates: [(PeerIdentity, SecureServicePeer)] = results.compactMap {
                result in
                guard case let .bonjour(txtRecord) = result.metadata,
                      let identity = PeerIdentityTXTCodec.decode(txtRecord),
                      identity.id != self.credentials.identity.id else {
                    return nil
                }
                return (
                    identity,
                    SecureServicePeer(
                        identity: identity,
                        endpoint: result.endpoint
                    )
                )
            }
            peersByID = PeerIdentityAdmission.resolvePinned(
                candidates,
                pinnedKeys: registry.pairedPeers,
                maximumCandidatesPerID: Self.maximumPeerCandidatesPerID,
                identity: { $0.0 }
            ).mapValues { $0.map(\.1) }
            peerCandidateIndices = peerCandidateIndices.filter {
                self.peersByID[$0.key] != nil
            }
            retryConnectionIfNeeded()
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            if case .failed(let error) = state {
                guard let self else { return }
                self.publishStatus(
                    "Secure discovery failed: \(error.localizedDescription)"
                )
                if self.browser === browser {
                    self.browser = nil
                }
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        guard activeContextID == nil,
              contexts.count < Self.maximumPendingConnections,
              admissionLimiter.allows(
                  eventAt: DispatchTime.now().uptimeNanoseconds
              ) else {
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
                scheduleTimeout(
                    for: context,
                    after: 5,
                    message: "Secure handshake timed out"
                )
                receive(on: context)
            case .failed(let error):
                fail(
                    context,
                    message: "Incoming secure connection failed: \(error.localizedDescription)"
                )
            case .cancelled:
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
                    remove(context)
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
                    remove(context)
                } else {
                    receive(on: context)
                }
            }
        } catch {
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
                    throw SecureSessionError.invalidHandshake
                }
                context.isAuthenticated = true
                context.handshakeTimeout?.cancel()
                activeContextID = ObjectIdentifier(context)
                reconnectAttempt = 0
                cancelReconnect(resetAttempt: false)
                context.admissionGeneration = onAuthenticated?()
                publishConnection(
                    peerID: peer.id,
                    status: "Encrypted session connected to \(peer.name)",
                    admissionGeneration: context.admissionGeneration
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
                  handshake.sender == expectedPeer,
                  registry.publicKey(for: expectedPeer.id)
                    == handshake.sender.signingPublicKey,
                  let ephemeralKey = context.localEphemeralKey,
                  let initiatorHandshake = context.initiatorHandshake,
                  handshake.sessionID == initiatorHandshake.sessionID else {
                throw SecureSessionError.invalidHandshake
            }
            context.responderHandshake = handshake
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
            send(confirmationData, on: context.connection) {
                [weak self, weak context] sent in
                guard let self, let context, self.isCurrent(context) else {
                    return
                }
                guard sent,
                      self.activeContextID == nil,
                      self.registry.publicKey(for: expectedPeer.id)
                        == expectedPeer.signingPublicKey else {
                    self.fail(
                        context,
                        message: "Could not confirm the secure session key"
                    )
                    return
                }
                context.isAuthenticated = true
                context.handshakeTimeout?.cancel()
                self.activeContextID = ObjectIdentifier(context)
                self.reconnectAttempt = 0
                self.cancelReconnect(resetAttempt: false)
                context.admissionGeneration = self.onAuthenticated?()
                self.publishConnection(
                    peerID: expectedPeer.id,
                    status: "Encrypted session connected to \(expectedPeer.name)",
                    admissionGeneration: context.admissionGeneration
                )
            }

        case .responder:
            guard handshake.role == .initiator,
                  registry.publicKey(for: handshake.sender.id)
                    == handshake.sender.signingPublicKey else {
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
                ephemeralKey: ephemeralKey
            )
            context.expectedPeer = handshake.sender
            context.peerEpoch = peerEpochs.current(for: handshake.sender.id)
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
            send(data, on: context.connection) { [weak self, weak context] sent in
                guard let self, let context, self.isCurrent(context) else {
                    return
                }
                guard sent else {
                    fail(context, message: "Could not complete secure handshake")
                    return
                }
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
        if preferredRole == .initiator {
            throw SecureSessionError.invalidHandshake
        }
        outbound.connection.cancel()
        remove(outbound)
    }

    private func remove(_ context: SessionConnectionContext) {
        let contextID = ObjectIdentifier(context)
        let removedActiveContext = activeContextID == contextID
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
        if removedActiveContext || context.localRole == .initiator {
            retryConnectionIfNeeded()
        }
    }

    private func fail(
        _ context: SessionConnectionContext,
        message: String
    ) {
        publishStatus(message)
        if context.localRole == .initiator,
           !context.isAuthenticated,
           let peerID = context.expectedPeer?.id {
            advancePeerCandidate(for: peerID)
        }
        context.connection.cancel()
        remove(context)
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
                self?.publishStatus("Secure send failed: \(error.localizedDescription)")
                connection.cancel()
            }
            completion?(error == nil)
        })
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
    var localEphemeralKey: P256.KeyAgreement.PrivateKey?
    var initiatorHandshake: SecureSessionHandshake?
    var responderHandshake: SecureSessionHandshake?
    var channel: SecureSessionChannel?
    var isAuthenticated = false
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
        localEphemeralKey: P256.KeyAgreement.PrivateKey? = nil,
        initiatorHandshake: SecureSessionHandshake? = nil,
        maximumPacketsPerSecond: Int,
        maximumBytesPerSecond: Int
    ) {
        self.connection = connection
        self.expectedPeer = expectedPeer
        self.localRole = localRole
        self.localEphemeralKey = localEphemeralKey
        self.initiatorHandshake = initiatorHandshake
        self.inboundPayloadBudget = InboundPayloadBudget(
            maximumPacketsPerSecond: maximumPacketsPerSecond,
            maximumBytesPerSecond: maximumBytesPerSecond
        )
    }
}
