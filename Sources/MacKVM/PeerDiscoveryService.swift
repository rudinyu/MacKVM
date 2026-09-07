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

/// The initiator must compare the displayed code with the receiving Mac
/// before it sends its signed acceptance. Keeping this state separate from an
/// incoming request makes the consent direction explicit in the UI and keeps
/// an attacker who only spoofs Bonjour metadata from being pinned silently.
struct PendingPairingConfirmation: Identifiable {
    let id: UUID
    let peer: PeerIdentity
    let verificationCode: String
}

/// The user-visible state of an outbound pairing attempt. Keeping this
/// separate from the verification-code prompt lets the menu cancel or retry
/// a request while Network.framework is still waiting for the receiving Mac's
/// listener (for example while its firewall approval is pending).
enum PairingActivity: Equatable {
    case idle
    case connecting(peerID: UUID, peerName: String)
    case awaitingConfirmation(peerID: UUID, peerName: String)
    case retryAvailable(peerID: UUID, peerName: String)

    var isActive: Bool {
        self != .idle
    }

    var peerID: UUID? {
        switch self {
        case .idle:
            return nil
        case let .connecting(peerID, _),
            let .awaitingConfirmation(peerID, _),
            let .retryAvailable(peerID, _):
            return peerID
        }
    }

    var peerName: String? {
        switch self {
        case .idle:
            return nil
        case let .connecting(_, peerName),
            let .awaitingConfirmation(_, peerName),
            let .retryAvailable(_, peerName):
            return peerName
        }
    }

    var canCancel: Bool {
        switch self {
        case .connecting, .awaitingConfirmation:
            return true
        case .idle, .retryAvailable:
            return false
        }
    }
}

/// Work captured after the signed pairing completion has crossed the close
/// barrier. Registry persistence can touch UserDefaults and compete with
/// SwiftUI reads, so it must not run on the Network.framework queue. Keeping
/// the peer and generation in one immutable job also lets the completion
/// callback re-check revocation before publishing trust to the UI.
private final class PairingPersistenceJob: @unchecked Sendable {
    let requestID: UUID
    let peer: PeerIdentity
    let expectedRegistryGeneration: UInt64
    let model: String?
    let lifecycleEpoch: UInt64

    init(
        requestID: UUID,
        peer: PeerIdentity,
        expectedRegistryGeneration: UInt64,
        model: String?,
        lifecycleEpoch: UInt64
    ) {
        self.requestID = requestID
        self.peer = peer
        self.expectedRegistryGeneration = expectedRegistryGeneration
        self.model = model
        self.lifecycleEpoch = lifecycleEpoch
    }
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

enum PairingTimeoutPhase: Equatable {
    case outboundTransport
    case inboundTransport
    case protocolNegotiation
    case userDecision
    case completion
}

enum PairingTimeoutPolicy {
    static let outboundTransport: TimeInterval = 15
    static let inboundTransport: TimeInterval = 10
    static let protocolNegotiation: TimeInterval = 60
    static let userDecision: TimeInterval = 120
    static let completion: TimeInterval = 30

    static func duration(for phase: PairingTimeoutPhase) -> TimeInterval {
        switch phase {
        case .outboundTransport:
            outboundTransport
        case .inboundTransport:
            inboundTransport
        case .protocolNegotiation:
            protocolNegotiation
        case .userDecision:
            userDecision
        case .completion:
            completion
        }
    }
}

final class PeerDiscoveryService: ObservableObject {
    @Published private(set) var peers: [DiscoveredPeer] = []
    @Published private(set) var pendingRequests: [PendingPairingRequest] = []
    @Published private(set) var pairedPeerIDs: Set<UUID>
    @Published private(set) var status = "Starting…"
    @Published private(set) var activeVerificationCode: String?
    @Published private(set) var pendingPairingConfirmation:
        PendingPairingConfirmation?
    @Published private(set) var pairingActivity: PairingActivity = .idle
    @Published private(set) var pairingRetryPeer: DiscoveredPeer?

    /// Called after both sides have recorded the signed pairing completion.
    /// The app wires this to the secure-session connector so a user does not
    /// have to rediscover a newly paired Mac and press Connect before using
    /// the shared keyboard. A newly completed pairing enables the receiver's
    /// local seamless-control authorization; an existing peer can opt out in
    /// its paired-device settings and return to per-request Allow actions.
    var onPairingCompleted: ((UUID, UInt64) -> Void)?

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
    // Serializes lifecycle invalidation with the final pairing registry write.
    // A worker must not pass its epoch check and then race stop() before the
    // durable trust mutation.
    private let pairingLifecycleLock = NSLock()
    private let registry: PairingRegistry
    private let privateKey: P256.Signing.PrivateKey
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var listenerIsReady = false
    private var browserIsReady = false
    private var networkRecoveryWorkItem: DispatchWorkItem?
    private var networkRecoveryAttempt = 0
    private var networkRecoveryGeneration: UInt64 = 0
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
    private var pendingPairingConfirmationRequestID: UUID?
    private var locallyAcceptedRequestIDs: Set<UUID> = []
    private var remotelyAcceptedRequestIDs: Set<UUID> = []
    private var completionSendStartedRequestIDs: Set<UUID> = []
    private var locallyCompletedRequestIDs: Set<UUID> = []
    private var remotelyCompletedRequestIDs: Set<UUID> = []
    private var completionAcknowledgementSendStartedRequestIDs: Set<UUID> = []
    // Do not cancel a pairing connection until our acknowledgement has been
    // accepted by Network.framework. With simultaneous completions, the
    // peer's acknowledgement can arrive while our outbound acknowledgement
    // is still queued; cancelling at that point would leave the peer unable
    // to persist the pairing.
    private var completionAcknowledgementDeliveredRequestIDs: Set<UUID> = []
    // The lower UUID sends one signed close barrier after both acknowledgement
    // frames have crossed the connection. Both close-barrier frames stay on
    // the TCP stream (they are not Network.framework final messages); the
    // lower side cancels only after it receives the higher side's signed
    // receipt. This avoids NWError 89 when macOS rejects a reply after a
    // peer has marked its sending direction complete.
    private var completionCloseSendStartedRequestIDs: Set<UUID> = []
    private var completionCloseDeliveredRequestIDs: Set<UUID> = []
    private var completionCloseReceivedRequestIDs: Set<UUID> = []
    private var completionCloseAcknowledgementSendStartedRequestIDs: Set<UUID> = []
    private var completionCloseAcknowledgementDeliveredRequestIDs: Set<UUID> = []
    private var completionCloseAcknowledgementReceivedRequestIDs: Set<UUID> = []
    // The lower-ID side waits briefly after receiving the signed receipt so
    // the higher-ID side's non-final send can receive its contentProcessed
    // callback before the connection is cancelled. This is a transport grace
    // period only; persistence still requires the callback to report success.
    private var completionCloseFinishScheduledRequestIDs: Set<UUID> = []
    // Every current pairing frame authenticates this capability. Keep the
    // per-request bit so completion code can fail closed if a future decoder
    // ever admits an incomplete negotiation.
    private var peerSupportsCompletionCloseRequestIDs: Set<UUID> = []
    private var locallyAcknowledgedByPeerRequestIDs: Set<UUID> = []
    // Pairing persistence is recorded as soon as both signed completion
    // proofs are present, but the request remains tracked until the peer has
    // finished its side of the final-message exchange. This prevents a local
    // `contentProcessed` callback from cancelling the connection before the
    // peer application can consume our final acknowledgement.
    private var pairingPersistenceRecordedRequestIDs: Set<UUID> = []
    private var pairingPersistenceJobs: [UUID: PairingPersistenceJob] = [:]
    // A peer can have more than one pairing attempt over its lifetime. Keep
    // the latest persistence request token so a canceled older worker cannot
    // revoke a newer successful retry for the same peer.
    private var latestPairingPersistenceRequestIDsByPeer: [UUID: UUID] = [:]
    /// A cancelled completion can finish after a retry has started. Keep the
    /// request IDs whose writes succeeded until that retry either succeeds or
    /// fails, so a failed retry cannot leave the cancelled trust record behind.
    private var cancelledPersistenceTrustJobsByPeer: [UUID: [PairingPersistenceJob]] = [:]
    private var latestSuccessfulPersistenceRequestIDsByPeer: [UUID: UUID] = [:]
    private var requestPeerDescriptors: [UUID: DiscoveredPeer] = [:]
    // A user cancellation can race the persistence worker. Keep cancellation
    // intent separate from the job so the worker can either skip the write or
    // roll it back before publishing trust.
    private var cancelledPersistenceRequestIDs: Set<UUID> = []
    // EOF can arrive before the final close-receipt send callback. Remember
    // it so the persistence callback can release the request instead of
    // leaving it tracked until the 60-second timeout.
    private var peerFinishedSendingRequestIDs: Set<UUID> = []
    private var activeOutboundRequestID: UUID?
    // Retry only after the previous TCP pairing transport has reported its
    // cancellation. Network.framework can deliver that callback after the
    // user taps Retry, while the receiver still has the old sender admission
    // in its request table.
    private var pendingRetryPeer: DiscoveredPeer?
    private var pendingRetryGeneration: UInt64 = 0
    private var pendingRetryWorkItem: DispatchWorkItem?
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private var connectionTimeouts: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var admissionLimiter =
        ConnectionAdmissionLimiter.unauthenticatedConnectionLimiter()
    private let lifecycleEpoch = EpochGuard()
    private let requestForgetGenerations = GenerationGuard<UUID>()
    // UserDefaults-backed pairing writes must not block the network callback
    // queue. SwiftUI reads the same registry while rebuilding the menu.
    private let pairingPersistenceQueue = DispatchQueue(
        label: "app.mackvm.pairing.persistence",
        qos: .utility
    )

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

    func seamlessControlAuthorized(for peerID: UUID) -> Bool {
        registry.seamlessControlAuthorized(for: peerID)
    }

    @discardableResult
    func updateSeamlessControlAuthorization(
        for peerID: UUID,
        authorized: Bool
    ) -> Bool {
        guard registry.updateSeamlessControlAuthorization(
            for: peerID,
            authorized: authorized
        ) else {
            return false
        }
        objectWillChange.send()
        return true
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
            guard let self else { return }
            // Repeated bootstrap notifications are harmless. Do not advance
            // the lifecycle epoch when both Bonjour services are already
            // running; doing so would invalidate an in-flight pairing job
            // even though there is nothing to restart.
            guard self.listener == nil || self.browser == nil else {
                return
            }
            self.advanceLifecycleEpoch()
            self.admissionLimiter.reset()
            self.startMissingNetworkServices()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            let outstandingPersistenceJobs = Array(
                self.pairingPersistenceJobs.values
            )
            outstandingPersistenceJobs.forEach {
                self.markPersistenceCancellation(for: $0.requestID)
            }
            self.advanceLifecycleEpoch()
            self.networkRecoveryGeneration &+= 1
            self.networkRecoveryWorkItem?.cancel()
            self.networkRecoveryWorkItem = nil
            self.networkRecoveryAttempt = 0
            self.pendingRetryGeneration &+= 1
            self.pendingRetryWorkItem?.cancel()
            self.pendingRetryWorkItem = nil
            self.pendingRetryPeer = nil
            self.listener?.cancel()
            self.browser?.cancel()
            self.requestConnections.values.forEach { $0.cancel() }
            self.unauthenticatedConnections.values.forEach { $0.cancel() }
            self.listener = nil
            self.browser = nil
            self.listenerIsReady = false
            self.browserIsReady = false
            self.requestConnections.removeAll()
            self.unauthenticatedConnections.removeAll()
            self.requestMessages.removeAll()
            self.requestTargets.removeAll()
            self.requestPeerModels.removeAll()
            self.requestForgetGenerations.removeAll()
            self.localContributions.removeAll()
            self.peerCommitments.removeAll()
            self.peerContributions.removeAll()
            self.pendingPairingConfirmationRequestID = nil
            self.locallyAcceptedRequestIDs.removeAll()
            self.remotelyAcceptedRequestIDs.removeAll()
            self.completionSendStartedRequestIDs.removeAll()
            self.locallyCompletedRequestIDs.removeAll()
            self.remotelyCompletedRequestIDs.removeAll()
            self.completionAcknowledgementSendStartedRequestIDs.removeAll()
            self.completionAcknowledgementDeliveredRequestIDs.removeAll()
            self.completionCloseSendStartedRequestIDs.removeAll()
            self.completionCloseDeliveredRequestIDs.removeAll()
            self.completionCloseReceivedRequestIDs.removeAll()
            self.completionCloseAcknowledgementSendStartedRequestIDs.removeAll()
            self.completionCloseAcknowledgementDeliveredRequestIDs.removeAll()
            self.completionCloseAcknowledgementReceivedRequestIDs.removeAll()
            self.completionCloseFinishScheduledRequestIDs.removeAll()
            self.peerSupportsCompletionCloseRequestIDs.removeAll()
            self.locallyAcknowledgedByPeerRequestIDs.removeAll()
            self.pairingPersistenceRecordedRequestIDs.removeAll()
            // Keep persistence jobs and cancellation markers until their
            // utility-queue callbacks reconcile a write that may have raced
            // this stop. Clearing them here could leave a canceled pairing
            // trusted if the worker committed immediately before shutdown.
            let cancelledTrustPeerIDs = Set(
                self.cancelledPersistenceTrustJobsByPeer.keys
            )
            cancelledTrustPeerIDs.forEach {
                self.revokeCancelledPersistenceTrust(for: $0)
            }
            self.peerFinishedSendingRequestIDs.removeAll()
            self.requestPeerDescriptors.removeAll()
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
                self.pendingPairingConfirmation = nil
                self.pairingActivity = .idle
                self.pairingRetryPeer = nil
                self.status = "Discovery stopped"
            }
        }
    }

    /// Starts only the discovery components that are currently missing. A
    /// browser or listener can fail independently after a network transition;
    /// requiring both properties to be nil would otherwise make a later start
    /// a permanent no-op.
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
        guard Self.areNetworkServicesReady(
            listenerPresent: listener != nil,
            browserPresent: browser != nil,
            listenerReady: listenerIsReady,
            browserReady: browserIsReady
        ) else {
            return false
        }
        let recoveredAfterFailure = networkRecoveryAttempt > 0
            || networkRecoveryWorkItem != nil
        networkRecoveryAttempt = 0
        networkRecoveryGeneration &+= 1
        networkRecoveryWorkItem?.cancel()
        networkRecoveryWorkItem = nil
        return recoveredAfterFailure
    }

    static func areNetworkServicesReady(
        listenerPresent: Bool,
        browserPresent: Bool,
        listenerReady: Bool,
        browserReady: Bool
    ) -> Bool {
        listenerPresent && browserPresent && listenerReady && browserReady
    }

    func requestPairing(with peer: DiscoveredPeer) {
        queue.async { [weak self] in
            self?.requestPairingOnQueue(with: peer)
        }
    }

    /// Cancels the current outbound request immediately. This is intentionally
    /// available before a verification code arrives, because a blocked
    /// receiving listener can otherwise leave the initiator in a pending state
    /// until the transport timeout expires.
    func cancelPairing() {
        queue.async { [weak self] in
            guard let self, let requestID = self.activeOutboundRequestID else {
                return
            }
            let peerName = self.requestTargets[requestID]?.name
                ?? self.requestMessages[requestID]?.sender.name
                ?? "peer"
            self.logPairingPhase(
                "user.cancel",
                requestID: requestID,
                peerID: self.peerIDForRequest(requestID),
                detail: "role=initiator"
            )
            self.finish(
                requestID: requestID,
                userCancelledPersistence: true
            )
            self.publishStatus("Pairing with \(peerName) canceled")
        }
    }

    /// Starts a fresh request after clearing any stale outbound attempt. A
    /// caller uses this only for an explicitly selected peer, so retrying does
    /// not silently redirect a request to another Bonjour result.
    func retryPairing(with peer: DiscoveredPeer) {
        queue.async { [weak self] in
            guard let self else { return }
            if let requestID = self.activeOutboundRequestID {
                self.pendingRetryPeer = peer
                self.pendingRetryGeneration &+= 1
                let retryGeneration = self.pendingRetryGeneration
                self.pendingRetryWorkItem?.cancel()
                let fallback = DispatchWorkItem { [weak self] in
                    guard let self,
                          self.pendingRetryGeneration == retryGeneration else {
                        return
                    }
                    self.pendingRetryWorkItem = nil
                    self.startPendingRetryIfReady()
                }
                self.pendingRetryWorkItem = fallback
                // The state callback normally starts the retry as soon as
                // Network.framework reports cancellation. Keep a bounded
                // fallback for platforms that do not deliver a second state
                // callback after an already-cancelled connection.
                self.queue.asyncAfter(
                    deadline: .now() + 1,
                    execute: fallback
                )
                self.logPairingPhase(
                    "user.retry",
                    requestID: requestID,
                    peerID: self.peerIDForRequest(requestID),
                    detail: "role=initiator"
                )
                self.finish(
                    requestID: requestID,
                    userCancelledPersistence: true
                )
            } else {
                self.requestPairingOnQueue(with: peer)
            }
        }
    }

    private func startPendingRetryIfReady() {
        guard activeOutboundRequestID == nil,
              let peer = pendingRetryPeer else {
            return
        }
        pendingRetryPeer = nil
        pendingRetryWorkItem?.cancel()
        pendingRetryWorkItem = nil
        requestPairingOnQueue(with: peer)
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
        // The browser admits peer-to-peer Bonjour results (for example an
        // AWDL route between Macs on Wi-Fi). Use the same transport policy
        // for the follow-up TCP connection; otherwise the M5 Pro can see the
        // Intel Mac but Network.framework cancels the pairing connection
        // before the first signed frame is delivered.
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: peer.endpoint, using: parameters)
        activeOutboundRequestID = request.requestID
        requestConnections[request.requestID] = connection
        requestPeerDescriptors[request.requestID] = peer
        requestMessages[request.requestID] = request
        requestTargets[request.requestID] = peer.identity
        localContributions[request.requestID] = contribution
        requestForgetGenerations.set(
            registry.generation(for: peer.identity.id),
            for: request.requestID
        )
        publishMain {
            $0.pairingRetryPeer = nil
            $0.pairingActivity = .connecting(
                peerID: peer.identity.id,
                peerName: peer.name
            )
        }
        publishStatus(
            "Connecting to \(peer.name)… If macOS asks about the firewall on "
                + "the receiving Mac, allow it, then select Retry pairing."
        )
        logPairingPhase(
            "request.created",
            requestID: request.requestID,
            peerID: peer.identity.id,
            detail: "role=initiator"
        )

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.logPairingPhase(
                    "transport.ready",
                    requestID: request.requestID,
                    peerID: peer.identity.id,
                    detail: "role=initiator"
                )
                self.scheduleTimeout(
                    for: connection,
                    phase: .protocolNegotiation
                )
                self.send(request, over: connection)
                self.receive(on: connection)
                self.publishStatus("Negotiating a security code with \(peer.name)…")
            case .failed(let error):
                guard self.requestConnections[request.requestID] === connection
                else { return }
                MacKVMLogger.pairing.error(
                    "phase=transport.failed request=\(MacKVMLogger.short(request.requestID), privacy: .public) peer=\(MacKVMLogger.short(peer.identity.id), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
                let wasPersisted = self.pairingPersistenceRecordedRequestIDs
                    .contains(request.requestID)
                self.finish(requestID: request.requestID)
                if !wasPersisted {
                    self.publishRetryAvailable(for: peer)
                    self.publishStatus(
                        self.pairingTransportFailureMessage(
                            peerName: peer.name,
                            detail: error.localizedDescription
                        )
                    )
                }
            case .cancelled:
                self.logPairingPhase(
                    "transport.cancelled",
                    requestID: request.requestID,
                    peerID: peer.identity.id,
                    detail: "role=initiator"
                )
                let wasTracked = self.requestConnections[request.requestID] != nil
                let wasPersisted = self.pairingPersistenceRecordedRequestIDs
                    .contains(request.requestID)
                self.finish(requestID: request.requestID)
                if wasTracked, !wasPersisted {
                    self.publishRetryAvailable(for: peer)
                    self.publishStatus(
                        self.pairingTransportFailureMessage(
                            peerName: peer.name,
                            detail: "pairing connection canceled"
                        )
                    )
                }
            case .waiting(let error):
                self.logPairingPhase(
                    "transport.waiting",
                    requestID: request.requestID,
                    peerID: peer.identity.id,
                    detail: "role=initiator error=\(error.localizedDescription)"
                )
                self.publishStatus(
                    "Waiting for \(peer.name)… If the receiving Mac shows a "
                        + "firewall prompt, allow it, then select Retry pairing."
                )
            default:
                break
            }
        }
        scheduleTimeout(for: connection, phase: .outboundTransport)
        connection.start(queue: queue)
    }

    func respond(to pending: PendingPairingRequest, accepted: Bool) {
        queue.async { [weak self] in
            self?.respondOnQueue(to: pending, accepted: accepted)
        }
    }

    /// Confirms the verification code shown after the initiator receives the
    /// responder's contribution. This is intentionally a separate user action
    /// from pressing Pair: Bonjour exposes identity metadata to local
    /// advertisers, while the code comparison authenticates the physical
    /// responder the user intended to pair with.
    func confirmPairing(requestID: UUID) {
        queue.async { [weak self] in
            self?.confirmPairingOnQueue(requestID: requestID, accepted: true)
        }
    }

    func declinePairing(requestID: UUID) {
        queue.async { [weak self] in
            self?.confirmPairingOnQueue(requestID: requestID, accepted: false)
        }
    }

    private func confirmPairingOnQueue(
        requestID: UUID,
        accepted: Bool
    ) {
        guard activeOutboundRequestID == requestID,
              let connection = requestConnections[requestID],
              let request = requestMessages[requestID],
              let peer = requestTargets[requestID],
              pendingPairingConfirmationRequestID == requestID else {
            logPairingPhase(
                "user.confirm.expired",
                requestID: requestID,
                detail: accepted ? "accepted=true" : "accepted=false"
            )
            publishStatus("The pairing confirmation has expired")
            return
        }
        logPairingPhase(
            accepted ? "user.confirm.accept" : "user.confirm.decline",
            requestID: requestID,
            peerID: peer.id,
            detail: "role=initiator"
        )
        let decision = PairingEnvelope.decision(
            to: request,
            from: identity,
            accepted: accepted,
            senderModel: localModel
        )
        send(decision, over: connection) { [weak self, weak connection] sent in
            guard let self,
                  let connection,
                  self.requestConnections[requestID] === connection else {
                return
            }
            guard sent else {
                self.logPairingPhase(
                    "decision.send.failed",
                    requestID: requestID,
                    peerID: peer.id,
                    detail: "role=initiator"
                )
                self.finish(requestID: requestID)
                return
            }
            self.logPairingPhase(
                "decision.send.confirmed",
                requestID: requestID,
                peerID: peer.id,
                detail: "role=initiator"
            )
            guard accepted else {
                self.finish(requestID: requestID)
                return
            }
        }
        if accepted {
            locallyAcceptedRequestIDs.insert(requestID)
            // Network.framework preserves send order on this connection. Do
            // not make the completion exchange wait for the local
            // contentProcessed callback; the peer's signed decision remains
            // the proof that the acceptance crossed the stream.
            beginCompletionIfMutuallyAccepted(requestID: requestID)
            publishStatus(
                remotelyAcceptedRequestIDs.contains(requestID)
                    ? "Code confirmed; completing pairing with "
                        + peer.name + "…"
                    : "Code confirmed; waiting for " + peer.name
                        + " to accept…"
            )
        } else {
            publishStatus("Pairing declined")
        }
        pendingPairingConfirmationRequestID = nil
        publishMain {
            $0.pendingPairingConfirmation = nil
            $0.activeVerificationCode = nil
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

        logPairingPhase(
            accepted ? "user.accept" : "user.decline",
            requestID: pending.id,
            peerID: pending.peer.id,
            detail: "role=responder"
        )

        let response = PairingEnvelope.decision(
            to: request,
            from: identity,
            accepted: accepted,
            senderModel: localModel
        )
        send(response, over: connection) { [weak self] sent in
            guard let self else { return }
            guard sent else {
                self.logPairingPhase(
                    "decision.send.failed",
                    requestID: pending.id,
                    peerID: pending.peer.id,
                    detail: "role=responder"
                )
                self.finish(requestID: pending.id)
                self.publishStatus(
                    self.pairingTransportFailureMessage(
                        peerName: pending.peer.name,
                        detail: "pairing response failed"
                    )
                )
                return
            }
            self.logPairingPhase(
                "decision.send.confirmed",
                requestID: pending.id,
                peerID: pending.peer.id,
                detail: "role=responder"
            )
            if !accepted {
                self.finish(requestID: pending.id)
            }
        }
        if accepted {
            // The user action is the local acceptance. Do not make the
            // handshake depend on Network.framework's contentProcessed
            // callback, which may be delayed while the peer is sending its
            // decision at the same time. A failed send still tears down the
            // request above, and persistence remains gated by the peer's
            // signed decision, both completions, and acknowledgement.
            locallyAcceptedRequestIDs.insert(pending.id)
            beginCompletionIfMutuallyAccepted(requestID: pending.id)
        }
        removePendingRequest(id: pending.id)
        publishStatus(
            accepted
                ? "Accepted here; completing pairing with \(pending.peer.name)…"
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
            self.cancelledPersistenceTrustJobsByPeer.removeValue(
                forKey: peerID
            )
            self.latestSuccessfulPersistenceRequestIDsByPeer.removeValue(
                forKey: peerID
            )
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
        listenerIsReady = false
        do {
            // Bonjour browsing and outbound pairing both allow AWDL/peer-to-peer
            // routes. The listener must opt in as well, or the discovered
            // peer can cancel the incoming pairing connection before ready.
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
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
                guard let self, let listener, self.listener === listener else {
                    return
                }
                switch state {
                case .ready:
                    self.listenerIsReady = true
                    self.noteNetworkServiceReady()
                    self.publishStatus("Ready on the local network")
                case .failed(let error):
                    self.listenerIsReady = false
                    let retryPeer = self.activeOutboundPeer()
                    let hadPairing = self
                        .cancelUnfinishedPairingsForNetworkFailure()
                    self.publishStatus(
                        hadPairing
                            ? self.pairingNetworkFailureMessage(
                                detail: error.localizedDescription
                            )
                            : "Listening failed: \(error.localizedDescription)"
                    )
                    if hadPairing, let retryPeer {
                        self.publishRetryAvailable(for: retryPeer)
                    }
                    self.listener?.cancel()
                    self.listener = nil
                    self.scheduleNetworkRecovery()
                case .waiting(let error):
                    self.listenerIsReady = false
                    self.publishStatus(
                        "Incoming pairing is waiting for the local network or "
                            + "firewall approval: \(error.localizedDescription)"
                    )
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
            listenerIsReady = false
            _ = cancelUnfinishedPairingsForNetworkFailure()
            publishStatus("Could not start listener: \(error.localizedDescription)")
            scheduleNetworkRecovery()
        }
    }

    private func startBrowser() {
        browserIsReady = false
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
            guard let self, let browser, self.browser === browser else {
                return
            }
            switch state {
            case .ready:
                self.browserIsReady = true
                if self.noteNetworkServiceReady() {
                    self.publishStatus("Discovery recovered on the local network")
                }
            case .failed(let error):
                self.browserIsReady = false
                let retryPeer = self.activeOutboundPeer()
                let hadPairing = self
                    .cancelUnfinishedPairingsForNetworkFailure()
                self.publishStatus(
                    hadPairing
                        ? self.pairingNetworkFailureMessage(
                            detail: error.localizedDescription
                        )
                        : "Discovery failed: \(error.localizedDescription)"
                )
                if hadPairing, let retryPeer {
                    self.publishRetryAvailable(for: retryPeer)
                }
                self.browser = nil
                self.scheduleNetworkRecovery()
            case .waiting:
                self.browserIsReady = false
            default:
                break
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
            MacKVMLogger.pairing.error(
                "phase=transport.rejected reason=admission-limit"
            )
            connection.cancel()
            return
        }
        unauthenticatedConnections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                self.logPairingPhase(
                    "transport.ready",
                    detail: "role=responder"
                )
                self.scheduleTimeout(for: connection, phase: .inboundTransport)
                self.receive(on: connection)
            case .failed, .cancelled:
                self.logPairingPhase(
                    "transport.closed",
                    detail: "role=responder"
                )
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
                    MacKVMLogger.pairing.error(
                        "phase=receive.incomplete-frame connection=\(MacKVMLogger.short(connectionID), privacy: .public)"
                    )
                    publishStatus("Received an incomplete pairing message")
                    connection.cancel()
                    removeConnection(connection)
                }
            } else {
                receive(on: connection)
            }
        } catch PairingWireError.tooManyMessages {
            MacKVMLogger.pairing.error(
                "phase=receive.too-many-messages connection=\(MacKVMLogger.short(connectionID), privacy: .public)"
            )
            publishStatus("Received too many pairing messages in one delivery")
            connection.cancel()
            removeConnection(connection)
        } catch {
            MacKVMLogger.pairing.error(
                "phase=receive.invalid-frame connection=\(MacKVMLogger.short(connectionID), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            publishStatus("Received an invalid pairing message")
            connection.cancel()
            removeConnection(connection)
        }
    }

    private func handle(_ message: PairingEnvelope, on connection: NWConnection) {
        logPairingPhase(
            "receive.\(message.kind.rawValue)",
            requestID: message.requestID,
            peerID: message.sender.id
        )
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
                logPairingPhase(
                    "request.rejected",
                    requestID: message.requestID,
                    peerID: message.sender.id,
                    detail: "reason=\(statusMessage(for: decision))"
                )
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
            scheduleTimeout(
                for: connection,
                phase: .protocolNegotiation
            )
            requestConnections[message.requestID] = connection
            requestMessages[message.requestID] = message
            if message.supportsCompletionClose == true {
                peerSupportsCompletionCloseRequestIDs.insert(message.requestID)
            }
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
            logPairingPhase(
                "request.accepted",
                requestID: message.requestID,
                peerID: message.sender.id,
                detail: "role=responder"
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
            recordCompletionCloseCapability(
                from: message,
                for: expectedPeer,
                on: connection
            )
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
            logPairingPhase(
                "reveal.sent",
                requestID: message.requestID,
                peerID: expectedPeer.id,
                detail: "role=initiator"
            )
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
            guard peerContributions[message.requestID] == nil else {
                // A duplicate reveal must not restart the user-decision
                // deadline or keep an unpaired request occupying its slot.
                logPairingPhase(
                    "reveal.duplicate",
                    requestID: message.requestID,
                    peerID: message.sender.id,
                    detail: "role=responder"
                )
                return
            }
            recordCompletionCloseCapability(
                from: message,
                for: request.sender,
                on: connection
            )
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
            // The request is now validated as a complete protocol message
            // and the responder's Accept action is visible to the user.
            // Give that action its own bounded window instead of consuming
            // the remainder of the transport handshake deadline.
            scheduleTimeout(for: connection, phase: .userDecision)
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
            logPairingPhase(
                "confirmation.sent",
                requestID: message.requestID,
                peerID: message.sender.id,
                detail: "role=responder"
            )

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
            guard peerContributions[message.requestID] == nil else {
                // A duplicate confirmation must not restart the user-decision
                // deadline after the initiator has already entered this
                // phase.
                logPairingPhase(
                    "confirmation.duplicate",
                    requestID: message.requestID,
                    peerID: expectedPeer.id,
                    detail: "role=initiator"
                )
                return
            }
            recordCompletionCloseCapability(
                from: message,
                for: expectedPeer,
                on: connection
            )
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
            // The initiator's Confirm code action is a separate user-visible
            // phase. Start a fresh bounded decision window when the prompt is
            // published, rather than inheriting time already spent on the
            // network exchange and the responder's prompt.
            scheduleTimeout(for: connection, phase: .userDecision)
            pendingPairingConfirmationRequestID = message.requestID
            logPairingPhase(
                "confirmation.received.awaiting-user",
                requestID: message.requestID,
                peerID: expectedPeer.id,
                detail: "role=initiator"
            )
            publishMain {
                $0.activeVerificationCode = verificationCode
                $0.pendingPairingConfirmation = PendingPairingConfirmation(
                    id: message.requestID,
                    peer: expectedPeer,
                    verificationCode: verificationCode
                )
                $0.pairingActivity = .awaitingConfirmation(
                    peerID: expectedPeer.id,
                    peerName: expectedPeer.name
                )
            }
            publishStatus(
                "Compare security code \(verificationCode) with \(expectedPeer.name), then confirm…"
            )

        case .decision:
            guard let peer = validatedSessionPeer(for: message),
                  peerContributions[message.requestID] != nil else {
                rejectUnexpected(message, on: connection)
                return
            }
            recordCompletionCloseCapability(
                from: message,
                for: peer,
                on: connection
            )
            if let model = message.senderModel {
                // validatedSessionPeer binds this model to the paired peer.
                requestPeerModels[message.requestID] = model
            }
            guard message.accepted == true else {
                logPairingPhase(
                    "decision.rejected-by-peer",
                    requestID: message.requestID,
                    peerID: peer.id
                )
                publishStatus("\(message.sender.name) declined pairing")
                finish(requestID: message.requestID)
                return
            }
            remotelyAcceptedRequestIDs.insert(message.requestID)
            logPairingPhase(
                "decision.accepted-by-peer",
                requestID: message.requestID,
                peerID: peer.id
            )
            if locallyAcceptedRequestIDs.contains(message.requestID) {
                beginCompletionIfMutuallyAccepted(
                    requestID: message.requestID
                )
            } else {
                publishStatus(
                    "\(peer.name) confirmed; accept this request when the code matches"
                )
            }

        case .completion:
            guard let peer = validatedSessionPeer(for: message),
                  peerContributions[message.requestID] != nil,
                  locallyAcceptedRequestIDs.contains(message.requestID),
                  remotelyAcceptedRequestIDs.contains(message.requestID) else {
                rejectUnexpected(message, on: connection)
                return
            }
            recordCompletionCloseCapability(
                from: message,
                for: peer,
                on: connection
            )
            if let model = message.senderModel {
                // validatedSessionPeer binds this model to the paired peer.
                requestPeerModels[message.requestID] = model
            }
            remotelyCompletedRequestIDs.insert(message.requestID)
            logPairingPhase(
                "completion.received",
                requestID: message.requestID,
                peerID: peer.id
            )
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
            recordCompletionCloseCapability(
                from: message,
                for: peer,
                on: connection
            )
            if let model = message.senderModel {
                // validatedSessionPeer binds this model to the paired peer.
                requestPeerModels[message.requestID] = model
            }
            // Receiving this signed acknowledgement proves that the peer
            // received our completion, even if Network.framework has not yet
            // delivered the local contentProcessed callback.
            locallyCompletedRequestIDs.insert(message.requestID)
            locallyAcknowledgedByPeerRequestIDs.insert(message.requestID)
            logPairingPhase(
                "completion.acknowledgement.received",
                requestID: message.requestID,
                peerID: peer.id
            )
            beginCompletionCloseIfReady(requestID: message.requestID)
            completePairingIfTransportConfirmed(
                with: peer,
                requestID: message.requestID
            )

        case .completionClose:
            guard let peer = validatedSessionPeer(for: message),
                  completionSendStartedRequestIDs.contains(message.requestID),
                  remotelyCompletedRequestIDs.contains(message.requestID),
                  !isCompletionCloser(peerID: peer.id) else {
                rejectUnexpected(message, on: connection)
                return
            }
            recordCompletionCloseCapability(
                from: message,
                for: peer,
                on: connection
            )
            // The close barrier is ordered after the sender's acknowledgement
            // on the same TCP stream. Receiving it therefore proves that our
            // acknowledgement reached the peer before it closed its side.
            completionCloseReceivedRequestIDs.insert(message.requestID)
            logPairingPhase(
                "completion.close.received",
                requestID: message.requestID,
                peerID: peer.id
            )
            beginCompletionCloseAcknowledgement(requestID: message.requestID)
            completePairingIfTransportConfirmed(
                with: peer,
                requestID: message.requestID
            )

        case .completionCloseAcknowledgement:
            guard let peer = validatedSessionPeer(for: message),
                  completionCloseSendStartedRequestIDs.contains(
                      message.requestID
                  ),
                  isCompletionCloser(peerID: peer.id) else {
                rejectUnexpected(message, on: connection)
                return
            }
            recordCompletionCloseCapability(
                from: message,
                for: peer,
                on: connection
            )
            if let model = message.senderModel {
                requestPeerModels[message.requestID] = model
            }
            // This is the peer-originated proof that the higher-ID side
            // consumed our close barrier. Local contentProcessed on the close
            // frame is intentionally not sufficient to persist trust.
            completionCloseAcknowledgementReceivedRequestIDs.insert(
                message.requestID
            )
            logPairingPhase(
                "completion.close.acknowledgement.received",
                requestID: message.requestID,
                peerID: peer.id
            )
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
        reportsError: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        logPairingPhase(
            "send.begin.\(message.kind.rawValue)",
            requestID: message.requestID,
            peerID: message.sender.id,
            detail: isFinal ? "final=true" : "final=false"
        )
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
                        MacKVMLogger.pairing.error(
                            "phase=send.failed kind=\(message.kind.rawValue, privacy: .public) request=\(MacKVMLogger.short(message.requestID), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                        )
                        if reportsError {
                            self?.publishStatus(
                                "Send failed: \(error.localizedDescription)"
                            )
                        }
                    } else {
                        self?.logPairingPhase(
                            "send.delivered.\(message.kind.rawValue)",
                            requestID: message.requestID,
                            peerID: message.sender.id
                        )
                    }
                    completion?(error == nil)
                }
            )
        } catch {
            MacKVMLogger.pairing.error(
                "phase=send.encode-failed kind=\(message.kind.rawValue, privacy: .public) request=\(MacKVMLogger.short(message.requestID), privacy: .public)"
            )
            publishStatus("Could not encode pairing message")
            completion?(false)
        }
    }

    private func hasActivePersistenceJob(
        for peerID: UUID,
        excluding requestID: UUID
    ) -> Bool {
        pairingPersistenceJobs.values.contains {
            $0.peer.id == peerID && $0.requestID != requestID
        }
    }

    /// Rolls back trust written by a cancelled pairing only when no newer
    /// successful write for that peer superseded it. This runs on the
    /// discovery queue, so the registry check and cleanup decision are
    /// serialized with every retry result.
    private func revokeCancelledPersistenceTrust(for peerID: UUID) {
        guard latestSuccessfulPersistenceRequestIDsByPeer[peerID] == nil else {
            cancelledPersistenceTrustJobsByPeer.removeValue(forKey: peerID)
            return
        }
        guard let jobs = cancelledPersistenceTrustJobsByPeer[peerID] else {
            return
        }
        let currentGeneration = registry.generation(for: peerID)
        let currentKey = registry.publicKey(for: peerID)
        guard let matchingJob = jobs.reversed().first(where: {
            $0.expectedRegistryGeneration == currentGeneration
                && currentKey == $0.peer.signingPublicKey
        }) else {
            cancelledPersistenceTrustJobsByPeer.removeValue(forKey: peerID)
            return
        }
        _ = registry.revoke(peerID)
        cancelledPersistenceTrustJobsByPeer.removeValue(forKey: peerID)
        latestSuccessfulPersistenceRequestIDsByPeer.removeValue(forKey: peerID)
        logPairingPhase(
            "pairing.persist.rollback",
            requestID: matchingJob.requestID,
            peerID: peerID,
            detail: "cancelled-retry-failed"
        )
    }

    private func handlePairingPersistenceResult(
        _ job: PairingPersistenceJob,
        saved: Bool
    ) {
        let cancellationRequested = takePersistenceCancellation(
            for: job.requestID
        )
        guard let activeJob = pairingPersistenceJobs[job.requestID],
              activeJob === job else {
            // stop() or a newer lifecycle already retired this job.
            return
        }
        pairingPersistenceJobs.removeValue(forKey: job.requestID)
        let isLatestPersistenceJob =
            latestPairingPersistenceRequestIDsByPeer[job.peer.id]
                == job.requestID
        if isLatestPersistenceJob {
            latestPairingPersistenceRequestIDsByPeer.removeValue(
                forKey: job.peer.id
            )
        }
        if cancellationRequested {
            // If the worker had already completed the write before the user
            // cancellation reached this queue, remove that trust record before
            // publishing anything to SwiftUI or auto-connecting the session.
            // Never revoke a newer retry's record: its persistence request has
            // a different token even when the peer uses the same signing key.
            if saved,
               registry.generation(for: job.peer.id)
                    == job.expectedRegistryGeneration,
               registry.publicKey(for: job.peer.id)
                    == job.peer.signingPublicKey {
                if hasActivePersistenceJob(
                    for: job.peer.id,
                    excluding: job.requestID
                ) {
                    cancelledPersistenceTrustJobsByPeer[
                        job.peer.id,
                        default: []
                    ].append(job)
                } else if latestSuccessfulPersistenceRequestIDsByPeer[
                    job.peer.id
                ] == nil {
                    _ = registry.revoke(job.peer.id)
                    cancelledPersistenceTrustJobsByPeer.removeValue(
                        forKey: job.peer.id
                    )
                }
            } else if isLatestPersistenceJob {
                revokeCancelledPersistenceTrust(for: job.peer.id)
            }
            logPairingPhase(
                "pairing.persist.discarded",
                requestID: job.requestID,
                peerID: job.peer.id,
                detail: "user-cancelled"
            )
            publishStatus("Pairing with \(job.peer.name) canceled")
            return
        }
        logPairingPhase(
            "pairing.persist.returned",
            requestID: job.requestID,
            peerID: job.peer.id,
            detail: "success=\(saved)"
        )

        guard currentLifecycleEpoch() == job.lifecycleEpoch else {
            logPairingPhase(
                "pairing.persist.discarded",
                requestID: job.requestID,
                peerID: job.peer.id,
                detail: "lifecycle-changed"
            )
            return
        }
        guard saved else {
            MacKVMLogger.pairing.error(
                "phase=pairing.persist.failed request=\(MacKVMLogger.short(job.requestID), privacy: .public) peer=\(MacKVMLogger.short(job.peer.id), privacy: .public)"
            )
            publishStatus(
                "Could not save pairing with \(job.peer.name); try Pair again"
            )
            if isLatestPersistenceJob
                && latestSuccessfulPersistenceRequestIDsByPeer[job.peer.id]
                    == nil {
                revokeCancelledPersistenceTrust(for: job.peer.id)
            }
            // A failed durable write is terminal for this pairing attempt. Do
            // not leave the connection/request tracked until the 60-second
            // timeout, otherwise the UI appears stuck and the next attempt is
            // rejected as a duplicate active request.
            finish(requestID: job.requestID)
            return
        }

        // A Forget action advances the registry generation synchronously. Do
        // not publish a pairing or auto-connect if that happened while the
        // background write was in flight.
        guard registry.generation(for: job.peer.id)
                == job.expectedRegistryGeneration,
              registry.publicKey(for: job.peer.id)
                == job.peer.signingPublicKey else {
            logPairingPhase(
                "pairing.persist.discarded",
                requestID: job.requestID,
                peerID: job.peer.id,
                detail: "trust-generation-changed"
            )
            return
        }

        latestSuccessfulPersistenceRequestIDsByPeer[job.peer.id] = job.requestID
        cancelledPersistenceTrustJobsByPeer.removeValue(forKey: job.peer.id)

        let requestIsTracked = requestTargets[job.requestID]?.id
                == job.peer.id
            || requestMessages[job.requestID]?.sender.id == job.peer.id
        if requestIsTracked {
            pairingPersistenceRecordedRequestIDs.insert(job.requestID)
        }
        logPairingPhase(
            "pairing.persisted",
            requestID: job.requestID,
            peerID: job.peer.id
        )
        let peerID = job.peer.id
        let signingPublicKey = job.peer.signingPublicKey
        publishMain { service in
            // Re-check at publication time so a Forget action queued between
            // the background write and this main-queue update cannot leave a
            // stale green Paired indicator behind.
            guard self.registry.publicKey(for: peerID) == signingPublicKey else {
                return
            }
            service.pairedPeerIDs.insert(peerID)
            if service.pairingActivity.peerID == peerID {
                service.activeVerificationCode = nil
                service.pendingPairingConfirmation = nil
                service.pairingActivity = .idle
            }
        }
        onPairingCompleted?(peerID, job.expectedRegistryGeneration)
        publishStatus("Paired with \(job.peer.name)")

        guard requestIsTracked else { return }
        guard peerSupportsCompletionCloseRequestIDs.contains(job.requestID)
        else {
            // This should be unreachable because PairingWireCodec rejects a
            // missing capability before the state machine sees a frame. Keep
            // the defensive check so a future decoder cannot publish trust
            // through a weaker EOF path.
            finish(requestID: job.requestID, cancelConnection: true)
            return
        }
        if peerFinishedSendingRequestIDs.contains(job.requestID) {
            // EOF was observed before the persistence callback. No second EOF
            // will arrive, so release the completed request now while leaving
            // the already-graceful transport close untouched.
            logPairingPhase(
                "pairing.persist.cleanup-after-eof",
                requestID: job.requestID,
                peerID: peerID
            )
            finish(requestID: job.requestID, cancelConnection: false)
            return
        }
        if isCompletionCloser(peerID: peerID) {
            // The lower-ID side has received the peer-originated receipt;
            // keep the stream alive briefly so the higher-ID side can observe
            // a successful contentProcessed callback for its non-final
            // receipt before we cancel it.
            scheduleCompletionCloseFinish(requestID: job.requestID)
        } else {
            // Keep the higher-ID side tracked until the lower side receives
            // the receipt and cancels.
        }
    }

    private func finish(
        requestID: UUID,
        cancelConnection: Bool = true,
        userCancelledPersistence: Bool = false
    ) {
        if userCancelledPersistence,
           pairingPersistenceJobs[requestID] != nil,
           !pairingPersistenceRecordedRequestIDs.contains(requestID) {
            markPersistenceCancellation(for: requestID)
        }
        logPairingPhase(
            "request.finish",
            requestID: requestID,
            peerID: peerIDForRequest(requestID),
            detail: "cancelConnection=\(cancelConnection) persisted=\(pairingPersistenceRecordedRequestIDs.contains(requestID))"
        )
        if activeOutboundRequestID == requestID {
            activeOutboundRequestID = nil
            pendingPairingConfirmationRequestID = nil
            publishMain {
                $0.activeVerificationCode = nil
                $0.pendingPairingConfirmation = nil
                $0.pairingActivity = .idle
            }
        }
        if let connection = requestConnections.removeValue(
            forKey: requestID
        ) {
            cleanup(connection)
            if cancelConnection {
                if pendingRetryPeer != nil {
                    connection.stateUpdateHandler = { [weak self] state in
                        let ended: Bool
                        switch state {
                        case .cancelled, .failed:
                            ended = true
                        default:
                            ended = false
                        }
                        guard ended else {
                            return
                        }
                        self?.queue.async { [weak self] in
                            self?.startPendingRetryIfReady()
                        }
                    }
                }
                connection.cancel()
            }
        }
        requestMessages.removeValue(forKey: requestID)
        requestPeerDescriptors.removeValue(forKey: requestID)
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
        completionAcknowledgementDeliveredRequestIDs.remove(requestID)
        completionCloseSendStartedRequestIDs.remove(requestID)
        completionCloseDeliveredRequestIDs.remove(requestID)
        completionCloseReceivedRequestIDs.remove(requestID)
        completionCloseAcknowledgementSendStartedRequestIDs.remove(requestID)
        completionCloseAcknowledgementDeliveredRequestIDs.remove(requestID)
        completionCloseAcknowledgementReceivedRequestIDs.remove(requestID)
        completionCloseFinishScheduledRequestIDs.remove(requestID)
        peerSupportsCompletionCloseRequestIDs.remove(requestID)
        locallyAcknowledgedByPeerRequestIDs.remove(requestID)
        pairingPersistenceRecordedRequestIDs.remove(requestID)
        peerFinishedSendingRequestIDs.remove(requestID)
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
        requestIDs.forEach {
            logPairingPhase(
                "transport.eof",
                requestID: $0,
                peerID: peerIDForRequest($0)
            )
        }
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
            peerFinishedSendingRequestIDs.insert(requestID)
            guard remotelyCompletedRequestIDs.contains(requestID),
                  let peer = requestTargets[requestID]
                    ?? requestMessages[requestID]?.sender else {
                finish(requestID: requestID)
                continue
            }
            completePairingIfTransportConfirmed(
                with: peer,
                requestID: requestID
            )
            if requestConnections[requestID] != nil {
                if pairingPersistenceRecordedRequestIDs.contains(requestID) {
                    // The deterministic close barrier has already completed
                    // the signed exchange. Leave the graceful FIN alone; do
                    // not issue a second cancellation from the EOF callback.
                    finish(requestID: requestID, cancelConnection: false)
                } else if peerSupportsCompletionCloseRequestIDs.contains(
                    requestID
                ) {
                    if pairingPersistenceRecordedRequestIDs.contains(requestID)
                        || completionCloseAcknowledgementDeliveredRequestIDs
                            .contains(requestID) {
                        // The signed close exchange is complete (or
                        // persistence failed after the peer consumed it).
                        // Leave the graceful FIN alone; do not issue a second
                        // cancellation from the EOF callback.
                        finish(requestID: requestID, cancelConnection: false)
                    } else {
                        // Keep the request alive until the higher-ID side's
                        // signed close acknowledgement is accepted locally.
                        // Releasing it here would race that callback and lose
                        // the only peer-originated receipt proof.
                        continue
                    }
                } else {
                    // A current frame without the authenticated capability
                    // must never enter the weaker acknowledgement/EOF path.
                    // The wire codec normally rejects this before it reaches
                    // the state machine; this defensive branch just releases
                    // the transport without persisting trust.
                    finish(requestID: requestID)
                }
            }
        }
    }

    private func cleanup(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        connectionTimeouts.removeValue(forKey: connectionID)?.cancel()
        receiveBuffers.removeValue(forKey: connectionID)
        unauthenticatedConnections.removeValue(forKey: connectionID)
    }

    /// A listener/browser failure can leave Network.framework's connection
    /// state callback delayed while the Bonjour service is being recreated.
    /// Release unfinished requests here so the next Pair action is not forced
    /// to wait for the normal handshake timeout.
    @discardableResult
    private func cancelUnfinishedPairingsForNetworkFailure() -> Bool {
        let requestIDs = requestConnections.keys.filter {
            !pairingPersistenceRecordedRequestIDs.contains($0)
                && pairingPersistenceJobs[$0] == nil
        }
        let hadConnections = !requestIDs.isEmpty
            || requestConnections.keys.contains {
                pairingPersistenceJobs[$0] != nil
            }
            || !unauthenticatedConnections.isEmpty
        requestIDs.forEach { finish(requestID: $0) }
        unauthenticatedConnections.values.forEach { $0.cancel() }
        unauthenticatedConnections.removeAll()
        return hadConnections
    }

    private func pairingTransportFailureMessage(
        peerName: String,
        detail: String
    ) -> String {
        "Could not reach \(peerName) (\(detail)). Allow incoming connections "
            + "on the receiving Mac in macOS Firewall, then select Retry pairing."
    }

    private func pairingNetworkFailureMessage(detail: String) -> String {
        "Pairing network stopped (\(detail)). Allow incoming connections on "
            + "the receiving Mac in macOS Firewall, then select Retry pairing."
    }

    private func publishRetryAvailable(for peer: DiscoveredPeer) {
        publishMain {
            $0.pairingRetryPeer = peer
            $0.pairingActivity = .retryAvailable(
                peerID: peer.identity.id,
                peerName: peer.name
            )
        }
    }

    private func scheduleTimeout(
        for connection: NWConnection,
        phase: PairingTimeoutPhase
    ) {
        let connectionID = ObjectIdentifier(connection)
        connectionTimeouts.removeValue(forKey: connectionID)?.cancel()
        let seconds = PairingTimeoutPolicy.duration(for: phase)

        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection else { return }
            guard self.isTracked(connection) else {
                return
            }
            let outboundRequestID = self.activeOutboundRequestID.flatMap {
                self.requestConnections[$0] === connection ? $0 : nil
            }
            let retryPeer = outboundRequestID.flatMap {
                self.requestPeerDescriptors[$0]
            }
            let wasPersisted = self.pairingPersistenceRecordedRequestIDs
                .contains { requestID in
                    self.requestConnections[requestID] === connection
                }
            if !wasPersisted {
                MacKVMLogger.pairing.error(
                    "phase=pairing.timeout timeoutPhase=\(String(describing: phase), privacy: .public) connection=\(MacKVMLogger.short(connectionID), privacy: .public)"
                )
                self.publishStatus("Pairing request timed out")
            }
            connection.cancel()
            self.removeConnection(connection)
            if !wasPersisted, let retryPeer {
                self.publishRetryAvailable(for: retryPeer)
            }
        }
        connectionTimeouts[connectionID] = timeout
        queue.asyncAfter(deadline: .now() + seconds, execute: timeout)
    }

    private func removePendingRequest(id: UUID) {
        publishMain { $0.pendingRequests.removeAll { $0.id == id } }
    }

    private func publishStatus(_ message: String) {
        publishMain { $0.status = message }
    }

    /// Logs only pairing state and short identifiers. Keep this separate from
    /// `publishStatus`: the user-facing status can contain the six-digit code,
    /// while the diagnostic log must never record it.
    private func logPairingPhase(
        _ phase: String,
        requestID: UUID? = nil,
        peerID: UUID? = nil,
        detail: String? = nil
    ) {
        var fields = [
            "phase=\(phase)",
            "request=\(MacKVMLogger.short(requestID))",
            "peer=\(MacKVMLogger.short(peerID))"
        ]
        if let detail {
            fields.append("detail=\(detail)")
        }
        MacKVMLogger.pairing.info(
            "\(fields.joined(separator: " "), privacy: .public)"
        )
    }

    private func peerIDForRequest(_ requestID: UUID) -> UUID? {
        requestTargets[requestID]?.id
            ?? requestMessages[requestID]?.sender.id
    }

    private func activeOutboundPeer() -> DiscoveredPeer? {
        guard let requestID = activeOutboundRequestID else { return nil }
        return requestPeerDescriptors[requestID]
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
        pairingLifecycleLock.lock()
        defer { pairingLifecycleLock.unlock() }
        lifecycleEpoch.advance()
    }

    private func markPersistenceCancellation(for requestID: UUID) {
        pairingLifecycleLock.lock()
        cancelledPersistenceRequestIDs.insert(requestID)
        pairingLifecycleLock.unlock()
    }

    private func takePersistenceCancellation(for requestID: UUID) -> Bool {
        pairingLifecycleLock.lock()
        defer { pairingLifecycleLock.unlock() }
        return cancelledPersistenceRequestIDs.remove(requestID) != nil
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

    /// Records the close-barrier capability only after the signed sender and
    /// the request's tracked connection have both been validated. Pairing
    /// request IDs are visible before authentication, so writing this bit
    /// before those checks would let a second local connection poison a
    /// legacy peer's completion path.
    private func recordCompletionCloseCapability(
        from message: PairingEnvelope,
        for peer: PeerIdentity,
        on connection: NWConnection
    ) {
        guard message.supportsCompletionClose == true,
              requestConnections[message.requestID] === connection,
              peer.id == message.sender.id,
              peer.signingPublicKey == message.sender.signingPublicKey else {
            return
        }
        peerSupportsCompletionCloseRequestIDs.insert(message.requestID)
    }

    private func beginCompletionIfMutuallyAccepted(requestID: UUID) {
        guard locallyAcceptedRequestIDs.contains(requestID),
              remotelyAcceptedRequestIDs.contains(requestID),
              !completionSendStartedRequestIDs.contains(requestID),
              let connection = requestConnections[requestID],
              let request = requestMessages[requestID] else {
            logPairingPhase(
                "completion.waiting-for-mutual-acceptance",
                requestID: requestID,
                detail: "local=\(locallyAcceptedRequestIDs.contains(requestID)) remote=\(remotelyAcceptedRequestIDs.contains(requestID))"
            )
            return
        }
        // Both signed user decisions are now present. The remaining
        // completion/acknowledgement/close exchange is transport work, so it
        // receives its own short deadline instead of using the user-decision
        // timer that may already be nearly exhausted.
        scheduleTimeout(for: connection, phase: .completion)
        completionSendStartedRequestIDs.insert(requestID)
        logPairingPhase(
            "completion.send.begin",
            requestID: requestID,
            peerID: requestTargets[requestID]?.id
                ?? requestMessages[requestID]?.sender.id
        )
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
                self.logPairingPhase(
                    "completion.send.failed",
                    requestID: requestID,
                    peerID: requestTargets[requestID]?.id
                )
                finish(requestID: requestID)
                return
            }
            guard requestConnections[requestID] != nil else { return }
            locallyCompletedRequestIDs.insert(requestID)
            self.logPairingPhase(
                "completion.send.confirmed",
                requestID: requestID,
                peerID: requestTargets[requestID]?.id
            )
            beginCompletionAcknowledgement(requestID: requestID)
            beginCompletionCloseIfReady(requestID: requestID)
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
            logPairingPhase(
                "completion.acknowledgement.waiting-for-peer-completion",
                requestID: requestID,
                detail: "remoteCompletion=\(remotelyCompletedRequestIDs.contains(requestID))"
            )
            return
        }
        completionAcknowledgementSendStartedRequestIDs.insert(requestID)
        logPairingPhase(
            "completion.acknowledgement.send.begin",
            requestID: requestID,
            peerID: requestTargets[requestID]?.id
                ?? requestMessages[requestID]?.sender.id
        )
        let acknowledgement = PairingEnvelope.completionAcknowledgement(
            to: request,
            from: identity,
            senderModel: localModel
        )
        // Do not mark this frame as Network.framework's final message. Both
        // Macs send the acknowledgement at the same time; using
        // `isComplete: true` on both directions can make one side cancel the
        // TCP stream while the other side's final send is still queued,
        // producing NWError 89 (Operation canceled) and losing the pairing.
        // The application-level acknowledgement exchange below is the safe
        // close barrier: once both acknowledgements have crossed the
        // connection, `completePairingIfTransportConfirmed` closes the idle
        // connection with no outstanding send.
        send(
            acknowledgement,
            over: connection,
            reportsError: true
        ) { [weak self, weak connection] sent in
            guard let self,
                  let connection,
                  self.requestConnections[requestID] === connection else {
                return
            }
            guard sent else {
                self.logPairingPhase(
                    "completion.acknowledgement.send.failed",
                    requestID: requestID,
                    peerID: requestTargets[requestID]?.id
                )
                self.finish(requestID: requestID)
                return
            }
            self.completionAcknowledgementDeliveredRequestIDs.insert(
                requestID
            )
            self.logPairingPhase(
                "completion.acknowledgement.send.confirmed",
                requestID: requestID,
                peerID: self.requestTargets[requestID]?.id
            )
            self.beginCompletionCloseIfReady(requestID: requestID)
            guard let peer = self.requestTargets[requestID]
                    ?? self.requestMessages[requestID]?.sender else {
                self.finish(requestID: requestID)
                return
            }
            self.completePairingIfTransportConfirmed(
                with: peer,
                requestID: requestID
            )
        }
    }

    /// Chooses one side to close the stream so the two close-barrier frames
    /// cannot race. The lower UUID sends `completionClose` only after both
    /// signed completion acknowledgements have been sent and received. The
    /// frame is application-level (not `isComplete: true`), so the higher UUID
    /// can return a signed receipt on the same live connection.
    private func beginCompletionCloseIfReady(requestID: UUID) {
        guard locallyAcceptedRequestIDs.contains(requestID),
              remotelyAcceptedRequestIDs.contains(requestID),
              locallyCompletedRequestIDs.contains(requestID),
              remotelyCompletedRequestIDs.contains(requestID),
              locallyAcknowledgedByPeerRequestIDs.contains(requestID),
              completionAcknowledgementDeliveredRequestIDs.contains(requestID),
              let connection = requestConnections[requestID],
              let request = requestMessages[requestID],
              let peer = requestTargets[requestID]
                ?? requestMessages[requestID]?.sender,
              peerSupportsCompletionCloseRequestIDs.contains(requestID),
              isCompletionCloser(peerID: peer.id),
              !completionCloseSendStartedRequestIDs.contains(requestID) else {
            logPairingPhase(
                "completion.close.waiting",
                requestID: requestID,
                peerID: peerIDForRequest(requestID),
                detail: "localCompletion=\(locallyCompletedRequestIDs.contains(requestID)) remoteCompletion=\(remotelyCompletedRequestIDs.contains(requestID)) peerAck=\(locallyAcknowledgedByPeerRequestIDs.contains(requestID)) localAckSent=\(completionAcknowledgementDeliveredRequestIDs.contains(requestID)) closeCap=\(peerSupportsCompletionCloseRequestIDs.contains(requestID))"
            )
            return
        }
        completionCloseSendStartedRequestIDs.insert(requestID)
        logPairingPhase(
            "completion.close.send.begin",
            requestID: requestID,
            peerID: peer.id
        )
        let close = PairingEnvelope.completionClose(
            to: request,
            from: identity,
            senderModel: localModel
        )
        send(
            close,
            over: connection
        ) { [weak self, weak connection] sent in
            guard let self,
                  let connection,
                  self.requestConnections[requestID] === connection else {
                return
            }
            guard sent else {
                self.logPairingPhase(
                    "completion.close.send.failed",
                    requestID: requestID,
                    peerID: self.peerIDForRequest(requestID)
                )
                self.finish(requestID: requestID)
                return
            }
            self.completionCloseDeliveredRequestIDs.insert(requestID)
            self.logPairingPhase(
                "completion.close.send.confirmed",
                requestID: requestID,
                peerID: peer.id
            )
            guard let peer = self.requestTargets[requestID]
                    ?? self.requestMessages[requestID]?.sender else {
                self.finish(requestID: requestID)
                return
            }
            self.completePairingIfTransportConfirmed(
                with: peer,
                requestID: requestID
            )
        }
    }

    /// The higher-ID participant answers the close barrier with a signed
    /// application-level receipt. Keeping this message non-final lets the
    /// lower-ID sender receive it before either side tears down the stream.
    private func beginCompletionCloseAcknowledgement(requestID: UUID) {
        guard completionCloseReceivedRequestIDs.contains(requestID),
              peerSupportsCompletionCloseRequestIDs.contains(requestID),
              !completionCloseAcknowledgementSendStartedRequestIDs.contains(
                  requestID
              ),
              let connection = requestConnections[requestID],
              let request = requestMessages[requestID] else {
            logPairingPhase(
                "completion.close.acknowledgement.waiting",
                requestID: requestID,
                peerID: peerIDForRequest(requestID),
                detail: "closeReceived=\(completionCloseReceivedRequestIDs.contains(requestID)) closeCap=\(peerSupportsCompletionCloseRequestIDs.contains(requestID))"
            )
            return
        }
        completionCloseAcknowledgementSendStartedRequestIDs.insert(requestID)
        logPairingPhase(
            "completion.close.acknowledgement.send.begin",
            requestID: requestID,
            peerID: peerIDForRequest(requestID)
        )
        let acknowledgement = PairingEnvelope.completionCloseAcknowledgement(
            to: request,
            from: identity,
            senderModel: localModel
        )
        send(
            acknowledgement,
            over: connection,
            // The lower-ID peer waits for a short grace period after receiving
            // this signed receipt before cancelling. Do not surface that
            // expected teardown as a "no response" status.
            reportsError: false
        ) { [weak self, weak connection] sent in
            guard let self,
                  let connection,
                  self.requestConnections[requestID] === connection else {
                return
            }
            guard sent else {
                self.logPairingPhase(
                    "completion.close.acknowledgement.send.failed",
                    requestID: requestID,
                    peerID: self.peerIDForRequest(requestID)
                )
                self.finish(requestID: requestID)
                return
            }
            // The lower-ID peer waits for the grace period above before
            // cancelling. A receipt is accepted only when Network.framework
            // reports successful delivery; a failed send leaves the higher
            // side unpaired.
            self.completionCloseAcknowledgementDeliveredRequestIDs.insert(
                requestID
            )
            self.logPairingPhase(
                "completion.close.acknowledgement.send.confirmed",
                requestID: requestID,
                peerID: self.peerIDForRequest(requestID)
            )
            guard let peer = self.requestTargets[requestID]
                    ?? self.requestMessages[requestID]?.sender else {
                self.finish(requestID: requestID)
                return
            }
            self.completePairingIfTransportConfirmed(
                with: peer,
                requestID: requestID
            )
        }
    }

    private func isCompletionCloser(peerID: UUID) -> Bool {
        identity.id.uuidString < peerID.uuidString
    }

    private func completePairingIfTransportConfirmed(
        with peer: PeerIdentity,
        requestID: UUID
    ) {
        guard let trackedPeer = requestTargets[requestID]
                ?? requestMessages[requestID]?.sender,
              trackedPeer.id == peer.id,
              // A current pairing must prove the signed close capability.
              // Treating a missing marker as a legacy fallback would let an
              // on-path relay strip the extension and recreate the weaker
              // acknowledgement/EOF persistence path.
              peerSupportsCompletionCloseRequestIDs.contains(requestID) else {
            return
        }
        guard !pairingPersistenceRecordedRequestIDs.contains(requestID) else {
            return
        }
        guard pairingPersistenceJobs[requestID] == nil else {
            return
        }
        let completionGuard = PairingCompletionGuard(
            requestID: requestID,
            peerID: trackedPeer.id,
            generation: requestForgetGenerations.current(for: requestID)
        )
        let closeReceived = completionCloseReceivedRequestIDs.contains(
            requestID
        )
        let acknowledgementDelivered =
            completionAcknowledgementDeliveredRequestIDs.contains(requestID)
                || closeReceived
        let closeBarrierConfirmedByPeer: Bool
        if isCompletionCloser(peerID: peer.id) {
            // Lower-ID sender waits for the higher-ID peer's signed receipt.
            // A local close `contentProcessed` callback alone is deliberately
            // not accepted as proof of delivery.
            closeBarrierConfirmedByPeer =
                completionCloseAcknowledgementReceivedRequestIDs.contains(
                    requestID
                )
        } else {
            // The higher-ID side has peer-originated proof when it receives
            // the close barrier, and only persists after its signed receipt
            // has also been accepted locally.
            closeBarrierConfirmedByPeer = closeReceived
                && completionCloseAcknowledgementDeliveredRequestIDs
                    .contains(requestID)
        }
        logPairingPhase(
            "completion.gate",
            requestID: requestID,
            peerID: trackedPeer.id,
            detail: "localAccepted=\(locallyAcceptedRequestIDs.contains(requestID)) remoteAccepted=\(remotelyAcceptedRequestIDs.contains(requestID)) localCompletion=\(locallyCompletedRequestIDs.contains(requestID)) remoteCompletion=\(remotelyCompletedRequestIDs.contains(requestID)) peerAck=\(locallyAcknowledgedByPeerRequestIDs.contains(requestID)) ackDelivered=\(acknowledgementDelivered) closeConfirmed=\(closeBarrierConfirmedByPeer) closeCap=true"
        )
        guard PairingCompletionPolicy.allowsPersistence(
                  localAccepted: locallyAcceptedRequestIDs.contains(requestID),
                  remoteAccepted: remotelyAcceptedRequestIDs.contains(requestID),
                  localCompletionSent: locallyCompletedRequestIDs.contains(requestID),
                  remoteCompletionReceived: remotelyCompletedRequestIDs.contains(requestID),
                  acknowledgementReceived: locallyAcknowledgedByPeerRequestIDs.contains(requestID),
                  acknowledgementDelivered: acknowledgementDelivered,
                  closeBarrierConfirmedByPeer: closeBarrierConfirmedByPeer
              ),
              completionGuard.permits(
                  currentGeneration: registry.generation(for: peer.id),
                  requestID: requestID,
                  peerID: peer.id
              ) else {
            logPairingPhase(
                "completion.gate.blocked",
                requestID: requestID,
                peerID: peer.id
            )
            return
        }
        let job = PairingPersistenceJob(
            requestID: requestID,
            peer: peer,
            expectedRegistryGeneration: completionGuard.generation,
            model: requestPeerModels[requestID],
            lifecycleEpoch: currentLifecycleEpoch()
        )
        pairingPersistenceJobs[requestID] = job
        latestPairingPersistenceRequestIDsByPeer[peer.id] = requestID
        logPairingPhase(
            "pairing.persist.begin",
            requestID: requestID,
            peerID: peer.id,
            detail: "generation=\(completionGuard.generation)"
        )
        pairingPersistenceQueue.async { [weak self] in
            MacKVMLogger.pairing.info(
                "phase=pairing.persist.worker.begin request=\(MacKVMLogger.short(job.requestID), privacy: .public) peer=\(MacKVMLogger.short(job.peer.id), privacy: .public)"
            )
            guard let self else {
                return
            }
            self.pairingLifecycleLock.lock()
            let cancellationRequested = self
                .cancelledPersistenceRequestIDs
                .contains(job.requestID)
            guard self.lifecycleEpoch.current() == job.lifecycleEpoch,
                  !cancellationRequested else {
                self.pairingLifecycleLock.unlock()
                if cancellationRequested {
                    self.queue.async { [weak self] in
                        self?.handlePairingPersistenceResult(job, saved: false)
                    }
                }
                MacKVMLogger.pairing.info(
                    "phase=pairing.persist.worker.skipped request=\(MacKVMLogger.short(job.requestID), privacy: .public) peer=\(MacKVMLogger.short(job.peer.id), privacy: .public) detail=\(cancellationRequested ? "user-cancelled" : "lifecycle-changed", privacy: .public)"
                )
                return
            }
            // This is the only potentially slow part of completion. Keep it
            // away from the Network.framework queue so a UserDefaults/UI
            // lock cannot deadlock the pairing handshake.
            let saved = self.registry.add(
                job.peer,
                ifGeneration: job.expectedRegistryGeneration,
                model: job.model,
                // Pairing success is not published until the pinned key and
                // profile are durable. This work is already off the network
                // queue, so waiting here cannot recreate the UI/UserDefaults
                // deadlock that caused the original completion stall.
                persistImmediately: true
            )
            self.pairingLifecycleLock.unlock()
            MacKVMLogger.pairing.info(
                "phase=pairing.persist.worker.completed request=\(MacKVMLogger.short(job.requestID), privacy: .public) peer=\(MacKVMLogger.short(job.peer.id), privacy: .public) success=\(saved)"
            )
            self.queue.async { [weak self] in
                self?.handlePairingPersistenceResult(job, saved: saved)
            }
        }
    }

    private func scheduleCompletionCloseFinish(requestID: UUID) {
        guard !completionCloseFinishScheduledRequestIDs.contains(requestID)
        else { return }
        completionCloseFinishScheduledRequestIDs.insert(requestID)
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self,
                  self.requestConnections[requestID] != nil,
                  self.pairingPersistenceRecordedRequestIDs.contains(requestID)
            else { return }
            self.finish(requestID: requestID, cancelConnection: true)
        }
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
            removeConnection(connection)
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
