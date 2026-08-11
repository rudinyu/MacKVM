import Combine
import CryptoKit
import Foundation
import MacKVMCore
import Network

struct DiscoveredPeer: Identifiable {
    let id: String
    let identity: PeerIdentity
    let model: String
    let endpoint: NWEndpoint

    var name: String { identity.name }
}

struct PendingPairingRequest: Identifiable {
    let id: UUID
    let peer: PeerIdentity
    let verificationCode: String
}

enum DiscoveredPeerTrust {
    case unpaired
    case paired
    case changedKey
}

enum PairingConnectionEOFPolicy {
    static func shouldCancelAfterEOF(activePairingCount: Int) -> Bool {
        activePairingCount == 0
    }
}

final class PeerDiscoveryService: ObservableObject {
    @Published private(set) var peers: [DiscoveredPeer] = []
    @Published private(set) var pendingRequests: [PendingPairingRequest] = []
    @Published private(set) var pairedPeerIDs: Set<UUID>
    @Published private(set) var status = "Starting…"
    @Published private(set) var activeVerificationCode: String?

    let identity: PeerIdentity
    let localModel: String

    private static let serviceType = "_mackvm._tcp"
    private static let maximumPendingRequests = 5
    // Bonjour is an untrusted discovery surface. The app is designed for a
    // small set of Macs, so keep a deterministic UI/memory bound when a local
    // advertiser publishes a large number of unique identities.
    private static let maximumDiscoveredPeers = 64
    // New devices are not authenticated until the user compares and accepts
    // the verification code. Admit only one unsolicited unpaired request at
    // a time so cheap self-signed identities cannot hold every slot for 60s.
    private static let maximumUnpairedPendingRequests = 1
    private static let maximumUnauthenticatedConnections = 16
    private static let maximumPairingMessagesPerReceive = 16
    private static let maximumWireBufferLength =
        PairingWireCodec.maximumFramePayloadLength + 4
    private let queue = DispatchQueue(label: "app.mackvm.network")
    private let registry: PairingRegistry
    private let privateKey: P256.Signing.PrivateKey
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var requestConnections: [UUID: NWConnection] = [:]
    private var unauthenticatedConnections: [ObjectIdentifier: NWConnection] = [:]
    private var requestMessages: [UUID: PairingEnvelope] = [:]
    private var requestTargets: [UUID: PeerIdentity] = [:]
    // The model is learned only from a signed pairing message. Bonjour's TXT
    // model remains a discovery hint and is never persisted as trust metadata.
    private var requestPeerModels: [UUID: String] = [:]
    private var localContributions: [UUID: Data] = [:]
    private var peerCommitments: [UUID: Data] = [:]
    private var peerContributions: [UUID: Data] = [:]
    private var locallyAcceptedRequestIDs: Set<UUID> = []
    private var remotelyAcceptedRequestIDs: Set<UUID> = []
    private var completionSendStartedRequestIDs: Set<UUID> = []
    private var locallyCompletedRequestIDs: Set<UUID> = []
    private var remotelyCompletedRequestIDs: Set<UUID> = []
    private var completionAcknowledgementSendStartedRequestIDs: Set<UUID> = []
    private var locallyAcknowledgedByPeerRequestIDs: Set<UUID> = []
    private var peerClosedRequestIDs: Set<UUID> = []
    private var activeOutboundRequestID: UUID?
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private var connectionTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var admissionLimiter =
        ConnectionAdmissionLimiter.unauthenticatedConnectionLimiter()
    private let lifecycleEpoch = EpochGuard()
    private let requestForgetGenerations = GenerationGuard<UUID>()

    init(
        credentials: DeviceCredentials,
        registry: PairingRegistry = PairingRegistry(),
        localModel: String = MacHardwareInfo.currentModel
    ) {
        identity = credentials.identity
        self.localModel = PeerMetadataValidation.validatedModel(localModel)
        privateKey = credentials.privateKey
        self.registry = registry
        pairedPeerIDs = registry.pairedPeerIDs
    }

    var pairedPeerProfiles: [UUID: PairedPeerProfile] {
        registry.pairedPeerProfiles
    }

    func pairedPublicKey(for peerID: UUID) -> Data? {
        registry.publicKey(for: peerID)
    }

    func pairedPeerProfile(for peerID: UUID) -> PairedPeerProfile? {
        registry.profile(for: peerID)
    }

    @discardableResult
    func updateFriendlyName(
        for peerID: UUID,
        friendlyName: String
    ) -> Bool {
        guard registry.updateFriendlyName(
            for: peerID,
            friendlyName: friendlyName
        ) else {
            return false
        }
        objectWillChange.send()
        return true
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.listener == nil, self.browser == nil else {
                return
            }
            self.advanceLifecycleEpoch()
            self.admissionLimiter.reset()
            self.startListener()
            self.startBrowser()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.advanceLifecycleEpoch()
            self.listener?.cancel()
            self.browser?.cancel()
            self.requestConnections.values.forEach { $0.cancel() }
            self.unauthenticatedConnections.values.forEach { $0.cancel() }
            self.listener = nil
            self.browser = nil
            self.requestConnections.removeAll()
            self.unauthenticatedConnections.removeAll()
            self.requestMessages.removeAll()
            self.requestTargets.removeAll()
            self.requestPeerModels.removeAll()
            self.requestForgetGenerations.removeAll()
            self.localContributions.removeAll()
            self.peerCommitments.removeAll()
            self.peerContributions.removeAll()
            self.locallyAcceptedRequestIDs.removeAll()
            self.remotelyAcceptedRequestIDs.removeAll()
            self.completionSendStartedRequestIDs.removeAll()
            self.locallyCompletedRequestIDs.removeAll()
            self.remotelyCompletedRequestIDs.removeAll()
            self.completionAcknowledgementSendStartedRequestIDs.removeAll()
            self.locallyAcknowledgedByPeerRequestIDs.removeAll()
            self.peerClosedRequestIDs.removeAll()
            self.activeOutboundRequestID = nil
            self.receiveBuffers.removeAll()
            self.connectionTimeouts.values.forEach { $0.cancel() }
            self.connectionTimeouts.removeAll()
            self.admissionLimiter.reset()
            // Stop is authoritative even if start() is already queued behind
            // it. Do not epoch-gate this cleanup, or the next start could
            // advance the epoch before the main queue clears stale UI state.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.peers.removeAll()
                self.pendingRequests.removeAll()
                self.activeVerificationCode = nil
                self.status = "Discovery stopped"
            }
        }
    }

    func requestPairing(with peer: DiscoveredPeer) {
        queue.async { [weak self] in
            self?.requestPairingOnQueue(with: peer)
        }
    }

    private func requestPairingOnQueue(with peer: DiscoveredPeer) {
        guard activeOutboundRequestID == nil else {
            publishStatus("Finish the current pairing request first")
            return
        }
        guard PairingRequestPolicy.acceptsDiscoveredPeer(
            peer.identity,
            pinnedPublicKey: registry.publicKey(for: peer.identity.id)
        ) else {
            publishStatus("Rejected a peer with a changed identity key")
            return
        }

        let requestID = UUID()
        let contribution = PairingVerificationCode.makeContribution()
        let request = PairingEnvelope.request(
            from: identity,
            requestID: requestID,
            commitment: PairingVerificationCode.commitment(
                requestID: requestID,
                publicKey: identity.signingPublicKey,
                contribution: contribution
            ),
            senderModel: localModel
        )
        let connection = NWConnection(to: peer.endpoint, using: .tcp)
        activeOutboundRequestID = request.requestID
        requestConnections[request.requestID] = connection
        requestMessages[request.requestID] = request
        requestTargets[request.requestID] = peer.identity
        localContributions[request.requestID] = contribution
        requestForgetGenerations.set(
            registry.generation(for: peer.identity.id),
            for: request.requestID
        )

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.scheduleTimeout(for: connection, after: 60)
                self.send(request, over: connection)
                self.receive(on: connection)
                self.publishStatus("Negotiating a security code with \(peer.name)…")
            case .failed(let error):
                self.finish(requestID: request.requestID)
                self.publishStatus("Could not reach \(peer.name): \(error.localizedDescription)")
            case .cancelled:
                self.finish(requestID: request.requestID)
            default:
                break
            }
        }
        scheduleTimeout(for: connection, after: 15)
        connection.start(queue: queue)
    }

    func respond(to pending: PendingPairingRequest, accepted: Bool) {
        queue.async { [weak self] in
            self?.respondOnQueue(to: pending, accepted: accepted)
        }
    }

    private func respondOnQueue(
        to pending: PendingPairingRequest,
        accepted: Bool
    ) {
        guard let connection = requestConnections[pending.id],
              let request = requestMessages[pending.id] else {
            publishStatus("The pairing request has expired")
            removePendingRequest(id: pending.id)
            return
        }

        let response = PairingEnvelope.decision(
            to: request,
            from: identity,
            accepted: accepted,
            senderModel: localModel
        )
        send(response, over: connection) { [weak self] sent in
            guard let self else { return }
            guard sent else {
                self.finish(requestID: pending.id)
                return
            }
            if accepted {
                self.locallyAcceptedRequestIDs.insert(pending.id)
                self.beginCompletionIfMutuallyAccepted(requestID: pending.id)
            } else {
                self.finish(requestID: pending.id)
            }
        }
        removePendingRequest(id: pending.id)
        publishStatus(
            accepted
                ? "Waiting for \(pending.peer.name) to confirm"
                : "Pairing request declined"
        )
    }

    func forget(_ peerID: UUID) {
        // Keep trust removal synchronous with the user action. The secure
        // listener runs on another queue and must not authenticate this peer
        // while the queued discovery cleanup is waiting to run.
        registry.revoke(peerID)
        queue.async { [weak self] in
            guard let self else { return }
            // Keep this idempotent removal as a safety net for a completion
            // that was already queued before revoke(); add(ifGeneration:)
            // rejects any newer stale completion atomically with revoke().
            registry.remove(peerID)

            let requestIDs = requestConnections.compactMap { requestID, _ in
                let peer = self.requestTargets[requestID]
                    ?? self.requestMessages[requestID]?.sender
                return peer?.id == peerID ? requestID : nil
            }
            requestIDs.forEach { self.finish(requestID: $0) }
            let pendingIDs = self.requestMessages.compactMap { requestID, message in
                message.sender.id == peerID ? requestID : nil
            }
            pendingIDs.forEach { self.finish(requestID: $0) }
            publishMain {
                $0.pairedPeerIDs.remove(peerID)
                $0.pendingRequests.removeAll { $0.peer.id == peerID }
            }
        }
    }

    func trustState(for peer: DiscoveredPeer) -> DiscoveredPeerTrust {
        guard let pinnedKey = registry.publicKey(for: peer.identity.id) else {
            return .unpaired
        }
        return pinnedKey == peer.identity.signingPublicKey
            ? .paired
            : .changedKey
    }

    private func startListener() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(
                name: identity.serviceName,
                type: Self.serviceType,
                txtRecord: NWTXTRecord([
                    "id": identity.id.uuidString,
                    "name": identity.name,
                    "model": localModel,
                    "key": identity.signingPublicKey.base64EncodedString()
                ])
            )
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    self?.publishStatus("Ready on the local network")
                case .failed(let error):
                    guard let self else { return }
                    self.publishStatus(
                        "Listening failed: \(error.localizedDescription)"
                    )
                    if self.listener === listener {
                        self.listener?.cancel()
                        self.listener = nil
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            publishStatus("Could not start listener: \(error.localizedDescription)")
        }
    }

    private func startBrowser() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(
                type: Self.serviceType,
                domain: nil
            ),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, self.browser === browser else { return }
            let candidates = results.compactMap {
                (result) -> (PeerAdvertisement, DiscoveredPeer)? in
                guard case let .service(name, _, _, _) = result.endpoint,
                      name != self.identity.serviceName,
                      case let .bonjour(txtRecord) = result.metadata,
                      let advertisement = PeerIdentityTXTCodec.decodeAdvertisement(
                          txtRecord
                      ),
                      advertisement.identity.id != self.identity.id else {
                    return nil
                }
                return (
                    advertisement,
                    DiscoveredPeer(
                        id: name,
                        identity: advertisement.identity,
                        model: advertisement.model,
                        endpoint: result.endpoint
                    )
                )
            }
            // NWBrowser delivers a Set, whose iteration order is not stable.
            // Order before applying the admission cap so an attacker cannot
            // make an otherwise valid peer churn in and out of the first 64
            // entries. Paired identities are kept ahead of unpaired ones;
            // the remaining tie-breakers are deterministic and do not rely on
            // Bonjour result order.
            let orderedCandidates = candidates.sorted {
                let lhsPaired = self.registry.contains($0.0.identity.id)
                let rhsPaired = self.registry.contains($1.0.identity.id)
                if lhsPaired != rhsPaired {
                    return lhsPaired
                }
                let lhsID = $0.0.identity.id.uuidString
                let rhsID = $1.0.identity.id.uuidString
                if lhsID != rhsID {
                    return lhsID < rhsID
                }
                let lhsKey = $0.0.identity.signingPublicKey
                    .base64EncodedString()
                let rhsKey = $1.0.identity.signingPublicKey
                    .base64EncodedString()
                if lhsKey != rhsKey {
                    return lhsKey < rhsKey
                }
                return $0.1.id < $1.1.id
            }
            let discoveredByID = PeerIdentityAdmission.resolve(
                orderedCandidates,
                maximumIdentities: Self.maximumDiscoveredPeers,
                identity: { $0.0.identity }
            )
            let discovered = discoveredByID.values.sorted {
                $0.1.name.localizedCaseInsensitiveCompare($1.1.name)
                    == .orderedAscending
            }.prefix(Self.maximumDiscoveredPeers).map(\.1)
            let epoch = self.currentLifecycleEpoch()
            self.publishMain(epoch: epoch) { $0.peers = discovered }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            if case .failed(let error) = state {
                guard let self else { return }
                self.publishStatus(
                    "Discovery failed: \(error.localizedDescription)"
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
        guard unauthenticatedConnections.count
                < Self.maximumUnauthenticatedConnections,
              admissionLimiter.allows(
                  eventAt: DispatchTime.now().uptimeNanoseconds
              ) else {
            connection.cancel()
            return
        }
        unauthenticatedConnections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.scheduleTimeout(for: connection, after: 10)
                self.receive(on: connection)
            case .failed, .cancelled:
                self.removeConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65_536
        ) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            let connectionID = ObjectIdentifier(connection)
            guard self.isTracked(connection) else {
                return
            }

            if let data, !data.isEmpty {
                self.receiveBuffers[connectionID, default: Data()].append(data)
            }
            self.drainBufferedFrames(
                on: connection,
                connectionEnded: isComplete || error != nil,
                remainingMessageBudget: Self.maximumPairingMessagesPerReceive
            )
        }
    }

    private func drainBufferedFrames(
        on connection: NWConnection,
        connectionEnded: Bool,
        remainingMessageBudget: Int
    ) {
        guard isTracked(connection) else { return }
        let connectionID = ObjectIdentifier(connection)
        do {
            let messages = try PairingWireCodec.decodeAvailableFrames(
                from: &receiveBuffers[connectionID, default: Data()],
                maximumFrameCount: remainingMessageBudget
            )
            let hasCompleteFrame = PairingWireCodec.hasCompleteFrame(
                in: receiveBuffers[connectionID, default: Data()]
            )
            guard BufferedFrameDrainPolicy.acceptsBufferedBytes(
                    bufferCount: receiveBuffers[connectionID, default: Data()].count,
                    maximumBufferLength: Self.maximumWireBufferLength,
                    hasCompleteFrame: hasCompleteFrame
                  ) else {
                throw PairingWireError.payloadTooLarge
            }
            messages.forEach {
                handle($0, on: connection)
            }
            let nextMessageBudget = remainingMessageBudget - messages.count
            if BufferedFrameDrainPolicy.shouldContinueDecoding(
                decodedFrameCount: messages.count,
                hasCompleteFrame: hasCompleteFrame
            ) {
                guard nextMessageBudget > 0 else {
                    throw PairingWireError.tooManyMessages
                }
                queue.async { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.drainBufferedFrames(
                        on: connection,
                        connectionEnded: connectionEnded,
                        remainingMessageBudget: nextMessageBudget
                    )
                }
            } else if connectionEnded {
                if receiveBuffers[connectionID, default: Data()].isEmpty {
                    handlePeerFinishedSending(connection)
                } else {
                    publishStatus("Received an incomplete pairing message")
                    connection.cancel()
                    removeConnection(connection)
                }
            } else {
                receive(on: connection)
            }
        } catch PairingWireError.tooManyMessages {
            publishStatus("Received too many pairing messages in one delivery")
            connection.cancel()
            removeConnection(connection)
        } catch {
            publishStatus("Received an invalid pairing message")
            connection.cancel()
            removeConnection(connection)
        }
    }

    private func handle(_ message: PairingEnvelope, on connection: NWConnection) {
        switch message.kind {
        case .request:
            guard message.sender.id != identity.id else {
                connection.cancel()
                return
            }
            if let outboundRequestID = activeOutboundRequestID,
               requestTargets[outboundRequestID]?.id == message.sender.id {
                if PairingRequestPolicy.keepOutboundDuringCollision(
                    localID: identity.id,
                    remoteID: message.sender.id
                ) {
                    publishStatus(
                        "Kept the outgoing pairing request after a simultaneous request"
                    )
                    connection.cancel()
                    return
                }
                finish(requestID: outboundRequestID)
            }
            let decision = PairingRequestPolicy.evaluate(
                request: message,
                pinnedPublicKey: registry.publicKey(for: message.sender.id),
                activeRequestIDs: Set(requestMessages.keys),
                pendingSenderIDs: Set(
                    requestMessages.values
                        .filter { $0.kind == .request }
                        .map(\.sender.id)
                ),
                activeRequestCount: requestMessages.count,
                maximumPendingRequests: Self.maximumPendingRequests,
                activeUnpairedRequestCount: requestMessages.values.filter {
                    $0.kind == .request
                        && $0.sender.id != identity.id
                        && registry.publicKey(for: $0.sender.id) == nil
                }.count,
                maximumUnpairedPendingRequests:
                    Self.maximumUnpairedPendingRequests
            )
            guard decision == .allow else {
                publishStatus(statusMessage(for: decision))
                connection.cancel()
                return
            }
            guard let peerCommitment = message.verificationCommitment,
                  peerCommitment.count == SHA256.Digest.byteCount else {
                publishStatus("Rejected an invalid pairing commitment")
                connection.cancel()
                return
            }
            let localContribution = PairingVerificationCode.makeContribution()
            unauthenticatedConnections.removeValue(
                forKey: ObjectIdentifier(connection)
            )
            scheduleTimeout(for: connection, after: 60)
            requestConnections[message.requestID] = connection
            requestMessages[message.requestID] = message
            if let model = message.senderModel {
                // The request has passed the admission policy and is now
                // bound to this request ID and sender connection.
                requestPeerModels[message.requestID] = model
            }
            localContributions[message.requestID] = localContribution
            requestForgetGenerations.set(
                registry.generation(for: message.sender.id),
                for: message.requestID
            )
            peerCommitments[message.requestID] = peerCommitment
            let challenge = PairingEnvelope.challenge(
                to: message,
                from: identity,
                commitment: PairingVerificationCode.commitment(
                    requestID: message.requestID,
                    publicKey: identity.signingPublicKey,
                    contribution: localContribution
                ),
                senderModel: localModel
            )
            send(challenge, over: connection)
            publishStatus("Negotiating a security code with \(message.sender.name)…")

        case .challenge:
            guard let expectedPeer = validatedOutboundPeer(for: message),
                  let peerCommitment = message.verificationCommitment,
                  peerCommitment.count == SHA256.Digest.byteCount,
                  let localContribution = localContributions[message.requestID],
                  let request = requestMessages[message.requestID] else {
                rejectUnexpected(message, on: connection)
                return
            }
            peerCommitments[message.requestID] = peerCommitment
            if let model = message.senderModel {
                // validatedOutboundPeer binds this model to the tracked peer.
                requestPeerModels[message.requestID] = model
            }
            let reveal = PairingEnvelope.reveal(
                to: request,
                from: identity,
                contribution: localContribution,
                senderModel: localModel
            )
            send(reveal, over: connection)
            publishStatus("Waiting for \(expectedPeer.name) to confirm the code…")

        case .reveal:
            guard let request = requestMessages[message.requestID],
                  request.sender.id == message.sender.id,
                  request.sender.signingPublicKey == message.sender.signingPublicKey,
                  let commitment = peerCommitments[message.requestID],
                  let peerContribution = message.verificationContribution,
                  PairingVerificationCode.verifies(
                      commitment: commitment,
                      requestID: message.requestID,
                      publicKey: message.sender.signingPublicKey,
                      contribution: peerContribution
                  ),
                  let localContribution = localContributions[message.requestID] else {
                rejectUnexpected(message, on: connection)
                return
            }
            if let model = message.senderModel {
                // The request sender and signing key were checked above.
                requestPeerModels[message.requestID] = model
            }
            peerContributions[message.requestID] = peerContribution
            let verificationCode = PairingVerificationCode.make(
                requestID: message.requestID,
                initiatorPublicKey: message.sender.signingPublicKey,
                responderPublicKey: identity.signingPublicKey,
                initiatorContribution: peerContribution,
                responderContribution: localContribution
            )
            publishMain { service in
                if !service.pendingRequests.contains(where: { $0.id == message.requestID }) {
                    service.pendingRequests.append(
                        PendingPairingRequest(
                            id: message.requestID,
                            peer: message.sender,
                            verificationCode: verificationCode
                        )
                    )
                }
                service.status = "\(message.sender.name) wants to pair"
            }
            let confirmation = PairingEnvelope.confirmation(
                to: request,
                from: identity,
                contribution: localContribution,
                senderModel: localModel
            )
            send(confirmation, over: connection)

        case .confirmation:
            guard let expectedPeer = validatedOutboundPeer(for: message),
                  let peerCommitment = peerCommitments[message.requestID],
                  let peerContribution = message.verificationContribution,
                  PairingVerificationCode.verifies(
                      commitment: peerCommitment,
                      requestID: message.requestID,
                      publicKey: expectedPeer.signingPublicKey,
                      contribution: peerContribution
                  ),
                  let localContribution = localContributions[message.requestID] else {
                rejectUnexpected(message, on: connection)
                return
            }
            if let model = message.senderModel {
                // validatedOutboundPeer binds this model to the tracked peer.
                requestPeerModels[message.requestID] = model
            }
            peerContributions[message.requestID] = peerContribution
            let verificationCode = PairingVerificationCode.make(
                requestID: message.requestID,
                initiatorPublicKey: identity.signingPublicKey,
                responderPublicKey: expectedPeer.signingPublicKey,
                initiatorContribution: localContribution,
                responderContribution: peerContribution
            )
            publishMain { $0.activeVerificationCode = verificationCode }
            addPendingConfirmation(
                requestID: message.requestID,
                peer: expectedPeer,
                verificationCode: verificationCode
            )
            publishStatus("Compare code \(verificationCode) with \(expectedPeer.name)")

        case .decision:
            guard let peer = validatedSessionPeer(for: message),
                  peerContributions[message.requestID] != nil else {
                rejectUnexpected(message, on: connection)
                return
            }
            if let model = message.senderModel {
                // validatedSessionPeer binds this model to the paired peer.
                requestPeerModels[message.requestID] = model
            }
            guard message.accepted == true else {
                publishStatus("\(message.sender.name) declined pairing")
                finish(requestID: message.requestID)
                return
            }
            remotelyAcceptedRequestIDs.insert(message.requestID)
            if locallyAcceptedRequestIDs.contains(message.requestID) {
                beginCompletionIfMutuallyAccepted(
                    requestID: message.requestID
                )
            } else {
                publishStatus("\(peer.name) confirmed; confirm the matching code locally")
            }

        case .completion:
            guard let peer = validatedSessionPeer(for: message),
                  peerContributions[message.requestID] != nil,
                  locallyAcceptedRequestIDs.contains(message.requestID),
                  remotelyAcceptedRequestIDs.contains(message.requestID) else {
                rejectUnexpected(message, on: connection)
                return
            }
            if let model = message.senderModel {
                // validatedSessionPeer binds this model to the paired peer.
                requestPeerModels[message.requestID] = model
            }
            remotelyCompletedRequestIDs.insert(message.requestID)
            beginCompletionIfMutuallyAccepted(requestID: message.requestID)
            beginCompletionAcknowledgement(requestID: message.requestID)
            completePairingIfTransportConfirmed(
                with: peer,
                requestID: message.requestID
            )

        case .completionAcknowledgement:
            guard let peer = validatedSessionPeer(for: message),
                  completionSendStartedRequestIDs.contains(message.requestID),
                  remotelyCompletedRequestIDs.contains(message.requestID) else {
                rejectUnexpected(message, on: connection)
                return
            }
            if let model = message.senderModel {
                // validatedSessionPeer binds this model to the paired peer.
                requestPeerModels[message.requestID] = model
            }
            // Receiving this signed acknowledgement proves that the peer
            // received our completion, even if Network.framework has not yet
            // delivered the local contentProcessed callback.
            locallyCompletedRequestIDs.insert(message.requestID)
            locallyAcknowledgedByPeerRequestIDs.insert(message.requestID)
            completePairingIfTransportConfirmed(
                with: peer,
                requestID: message.requestID
            )
        }
    }

    private func send(
        _ message: PairingEnvelope,
        over connection: NWConnection,
        isFinal: Bool = false,
        completion: ((Bool) -> Void)? = nil
    ) {
        do {
            let data = try PairingWireCodec.encode(
                message,
                signingWith: privateKey
            )
            connection.send(
                content: data,
                contentContext: isFinal ? .finalMessage : .defaultMessage,
                isComplete: isFinal,
                completion: .contentProcessed { [weak self] error in
                    if let error {
                        self?.publishStatus(
                            "Send failed: \(error.localizedDescription)"
                        )
                    }
                    completion?(error == nil)
                }
            )
        } catch {
            publishStatus("Could not encode pairing message")
            completion?(false)
        }
    }

    private func savePairing(
        with peer: PeerIdentity,
        expectedRegistryGeneration: UInt64,
        model: String?
    ) -> Bool {
        guard registry.add(
            peer,
            ifGeneration: expectedRegistryGeneration,
            model: model
        ) else {
            return false
        }
        publishMain { $0.pairedPeerIDs.insert(peer.id) }
        return true
    }

    private func finish(
        requestID: UUID,
        cancelConnection: Bool = true
    ) {
        if activeOutboundRequestID == requestID {
            activeOutboundRequestID = nil
            publishMain { $0.activeVerificationCode = nil }
        }
        if let connection = requestConnections.removeValue(
            forKey: requestID
        ) {
            cleanup(connection)
            if cancelConnection {
                connection.cancel()
            }
        }
        requestMessages.removeValue(forKey: requestID)
        requestTargets.removeValue(forKey: requestID)
        requestPeerModels.removeValue(forKey: requestID)
        localContributions.removeValue(forKey: requestID)
        requestForgetGenerations.remove(for: requestID)
        peerCommitments.removeValue(forKey: requestID)
        peerContributions.removeValue(forKey: requestID)
        locallyAcceptedRequestIDs.remove(requestID)
        remotelyAcceptedRequestIDs.remove(requestID)
        completionSendStartedRequestIDs.remove(requestID)
        locallyCompletedRequestIDs.remove(requestID)
        remotelyCompletedRequestIDs.remove(requestID)
        completionAcknowledgementSendStartedRequestIDs.remove(requestID)
        locallyAcknowledgedByPeerRequestIDs.remove(requestID)
        peerClosedRequestIDs.remove(requestID)
        removePendingRequest(id: requestID)
    }

    private func removeConnection(_ connection: NWConnection) {
        cleanup(connection)
        let requestIDs = requestConnections
            .filter { $0.value === connection }
            .map(\.key)
        requestIDs.forEach { finish(requestID: $0) }
    }

    private func handlePeerFinishedSending(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        receiveBuffers.removeValue(forKey: connectionID)
        let requestIDs = requestConnections
            .filter { $0.value === connection }
            .map(\.key)
        // A peer can close before sending a pairing frame. Such a connection
        // is still tracked as unauthenticated because Network.framework does
        // not necessarily emit a second cancelled state after EOF. Release
        // its admission slot immediately instead of waiting for the timeout.
        if PairingConnectionEOFPolicy.shouldCancelAfterEOF(
            activePairingCount: requestIDs.count
        ) {
            cleanup(connection)
            connection.cancel()
            return
        }
        for requestID in requestIDs {
            guard remotelyCompletedRequestIDs.contains(requestID),
                  let peer = requestTargets[requestID]
                    ?? requestMessages[requestID]?.sender else {
                finish(requestID: requestID)
                continue
            }
            peerClosedRequestIDs.insert(requestID)
            completePairingIfTransportConfirmed(
                with: peer,
                requestID: requestID
            )
        }
    }

    private func cleanup(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        connectionTimeouts.removeValue(forKey: connectionID)?.cancel()
        receiveBuffers.removeValue(forKey: connectionID)
        unauthenticatedConnections.removeValue(forKey: connectionID)
    }

    private func scheduleTimeout(
        for connection: NWConnection,
        after seconds: TimeInterval = 60
    ) {
        let connectionID = ObjectIdentifier(connection)
        connectionTimeouts.removeValue(forKey: connectionID)?.cancel()

        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            guard self.isTracked(connection) else {
                return
            }
            self.publishStatus("Pairing request timed out")
            connection.cancel()
            self.removeConnection(connection)
        }
        connectionTimeouts[connectionID] = timeout
        queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    private func removePendingRequest(id: UUID) {
        publishMain { $0.pendingRequests.removeAll { $0.id == id } }
    }

    private func addPendingConfirmation(
        requestID: UUID,
        peer: PeerIdentity,
        verificationCode: String
    ) {
        publishMain { service in
            guard !service.pendingRequests.contains(where: { $0.id == requestID }) else {
                return
            }
            service.pendingRequests.append(
                PendingPairingRequest(
                    id: requestID,
                    peer: peer,
                    verificationCode: verificationCode
                )
            )
        }
    }

    private func publishStatus(_ message: String) {
        publishMain { $0.status = message }
    }

    private func publishMain(
        epoch: UInt64? = nil,
        _ update: @escaping (PeerDiscoveryService) -> Void
    ) {
        let expectedEpoch = epoch ?? currentLifecycleEpoch()
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.currentLifecycleEpoch() == expectedEpoch else { return }
            update(self)
        }
    }

    private func advanceLifecycleEpoch() {
        lifecycleEpoch.advance()
    }

    private func currentLifecycleEpoch() -> UInt64 {
        lifecycleEpoch.current()
    }

    private func isTracked(_ connection: NWConnection) -> Bool {
        let connectionID = ObjectIdentifier(connection)
        return requestConnections.values.contains { $0 === connection }
            || unauthenticatedConnections[connectionID] != nil
    }

    private func validatedOutboundPeer(
        for message: PairingEnvelope
    ) -> PeerIdentity? {
        guard let expectedPeer = requestTargets[message.requestID],
              expectedPeer.id == message.sender.id,
              expectedPeer.signingPublicKey == message.sender.signingPublicKey else {
            return nil
        }
        return expectedPeer
    }

    private func validatedSessionPeer(
        for message: PairingEnvelope
    ) -> PeerIdentity? {
        let expectedPeer = requestTargets[message.requestID]
            ?? requestMessages[message.requestID]?.sender
        guard let expectedPeer,
              expectedPeer.id == message.sender.id,
              expectedPeer.signingPublicKey == message.sender.signingPublicKey else {
            return nil
        }
        return expectedPeer
    }

    private func beginCompletionIfMutuallyAccepted(requestID: UUID) {
        guard locallyAcceptedRequestIDs.contains(requestID),
              remotelyAcceptedRequestIDs.contains(requestID),
              !completionSendStartedRequestIDs.contains(requestID),
              let connection = requestConnections[requestID],
              let request = requestMessages[requestID] else {
            return
        }
        completionSendStartedRequestIDs.insert(requestID)
            let completionMessage = PairingEnvelope.completion(
                to: request,
                from: identity,
                senderModel: localModel
        )
        send(
            completionMessage,
            over: connection
        ) { [weak self] sent in
            guard let self else { return }
            guard sent else {
                finish(requestID: requestID)
                return
            }
            guard requestConnections[requestID] != nil else { return }
            locallyCompletedRequestIDs.insert(requestID)
            beginCompletionAcknowledgement(requestID: requestID)
            guard let peer = requestTargets[requestID]
                    ?? requestMessages[requestID]?.sender else {
                finish(requestID: requestID)
                return
            }
            completePairingIfTransportConfirmed(
                with: peer,
                requestID: requestID
            )
        }
    }

    private func beginCompletionAcknowledgement(requestID: UUID) {
        guard remotelyCompletedRequestIDs.contains(requestID),
              !completionAcknowledgementSendStartedRequestIDs.contains(
                requestID
              ),
              let connection = requestConnections[requestID],
              let request = requestMessages[requestID] else {
            return
        }
        completionAcknowledgementSendStartedRequestIDs.insert(requestID)
        let acknowledgement = PairingEnvelope.completionAcknowledgement(
            to: request,
            from: identity,
            senderModel: localModel
        )
        send(
            acknowledgement,
            over: connection,
            isFinal: true
        ) { [weak self] sent in
            guard let self, !sent else { return }
            finish(requestID: requestID)
        }
    }

    private func completePairingIfTransportConfirmed(
        with peer: PeerIdentity,
        requestID: UUID
    ) {
        guard let trackedPeer = requestTargets[requestID]
                ?? requestMessages[requestID]?.sender,
              trackedPeer.id == peer.id else {
            return
        }
        let completionGuard = PairingCompletionGuard(
            requestID: requestID,
            peerID: trackedPeer.id,
            generation: requestForgetGenerations.current(for: requestID)
        )
        guard locallyAcceptedRequestIDs.contains(requestID),
              remotelyAcceptedRequestIDs.contains(requestID),
              locallyCompletedRequestIDs.contains(requestID),
              remotelyCompletedRequestIDs.contains(requestID),
              locallyAcknowledgedByPeerRequestIDs.contains(requestID),
              peerClosedRequestIDs.contains(requestID),
              completionGuard.permits(
                  currentGeneration: registry.generation(for: peer.id)
              ) else {
            return
        }
        guard savePairing(
            with: peer,
            expectedRegistryGeneration: completionGuard.generation,
            model: requestPeerModels[requestID]
        ) else {
            return
        }
        publishStatus("Paired with \(peer.name)")
        finish(requestID: requestID, cancelConnection: false)
    }

    private func rejectUnexpected(
        _ message: PairingEnvelope,
        on connection: NWConnection
    ) {
        publishStatus("Rejected an unexpected pairing message")
        connection.cancel()
        if requestConnections[message.requestID] === connection {
            finish(requestID: message.requestID)
        } else {
            cleanup(connection)
        }
    }

    private func statusMessage(
        for decision: PairingRequestDecision
    ) -> String {
        switch decision {
        case .allow:
            return "Pairing request accepted"
        case .rejectChangedKey:
            return "Rejected a peer with a changed identity key"
        case .rejectDuplicateRequest:
            return "Rejected a duplicate pairing request"
        case .rejectDuplicateSender:
            return "A request from this peer is already pending"
        case .rejectAtCapacity:
            return "Rejected excess pairing requests"
        }
    }
}
