import Combine
import CryptoKit
import Foundation
import MacKVMCore
import Network

final class SecureSessionService: ObservableObject, ControlSessionTransport {
    @Published private(set) var connectedPeerID: UUID?
    @Published private(set) var status = "Secure session idle"

    var onPayload: ((Data) -> Void)?

    var connectedPeerIDPublisher: AnyPublisher<UUID?, Never> {
        $connectedPeerID.eraseToAnyPublisher()
    }

    private static let serviceType = "_mackvm-secure._tcp"
    private static let maximumPendingConnections = 16
    private static let maximumPendingPayloads = 64
    private static let keyConfirmation = Data(
        "MacKVM encrypted key confirmation v1".utf8
    )
    private let queue = DispatchQueue(label: "app.mackvm.secure-session")
    private let credentials: DeviceCredentials
    private let registry: PairingRegistry
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var peersByID: [UUID: SecureServicePeer] = [:]
    private var contexts: [ObjectIdentifier: SessionConnectionContext] = [:]
    private var activeContextID: ObjectIdentifier?

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
            startListener()
            startBrowser()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            listener?.cancel()
            browser?.cancel()
            contexts.values.forEach { $0.connection.cancel() }
            listener = nil
            browser = nil
            peersByID.removeAll()
            contexts.removeAll()
            activeContextID = nil
            publishConnection(peerID: nil, status: "Secure session stopped")
        }
    }

    func connect(to peerID: UUID) {
        queue.async { [weak self] in
            self?.connectOnQueue(to: peerID)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            if let activeContextID,
               let context = contexts[activeContextID] {
                context.connection.cancel()
                remove(context)
            }
            publishConnection(peerID: nil, status: "Secure session disconnected")
        }
    }

    func revoke(_ peerID: UUID) {
        queue.async { [weak self] in
            guard let self else { return }
            let revokedContexts = contexts.values.filter {
                $0.expectedPeer?.id == peerID
            }
            revokedContexts.forEach {
                $0.connection.cancel()
                self.remove($0)
            }
            if !revokedContexts.isEmpty {
                publishConnection(
                    peerID: nil,
                    status: "Trust was revoked for the disconnected peer"
                )
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
                guard let self, let context else { return }
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
        guard activeContextID == nil,
              !contexts.values.contains(where: { $0.localRole == .initiator }) else {
            publishStatus("Disconnect the current secure session first")
            return
        }
        guard let peer = peersByID[peerID] else {
            publishStatus("The paired Mac's secure service is not available")
            return
        }
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
            initiatorHandshake: hello
        )
        install(context)
        connection.stateUpdateHandler = { [weak self, weak context] state in
            guard let self, let context else { return }
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
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.publishStatus(
                        "Secure listener failed: \(error.localizedDescription)"
                    )
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
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            peersByID = results.reduce(into: [:]) { peers, result in
                    guard case let .bonjour(txtRecord) = result.metadata,
                          let identity = PeerIdentityTXTCodec.decode(txtRecord),
                          identity.id != self.credentials.identity.id else {
                        return
                    }
                    peers[identity.id] = SecureServicePeer(
                        identity: identity,
                        endpoint: result.endpoint
                    )
                }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.publishStatus(
                    "Secure discovery failed: \(error.localizedDescription)"
                )
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        guard activeContextID == nil,
              contexts.count < Self.maximumPendingConnections else {
            connection.cancel()
            return
        }
        let context = SessionConnectionContext(
            connection: connection,
            expectedPeer: nil,
            localRole: .responder
        )
        install(context)
        connection.stateUpdateHandler = { [weak self, weak context] state in
            guard let self, let context else { return }
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
            guard let self, let context else { return }
            if let data, !data.isEmpty {
                do {
                    context.buffer.append(data)
                    let messages = try SecureSessionWireCodec.decodeAvailableFrames(
                        from: &context.buffer
                    )
                    try messages.forEach {
                        try self.handle($0, in: context)
                    }
                } catch {
                    fail(context, message: "Rejected invalid secure session data")
                    return
                }
            }
            if complete || error != nil {
                remove(context)
            } else {
                receive(on: context)
            }
        }
    }

    private func handle(
        _ message: SecureSessionWireMessage,
        in context: SessionConnectionContext
    ) throws {
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
                publishConnection(
                    peerID: peer.id,
                    status: "Encrypted session connected to \(peer.name)"
                )
                return
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
                guard let self, let context else { return }
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
                self.publishConnection(
                    peerID: expectedPeer.id,
                    status: "Encrypted session connected to \(expectedPeer.name)"
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
                guard let self, let context else { return }
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

    private func scheduleTimeout(
        for context: SessionConnectionContext,
        after seconds: TimeInterval,
        message: String
    ) {
        context.handshakeTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self, weak context] in
            guard let self, let context, !context.isAuthenticated else { return }
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
        context.handshakeTimeout?.cancel()
        contexts.removeValue(forKey: contextID)
        if activeContextID == contextID {
            activeContextID = nil
            publishConnection(peerID: nil, status: "Secure session disconnected")
        }
    }

    private func fail(
        _ context: SessionConnectionContext,
        message: String
    ) {
        publishStatus(message)
        context.connection.cancel()
        remove(context)
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

    private func publishConnection(peerID: UUID?, status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.connectedPeerID = peerID
            self?.status = status
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

    init(
        connection: NWConnection,
        expectedPeer: PeerIdentity?,
        localRole: SecureSessionRole,
        localEphemeralKey: P256.KeyAgreement.PrivateKey? = nil,
        initiatorHandshake: SecureSessionHandshake? = nil
    ) {
        self.connection = connection
        self.expectedPeer = expectedPeer
        self.localRole = localRole
        self.localEphemeralKey = localEphemeralKey
        self.initiatorHandshake = initiatorHandshake
    }
}
