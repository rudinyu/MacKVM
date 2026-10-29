import Combine
import CryptoKit
import Foundation
import MacKVMCore
import Network
import OSLog

struct DiscoveredPeer: Identifiable {
    let id: String
    let identity: PeerIdentity
    let model: String
    let endpoint: NWEndpoint

    var name: String { identity.name }
}

struct PendingPairingRequest: Identifiable {
    /// Local identity for this exact incoming attempt. The wire request ID
    /// can be reused after a connection is retired, while SwiftUI may still
    /// hold the previous prompt value.
    let id: UUID
    let requestID: UUID
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

/// Result of a user-requested, one-shot Local Network connectivity check.
/// `.reachable` proves that this endpoint accepted a fresh TCP connection; it
/// does not claim that macOS granted a global permission state.
enum LocalNetworkCheckResult: Equatable {
    case reachable
    case blocked
    case unconfirmed
    case busy
    case noPeer
    case unavailable
}

enum LocalNetworkCheckDecision: Equatable {
    case wait
    case finish(LocalNetworkCheckResult)
}

enum NetworkServiceComponent: String, CaseIterable, Equatable, Hashable, Sendable {
    case browser
    case listener
}

struct NetworkServiceErrorDiagnostic: Equatable, Sendable {
    let component: NetworkServiceComponent
    let state: String
    let domain: String
    let code: Int

    static func capture(
        component: NetworkServiceComponent,
        state: String,
        error: Error
    ) -> Self {
        let rawError = error as NSError
        let rawCode: Int
        if let networkError = error as? NWError,
           case let .dns(dnsServiceError) = networkError {
            // NWError's NSError bridge does not preserve DNSServiceErrorType
            // on every supported macOS version. Read the payload directly.
            rawCode = Int(dnsServiceError)
        } else {
            rawCode = rawError.code
        }
        return Self(
            component: component,
            state: state,
            domain: rawError.domain,
            code: rawCode
        )
    }

    var supportDescription: String {
        "state=\(state) domain=\(domain) code=\(code)"
    }
}

enum NetworkServiceStatePolicy {
    /// Network.framework carries DNS-SD failures as `NWError.dns`. Compare
    /// the SDK constant directly so generic waiting errors never imply a
    /// Local Network denial.
    static func isLocalNetworkPolicyDenied(_ error: NWError) -> Bool {
        guard case let .dns(dnsError) = error else { return false }
        return dnsError == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
    }

    static func isLocalNetworkAccessDenied(
        error: NWError,
        unsatisfiedReason: NWPath.UnsatisfiedReason?
    ) -> Bool {
        unsatisfiedReason == .localNetworkDenied
            || isLocalNetworkPolicyDenied(error)
    }
}

enum LocalNetworkAccessBlockedPolicy {
    static func isBlocked(by sources: Bool...) -> Bool {
        sources.contains(true)
    }
}

enum LocalNetworkRecoveryGuidance {
    static let localizationKey =
        "Local Network access is blocked. Allow MacKVM in Local Network settings and wait for the automatic retry. If it still fails, quit and reopen MacKVM."

    static var localizedMessage: String {
        NSLocalizedString(
            localizationKey,
            comment: "Local Network access recovery guidance"
        )
    }
}

enum PairingProgressGuidance: Equatable {
    case localNetwork
    case firewall

    static func resolve(localNetworkAccessBlocked: Bool) -> Self {
        localNetworkAccessBlocked ? .localNetwork : .firewall
    }
}

struct PairingTransportLocalNetworkState {
    private(set) var deniedRequestID: UUID?

    var isBlocked: Bool { deniedRequestID != nil }

    mutating func recordDenial(for requestID: UUID) {
        deniedRequestID = requestID
    }

    /// A ready callback may clear a previous denial only when its request is
    /// still the active outbound transport. The service also checks NWConnection
    /// identity and the captured pairing status context before calling this.
    @discardableResult
    mutating func recovered(
        by callbackRequestID: UUID,
        currentRequestID: UUID?
    ) -> Bool {
        guard callbackRequestID == currentRequestID, isBlocked else {
            return false
        }
        deniedRequestID = nil
        return true
    }

    @discardableResult
    mutating func recoveredFromInboundReady(
        connectionIsTracked: Bool
    ) -> Bool {
        guard connectionIsTracked, isBlocked else { return false }
        deniedRequestID = nil
        return true
    }

    @discardableResult
    mutating func recoveredAfterNetworkServicesReady() -> Bool {
        guard isBlocked else { return false }
        deniedRequestID = nil
        return true
    }

    @discardableResult
    mutating func recoveredAfterSuccessfulLocalNetworkProbe() -> Bool {
        guard isBlocked else { return false }
        deniedRequestID = nil
        return true
    }

    mutating func stop() {
        deniedRequestID = nil
    }
}

enum NetworkServiceReadyStatusPolicy {
    static func shouldPublishListenerReady(hasBlockedComponents: Bool) -> Bool {
        !hasBlockedComponents
    }

    static func shouldPublishBrowserRecovered(
        recoveredFromPolicyDenial: Bool,
        recoveredAfterGenericFailure: Bool,
        hasBlockedComponents: Bool
    ) -> Bool {
        !hasBlockedComponents
            && (recoveredFromPolicyDenial || recoveredAfterGenericFailure)
    }
}

enum GeneralNetworkRecoveryPolicy {
    static func componentsToRestart(
        missingComponents: Set<NetworkServiceComponent>,
        blockedComponents: Set<NetworkServiceComponent>
    ) -> [NetworkServiceComponent] {
        NetworkServiceComponent.allCases.filter {
            missingComponents.contains($0) && !blockedComponents.contains($0)
        }
    }
}

/// Pure retry state for DNS-SD policy denials. Each service owns its own
/// blocked/recovery lifecycle, and a `.ready` from a service clears its block
/// only after this state has authorized a new recovery operation for it.
struct NetworkRecoveryRetryBackoff {
    static let intervals: [TimeInterval] = [4, 8, 16, 32, 60]

    private(set) var consecutiveAttempts = 0

    func nextInterval() -> TimeInterval {
        Self.intervals[min(consecutiveAttempts, Self.intervals.count - 1)]
    }

    mutating func recordAttempt() {
        consecutiveAttempts = min(
            consecutiveAttempts + 1,
            Self.intervals.count - 1
        )
    }

    mutating func reset() {
        consecutiveAttempts = 0
    }
}

struct BlockedNetworkRecoveryState {
    static let retryInterval: TimeInterval = 4

    private(set) var blockedComponents = Set<NetworkServiceComponent>()
    private(set) var recoveryOperationsAwaitingReady =
        Set<NetworkServiceComponent>()
    private var retryBackoff = NetworkRecoveryRetryBackoff()

    var isBlocked: Bool { !blockedComponents.isEmpty }

    var hasRetryableComponents: Bool { isBlocked }

    func nextRetryInterval() -> TimeInterval {
        retryBackoff.nextInterval()
    }

    mutating func resetRetryBackoff() {
        retryBackoff.reset()
    }

    mutating func recordPolicyDenial(
        for component: NetworkServiceComponent
    ) {
        blockedComponents.insert(component)
        recoveryOperationsAwaitingReady.remove(component)
    }

    mutating func beginRecoveryAttempts(
        networkServicesStarted: Bool,
        pairingIsInFlight: Bool
    ) -> [NetworkServiceComponent] {
        guard networkServicesStarted, !pairingIsInFlight else { return [] }
        var started: [NetworkServiceComponent] = []
        for component in NetworkServiceComponent.allCases
        where blockedComponents.contains(component) {
            recoveryOperationsAwaitingReady.insert(component)
            started.append(component)
        }
        if !started.isEmpty { retryBackoff.recordAttempt() }
        return started
    }

    @discardableResult
    mutating func recovered(
        component: NetworkServiceComponent
    ) -> Bool {
        guard recoveryOperationsAwaitingReady.remove(component) != nil else {
            return false
        }
        blockedComponents.remove(component)
        retryBackoff.reset()
        return true
    }

    mutating func stop() {
        blockedComponents.removeAll()
        recoveryOperationsAwaitingReady.removeAll()
        retryBackoff.reset()
    }
}

/// The connection-level probe is independent evidence from Bonjour's
/// browser/listener callbacks. A result other than a definitive denial or a
/// successful TCP connection must not erase the last known denial.
struct LocalNetworkProbeBlockedState {
    private(set) var isBlocked = false

    @discardableResult
    mutating func record(_ result: LocalNetworkCheckResult) -> Bool {
        let nextValue: Bool
        switch result {
        case .blocked:
            nextValue = true
        case .reachable:
            nextValue = false
        case .unconfirmed, .busy, .noPeer, .unavailable:
            return false
        }
        guard nextValue != isBlocked else { return false }
        isBlocked = nextValue
        return true
    }

    @discardableResult
    mutating func stop() -> Bool {
        guard isBlocked else { return false }
        isBlocked = false
        return true
    }
}

enum LocalNetworkProbeRecoveryTimerAction: Equatable {
    case none
    case schedule(generation: UInt64)
    case cancel
}

/// Deterministic lifecycle for the separate connection-level recovery timer.
/// DNS-SD component retries have their own state and continue when no peer is
/// currently discovered.
struct LocalNetworkProbeRecoveryState {
    static let retryInterval = BlockedNetworkRecoveryState.retryInterval

    private(set) var generation: UInt64 = 0
    private(set) var timerIsScheduled = false
    private var retryBackoff = NetworkRecoveryRetryBackoff()

    func nextRetryInterval() -> TimeInterval {
        retryBackoff.nextInterval()
    }

    mutating func recordRetryAttempt() {
        retryBackoff.recordAttempt()
    }

    mutating func reconcile(
        isBlocked: Bool,
        networkServicesStarted: Bool,
        hasDiscoveredPeer: Bool
    ) -> LocalNetworkProbeRecoveryTimerAction {
        guard isBlocked, networkServicesStarted, hasDiscoveredPeer else {
            retryBackoff.reset()
            guard timerIsScheduled else { return .none }
            generation &+= 1
            timerIsScheduled = false
            return .cancel
        }
        guard !timerIsScheduled else { return .none }
        generation &+= 1
        timerIsScheduled = true
        return .schedule(generation: generation)
    }

    mutating func beginRetry(generation callbackGeneration: UInt64) -> Bool {
        guard timerIsScheduled, generation == callbackGeneration else {
            return false
        }
        timerIsScheduled = false
        return true
    }

    @discardableResult
    mutating func stop() -> LocalNetworkProbeRecoveryTimerAction {
        generation &+= 1
        retryBackoff.reset()
        guard timerIsScheduled else { return .none }
        timerIsScheduled = false
        return .cancel
    }

    static func shouldStartProbe(
        isBlocked: Bool,
        networkServicesStarted: Bool,
        pairingIsInFlight: Bool,
        hasDiscoveredPeer: Bool,
        probeIsInFlight: Bool
    ) -> Bool {
        isBlocked
            && networkServicesStarted
            && !pairingIsInFlight
            && hasDiscoveredPeer
            && !probeIsInFlight
    }
}

enum LocalNetworkCheckPolicy {
    static func decision(
        for state: NWConnection.State,
        unsatisfiedReason: NWPath.UnsatisfiedReason?
    ) -> LocalNetworkCheckDecision {
        switch state {
        case .ready:
            return .finish(.reachable)
        case .waiting:
            return unsatisfiedReason == .localNetworkDenied
                ? .finish(.blocked)
                : .wait
        case .failed:
            return unsatisfiedReason == .localNetworkDenied
                ? .finish(.blocked)
                : .finish(.unconfirmed)
        case .cancelled:
            return .finish(.unconfirmed)
        case .setup, .preparing:
            return .wait
        @unknown default:
            return .wait
        }
    }

    /// A timer expiry by itself is not evidence of a Local Network denial,
    /// even if the last path snapshot was unsatisfied.
    static func timeoutResult() -> LocalNetworkCheckResult {
        .unconfirmed
    }

    static func acceptsProbeCallback(
        callbackGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        callbackGeneration == currentGeneration
    }

    static func hasPairingInFlight(
        activeOutboundRequest: Bool,
        trackedRequestCount: Int,
        incomingConnectionCount: Int,
        pendingConfirmation: Bool,
        persistenceJobCount: Int,
        hasScheduledRetry: Bool
    ) -> Bool {
        activeOutboundRequest
            || trackedRequestCount > 0
            || incomingConnectionCount > 0
            || pendingConfirmation
            || persistenceJobCount > 0
            || hasScheduledRetry
    }

    static func preferredPeerID(
        requestedPeerID: UUID?,
        pairedPeerIDs: Set<UUID>,
        availablePeerIDs: [UUID]
    ) -> UUID? {
        let available = Set(availablePeerIDs)
        if let requestedPeerID {
            return available.contains(requestedPeerID) ? requestedPeerID : nil
        }
        return availablePeerIDs
            .filter(pairedPeerIDs.contains)
            .sorted { $0.uuidString < $1.uuidString }
            .first
            ?? availablePeerIDs.sorted { $0.uuidString < $1.uuidString }.first
    }

    /// Manual checks rebuild discovery so a click always gets a fresh Bonjour
    /// view. Automatic checks leave a healthy browser alone and refresh only
    /// when it is missing or has not reached `.ready`.
    static func shouldRefreshBrowserForDiscoveryWait(
        isAutomatic: Bool,
        browserExists: Bool,
        browserIsReady: Bool,
        listenerExists: Bool = true
    ) -> Bool {
        !browserExists || (isAutomatic ? !browserIsReady : listenerExists)
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

private struct PairingStatusContext {
    let peerID: UUID
    let expectedGeneration: UInt64
    let expectedSigningPublicKey: Data?
    let suppressesStatus: Bool

    init(
        peerID: UUID,
        expectedGeneration: UInt64,
        expectedSigningPublicKey: Data?,
        suppressesStatus: Bool = false
    ) {
        self.peerID = peerID
        self.expectedGeneration = expectedGeneration
        self.expectedSigningPublicKey = expectedSigningPublicKey
        self.suppressesStatus = suppressesStatus
    }
}

enum PairingStatusPublicationPolicy {
    /// A peer-specific status may be shown only while the same revocation
    /// generation is still current. Completed pairings additionally bind the
    /// status to the same trusted signing key.
    static func allows(
        expectedGeneration: UInt64,
        currentGeneration: UInt64,
        expectedSigningPublicKey: Data?,
        currentSigningPublicKey: Data?
    ) -> Bool {
        expectedGeneration == currentGeneration
            && (expectedSigningPublicKey == nil
                || expectedSigningPublicKey == currentSigningPublicKey)
    }
}

enum PairingContributionPolicy {
    /// Whether an incoming reveal/confirmation should be recorded and should
    /// (re)start the user-decision timeout. A request that already has a
    /// recorded contribution has already entered this phase once; a resent
    /// or duplicated message for the same request must not restart the
    /// decision window or duplicate the pending-request/prompt UI.
    static func shouldRecordContribution(
        existingContribution: Data?
    ) -> Bool {
        existingContribution == nil
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
    private static let networkLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "app.mackvm.MacKVM",
        category: "network-services"
    )

    @Published private(set) var peers: [DiscoveredPeer] = []
    @Published private(set) var pendingRequests: [PendingPairingRequest] = []
    @Published private(set) var pairedPeerIDs: Set<UUID>
    @Published private(set) var failedForgetPeerIDs: Set<UUID> = []
    @Published private(set) var status = "Starting…"
    @Published private(set) var activeVerificationCode: String?
    @Published private(set) var pendingPairingConfirmation:
        PendingPairingConfirmation?
    @Published private(set) var pairingActivity: PairingActivity = .idle
    @Published private(set) var pairingRetryPeer: DiscoveredPeer?
    @Published private(set) var localNetworkAccessBlocked = false
    @Published private(set) var lastBrowserError: NetworkServiceErrorDiagnostic?
    @Published private(set) var lastListenerError: NetworkServiceErrorDiagnostic?

    /// Called after both sides have recorded the signed pairing completion.
    /// The app wires this to the secure-session connector so a user does not
    /// have to rediscover a newly paired Mac and press Connect before using
    /// the shared keyboard. A newly completed pairing enables the receiver's
    /// local seamless-control authorization; an existing peer can opt out in
    /// its paired-device settings and return to per-request Allow actions.
    var onPairingCompleted: ((UUID, UInt64) -> Void)?

    /// Called on the main actor after a fresh peer endpoint accepts a TCP
    /// probe, so a pending secure-session connection can retry without an
    /// open menu or window. The argument identifies the peer whose endpoint
    /// accepted the probe; it is nil when the probe had no captured identity.
    var onLocalNetworkAccessRecovered: (@MainActor (UUID?) -> Void)?

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
    private static let localNetworkCheckTimeout: TimeInterval = 7
    private static let localNetworkDiscoveryWait: TimeInterval = 2
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
    private var networkServicesStarted = false
    private var discoveredPeersByID: [UUID: DiscoveredPeer] = [:]
    private var networkRecoveryWorkItem: DispatchWorkItem?
    private var networkRecoveryAttempt = 0
    private var networkRecoveryGeneration: UInt64 = 0
    private var blockedNetworkRecoveryWorkItem: DispatchWorkItem?
    private var blockedNetworkRecoveryGeneration: UInt64 = 0
    private var blockedNetworkRecoveryState = BlockedNetworkRecoveryState()
    private var localNetworkProbeBlockedState = LocalNetworkProbeBlockedState()
    private var localNetworkProbeRecoveryState = LocalNetworkProbeRecoveryState()
    private var localNetworkProbeRecoveryWorkItem: DispatchWorkItem?
    private let localNetworkAccessStateEpoch = EpochGuard()
    private var pairingTransportLocalNetworkState =
        PairingTransportLocalNetworkState()
    private var requestConnections: [UUID: NWConnection] = [:]
    private var unauthenticatedConnections: [ObjectIdentifier: NWConnection] = [:]
    private var requestMessages: [UUID: PairingEnvelope] = [:]
    // Incoming prompts are bound to a fresh local attempt token. Wire UUIDs
    // identify protocol messages, but are not sufficient to identify a UI
    // consent action after a connection has been replaced.
    private var pendingPairingAttemptTokens: [UUID: UUID] = [:]
    private var consumedPairingAttemptTokens: Set<UUID> = []
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
    // A signed request/reveal can be replayed. Preserve the selected outbound
    // until the user explicitly accepts the incoming collision's fresh code.
    // Admission allows only one such candidate for the selected peer.
    private var provisionalCollisionOutboundRequestIDs: [UUID: UUID] = [:]
    #if DEBUG
    private var beforeTrustRollbackForTesting: (() -> Void)?
    private var nextLocalContributionForTesting: Data?
    private var networkRecoveryMissingComponentsForTesting:
        Set<NetworkServiceComponent>?
    private var networkRecoveryPairingOverrideForTesting: Bool?
    private var networkRecoveryTimersAreManualForTesting = false
    private var networkRecoveryRestartsForTesting: [NetworkServiceComponent] = []
    #endif
    // Retry only after the previous TCP pairing transport has reported its
    // cancellation. Network.framework can deliver that callback after the
    // user taps Retry, while the receiver still has the old sender admission
    // in its request table.
    private var pendingRetryPeer: DiscoveredPeer?
    private var pendingRetryGeneration: UInt64 = 0
    private var pendingRetryWorkItem: DispatchWorkItem?
    private var localNetworkProbeGeneration: UInt64 = 0
    private var localNetworkProbeConnection: NWConnection?
    private var localNetworkProbePeerID: UUID?
    private var localNetworkProbeTimeout: DispatchWorkItem?
    private var localNetworkProbeCompletion:
        ((LocalNetworkCheckResult) -> Void)?
    private var localNetworkProbeIsAutomaticRecovery = false
    private var localNetworkDiscoveryTimeout: DispatchWorkItem?
    private var localNetworkDiscoveryCompletion:
        ((LocalNetworkCheckResult) -> Void)?
    private var localNetworkDiscoveryPreferredPeerID: UUID?
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

    #if DEBUG
    // Install protocol state without starting Bonjour or TCP and exercise the
    // same handler used by decoded, signed network messages.
    func prepareOutboundPairingForTesting(
        with peer: PeerIdentity,
        requestID: UUID,
        pendingRequests: [PairingEnvelope] = []
    ) {
        queue.sync {
            let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            activeOutboundRequestID = requestID
            requestConnections[requestID] = connection
            requestTargets[requestID] = peer
            requestMessages[requestID] = .request(
                from: identity,
                requestID: requestID,
                commitment: Data(repeating: 1, count: SHA256.Digest.byteCount)
            )
            requestForgetGenerations.set(
                registry.generation(for: peer.id), for: requestID
            )
            pendingPairingConfirmationRequestID = requestID
            for pending in pendingRequests {
                requestMessages[pending.requestID] = pending
            }
        }
        activeVerificationCode = "123456"
        pendingPairingConfirmation = PendingPairingConfirmation(
            id: requestID, peer: peer, verificationCode: "123456"
        )
        pairingActivity = .awaitingConfirmation(peerID: peer.id, peerName: peer.name)
        status = "Waiting for code confirmation"
    }

    func setNextLocalContributionForTesting(_ contribution: Data) {
        queue.sync {
            nextLocalContributionForTesting = contribution
        }
    }

    func handleIncomingPairingRequestForTesting(
        _ message: PairingEnvelope
    ) -> (outboundRequestID: UUID?, trackedRequestIDs: Set<UUID>) {
        queue.sync {
            let connection = message.kind == .request
                ? NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
                : requestConnections[message.requestID]
                    ?? NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            if message.kind == .request || requestConnections[message.requestID] == nil {
                unauthenticatedConnections[ObjectIdentifier(connection)] = connection
            }
            handle(message, on: connection)
            return (activeOutboundRequestID, Set(requestMessages.keys))
        }
    }

    func handleIncomingPairingFramesForTesting(
        _ frames: Data
    ) -> (outboundRequestID: UUID?, trackedRequestIDs: Set<UUID>) {
        queue.sync {
            let connection = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            let connectionID = ObjectIdentifier(connection)
            unauthenticatedConnections[connectionID] = connection
            receiveBuffers[connectionID] = frames
            drainBufferedFrames(
                on: connection, connectionEnded: false,
                remainingMessageBudget: Self.maximumPairingMessagesPerReceive
            )
            return (activeOutboundRequestID, Set(requestMessages.keys))
        }
    }

    func waitForQueuedWorkForTesting() {
        queue.sync {}
    }

    func prepareNetworkRecoveryForTesting(
        missingComponents: Set<NetworkServiceComponent>,
        pairingIsInFlight: Bool = false
    ) {
        queue.sync {
            networkServicesStarted = true
            networkRecoveryMissingComponentsForTesting = missingComponents
            networkRecoveryPairingOverrideForTesting = pairingIsInFlight
            networkRecoveryTimersAreManualForTesting = true
        }
    }

    func failNetworkServiceForTesting(
        _ component: NetworkServiceComponent,
        policyDenied: Bool
    ) {
        queue.sync {
            networkRecoveryMissingComponentsForTesting?.insert(component)
            let error: NWError = policyDenied
                ? .dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
                : .posix(.ENETUNREACH)
            if !recordNetworkServiceError(
                component: component,
                state: "failed",
                error: error
            ) {
                scheduleNetworkRecovery()
            }
        }
    }

    func recoverBlockedNetworkServiceForTesting(
        _ component: NetworkServiceComponent
    ) {
        queue.sync {
            _ = blockedNetworkRecoveryState.beginRecoveryAttempts(
                networkServicesStarted: networkServicesStarted,
                pairingIsInFlight: hasPairingInFlightForNetworkCheck
            )
            _ = noteBlockedNetworkServiceReady(component)
            networkRecoveryMissingComponentsForTesting?.remove(component)
        }
    }

    func fireNetworkRecoveryForTesting(generation: UInt64? = nil) {
        queue.sync {
            networkRecoveryWorkItem?.cancel()
            runNetworkRecovery(
                generation: generation ?? networkRecoveryGeneration
            )
        }
    }

    func networkRecoverySnapshotForTesting() -> (
        generalRetryScheduled: Bool,
        blockedRetryScheduled: Bool,
        attempt: Int,
        generation: UInt64,
        restartedComponents: [NetworkServiceComponent],
        missingComponents: Set<NetworkServiceComponent>
    ) {
        queue.sync {
            (
                networkRecoveryWorkItem != nil,
                blockedNetworkRecoveryWorkItem != nil,
                networkRecoveryAttempt,
                networkRecoveryGeneration,
                networkRecoveryRestartsForTesting,
                networkRecoveryMissingComponentsForTesting ?? []
            )
        }
    }

    func recordLocalNetworkProbeResultForTesting(
        _ result: LocalNetworkCheckResult,
        isAutomaticRecovery: Bool = false,
        peerID: UUID? = nil,
        completion: @escaping () -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.recordLocalNetworkProbeResult(
                result,
                isAutomaticRecovery: isAutomaticRecovery,
                peerID: peerID
            )
            DispatchQueue.main.async(execute: completion)
        }
    }

    func finishLocalNetworkProbeForTesting(
        peerID: UUID,
        result: LocalNetworkCheckResult
    ) -> UUID? {
        queue.sync {
            let connection = NWConnection(
                host: "127.0.0.1",
                port: 9,
                using: .tcp
            )
            localNetworkProbeConnection = connection
            localNetworkProbePeerID = peerID
            finishLocalNetworkProbe(
                connection,
                generation: localNetworkProbeGeneration,
                result: result
            )
            return localNetworkProbePeerID
        }
    }

    func pairingRequestStateForTesting() -> (outboundRequestID: UUID?, trackedRequestIDs: Set<UUID>) {
        queue.sync { (activeOutboundRequestID, Set(requestMessages.keys)) }
    }

    func pairingResponseStateForTesting(requestID: UUID) -> (
        locallyAccepted: Bool,
        attemptToken: UUID?
    ) {
        queue.sync {
            (
                locallyAcceptedRequestIDs.contains(requestID),
                pendingPairingAttemptTokens[requestID]
            )
        }
    }

    func finishPairingTransportForTesting(requestID: UUID) {
        queue.sync {
            if let connection = requestConnections[requestID] {
                handlePeerFinishedSending(connection)
            }
        }
    }

    func expirePairingRequestForTesting(requestID: UUID) {
        queue.sync {
            if let connection = requestConnections[requestID] {
                connection.cancel()
                removeConnection(connection)
            }
        }
    }

    func rollbackCancelledPairingPersistenceForTesting(
        peer: PeerIdentity,
        deferredRetryFailure: Bool,
        forgetBeforeRollback: Bool = false
    ) {
        queue.sync {
            let job = PairingPersistenceJob(
                requestID: UUID(), peer: peer,
                expectedRegistryGeneration: registry.generation(for: peer.id),
                model: nil, lifecycleEpoch: currentLifecycleEpoch()
            )
            pairingPersistenceJobs[job.requestID] = job
            latestPairingPersistenceRequestIDsByPeer[peer.id] = job.requestID
            if deferredRetryFailure {
                cancelledPersistenceTrustJobsByPeer[peer.id] = [job]
            } else {
                markPersistenceCancellation(for: job.requestID)
            }
            if forgetBeforeRollback {
                beforeTrustRollbackForTesting = { [weak self] in self?.forget(peer.id) }
            }
            handlePairingPersistenceResult(job, saved: !deferredRetryFailure)
            beforeTrustRollbackForTesting = nil
        }
    }
    #endif

    func pairedPublicKey(for peerID: UUID) -> Data? {
        registry.publicKey(for: peerID)
    }

    func pairedPeerProfile(for peerID: UUID) -> PairedPeerProfile? {
        registry.profile(for: peerID)
    }

    func seamlessControlAuthorized(for peerID: UUID) -> Bool {
        registry.seamlessControlAuthorized(for: peerID)
    }

    func clipboardSyncEnabled(for peerID: UUID) -> Bool {
        registry.clipboardSyncEnabled(for: peerID)
    }

    @discardableResult
    func updateClipboardSyncEnabled(
        for peerID: UUID,
        enabled: Bool
    ) -> Bool {
        guard registry.updateClipboardSyncEnabled(
            for: peerID,
            enabled: enabled
        ) else {
            return false
        }
        objectWillChange.send()
        return true
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
            self.networkServicesStarted = true
            self.scheduleLocalNetworkProbeRecovery()
            // Repeated bootstrap notifications are harmless. Do not advance
            // the lifecycle epoch when both Bonjour services are already
            // running; doing so would invalidate an in-flight pairing job
            // even though there is nothing to restart.
            guard self.listener == nil || self.browser == nil else {
                self.scheduleBlockedNetworkRecovery()
                return
            }
            self.advanceLifecycleEpoch()
            self.admissionLimiter.reset()
            self.startMissingNetworkServices(
                includingBlockedComponents: true
            )
        }
    }

    /// Called for foreground/settings returns and meaningful network changes.
    /// These external opportunities reset policy-recovery delays, but routine
    /// automatic checks intentionally do not.
    func networkEnvironmentDidChange() {
        queue.async { [weak self] in
            self?.resetRecoveryBackoffsAndReschedule()
        }
    }

    /// Performs one bounded TCP reachability check against a peer's existing
    /// Bonjour endpoint. It sends no pairing or session data and cancels as
    /// soon as TCP becomes ready. A successful probe only proves that this
    /// peer endpoint was reachable for this attempt.
    func checkLocalNetworkAccess(
        isAutomatic: Bool = false,
        preferredPeerID: UUID? = nil,
        completion: @escaping (LocalNetworkCheckResult) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(.unavailable) }
                return
            }

            if !isAutomatic {
                self.resetRecoveryBackoffsAndReschedule()
            }

            // A repeated user action replaces the previous probe. The older
            // request gets a terminal result, and its callbacks are fenced by
            // the generation advance in finishLocalNetworkProbe.
            if let previous = self.localNetworkProbeConnection {
                if self.localNetworkProbeIsAutomaticRecovery {
                    self.deliverLocalNetworkCheckResult(
                        .busy,
                        completion: completion
                    )
                    return
                }
                self.finishLocalNetworkProbe(
                    previous,
                    generation: self.localNetworkProbeGeneration,
                    result: .unconfirmed
                )
            } else if self.localNetworkDiscoveryCompletion != nil {
                self.finishLocalNetworkDiscoveryWait(
                    generation: self.localNetworkProbeGeneration,
                    result: .unconfirmed
                )
            }

            guard !self.hasPairingInFlightForNetworkCheck else {
                self.logNetworkCheckDeferredForPairing(reason: "manual-or-automatic-check")
                self.deliverLocalNetworkCheckResult(.busy, completion: completion)
                return
            }
            guard self.networkServicesStarted else {
                self.deliverLocalNetworkCheckResult(
                    .unavailable,
                    completion: completion
                )
                return
            }

            guard let peer = self.localNetworkCheckPeer(
                preferredPeerID: preferredPeerID
            ) else {
                self.waitForLocalNetworkPeer(
                    preferredPeerID: preferredPeerID,
                    isAutomatic: isAutomatic,
                    completion: completion
                )
                return
            }
            self.startLocalNetworkProbe(to: peer, completion: completion)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.networkServicesStarted = false
            self.stopLocalNetworkProbeRecovery()
            if let probe = self.localNetworkProbeConnection {
                self.finishLocalNetworkProbe(
                    probe,
                    generation: self.localNetworkProbeGeneration,
                    result: .unavailable
                )
            } else if self.localNetworkDiscoveryCompletion != nil {
                self.finishLocalNetworkDiscoveryWait(
                    generation: self.localNetworkProbeGeneration,
                    result: .unavailable
                )
            }
            self.localNetworkProbePeerID = nil
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
            self.blockedNetworkRecoveryGeneration &+= 1
            self.blockedNetworkRecoveryWorkItem?.cancel()
            self.blockedNetworkRecoveryWorkItem = nil
            self.blockedNetworkRecoveryState.stop()
            self.localNetworkProbeBlockedState.stop()
            self.localNetworkAccessStateEpoch.advance()
            self.pairingTransportLocalNetworkState.stop()
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
            self.discoveredPeersByID.removeAll()
            self.listenerIsReady = false
            self.browserIsReady = false
            self.requestConnections.removeAll()
            self.unauthenticatedConnections.removeAll()
            self.requestMessages.removeAll()
            self.pendingPairingAttemptTokens.removeAll()
            self.consumedPairingAttemptTokens.removeAll()
            self.requestTargets.removeAll()
            self.provisionalCollisionOutboundRequestIDs.removeAll()
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
                self.localNetworkAccessBlocked = false
                self.status = "Discovery stopped"
            }
        }
    }

    /// Starts only the discovery components that are currently missing. A
    /// browser or listener can fail independently after a network transition;
    /// requiring both properties to be nil would otherwise make a later start
    /// a permanent no-op.
    private func startMissingNetworkServices(
        includingBlockedComponents: Bool
    ) {
        let components = includingBlockedComponents
            ? NetworkServiceComponent.allCases.filter {
                missingNetworkServiceComponents.contains($0)
            }
            : generalNetworkRecoveryComponents

        #if DEBUG
        if networkRecoveryMissingComponentsForTesting != nil {
            for component in components {
                networkRecoveryRestartsForTesting.append(component)
                networkRecoveryMissingComponentsForTesting?.remove(component)
            }
            return
        }
        #endif

        components.forEach(startNetworkService)
    }

    private var missingNetworkServiceComponents: Set<NetworkServiceComponent> {
        #if DEBUG
        if let networkRecoveryMissingComponentsForTesting {
            return networkRecoveryMissingComponentsForTesting
        }
        #endif

        var missing = Set<NetworkServiceComponent>()
        if listener == nil { missing.insert(.listener) }
        if browser == nil { missing.insert(.browser) }
        return missing
    }

    private var generalNetworkRecoveryComponents: [NetworkServiceComponent] {
        GeneralNetworkRecoveryPolicy.componentsToRestart(
            missingComponents: missingNetworkServiceComponents,
            blockedComponents: blockedNetworkRecoveryState.blockedComponents
        )
    }

    private func startNetworkService(_ component: NetworkServiceComponent) {
        switch component {
        case .listener:
            startListener()
        case .browser:
            startBrowser()
        }
    }

    private func refreshBrowserOnQueue() {
        browser?.cancel()
        browser = nil
        discoveredPeersByID.removeAll()
        browserIsReady = false
        scheduleLocalNetworkProbeRecovery()
        startBrowser()
    }

    private func scheduleNetworkRecovery() {
        guard networkServicesStarted,
              !generalNetworkRecoveryComponents.isEmpty,
              networkRecoveryWorkItem == nil else {
            return
        }
        let delay = min(pow(2.0, Double(networkRecoveryAttempt)), 30.0)
        networkRecoveryAttempt = min(networkRecoveryAttempt + 1, 5)
        networkRecoveryGeneration &+= 1
        let recoveryGeneration = networkRecoveryGeneration
        let workItem = DispatchWorkItem { [weak self] in
            self?.runNetworkRecovery(generation: recoveryGeneration)
        }
        networkRecoveryWorkItem = workItem
        #if DEBUG
        if networkRecoveryTimersAreManualForTesting { return }
        #endif
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func runNetworkRecovery(generation: UInt64) {
        guard networkRecoveryGeneration == generation,
              networkRecoveryWorkItem != nil else {
            return
        }
        networkRecoveryWorkItem = nil
        guard networkServicesStarted else { return }
        guard !hasPairingInFlightForNetworkCheck else {
            logNetworkCheckDeferredForPairing(reason: "general-recovery")
            scheduleNetworkRecovery()
            return
        }
        startMissingNetworkServices(includingBlockedComponents: false)
    }

    private func resetRecoveryBackoffsAndReschedule() {
        resetBlockedNetworkRecoveryBackoffAndReschedule()
        resetLocalNetworkProbeRecoveryState()
        scheduleLocalNetworkProbeRecovery()
    }

    private func resetBlockedNetworkRecoveryBackoffAndReschedule() {
        blockedNetworkRecoveryState.resetRetryBackoff()
        blockedNetworkRecoveryGeneration &+= 1
        blockedNetworkRecoveryWorkItem?.cancel()
        blockedNetworkRecoveryWorkItem = nil
        scheduleBlockedNetworkRecovery()
    }

    private func noteNetworkServiceBecameReady(
        _ component: NetworkServiceComponent
    ) -> Bool {
        let recoveredBlockedComponent = noteBlockedNetworkServiceReady(component)
        guard !recoveredBlockedComponent else { return true }

        // A ready callback is an external recovery opportunity even when it
        // belongs to the other Bonjour component. Reset both retry delays and
        // restart any eligible recovery timer at its base interval.
        resetBlockedNetworkRecoveryBackoffAndReschedule()
        resetLocalNetworkProbeRecoveryState()
        scheduleLocalNetworkProbeRecovery()
        return false
    }

    private func resetLocalNetworkProbeRecoveryState() {
        localNetworkProbeRecoveryState.stop()
        localNetworkProbeRecoveryWorkItem?.cancel()
        localNetworkProbeRecoveryWorkItem = nil
    }

    private func scheduleBlockedNetworkRecovery() {
        guard networkServicesStarted,
              blockedNetworkRecoveryState.hasRetryableComponents,
              blockedNetworkRecoveryWorkItem == nil else {
            return
        }
        blockedNetworkRecoveryGeneration &+= 1
        let generation = blockedNetworkRecoveryGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.blockedNetworkRecoveryGeneration == generation,
                  self.blockedNetworkRecoveryWorkItem != nil else {
                return
            }
            self.blockedNetworkRecoveryWorkItem = nil
            guard self.networkServicesStarted else { return }

            let pairingIsInFlight = self.hasPairingInFlightForNetworkCheck
            if pairingIsInFlight {
                self.logNetworkCheckDeferredForPairing(reason: "dns-sd-recovery")
            }

            let components = self.blockedNetworkRecoveryState
                .beginRecoveryAttempts(
                    networkServicesStarted: self.networkServicesStarted,
                    pairingIsInFlight: pairingIsInFlight
                )
            components.forEach(self.restartBlockedNetworkService)
            self.scheduleBlockedNetworkRecovery()
        }
        blockedNetworkRecoveryWorkItem = workItem
        let delay = blockedNetworkRecoveryState.nextRetryInterval()
        #if DEBUG
        if networkRecoveryTimersAreManualForTesting { return }
        #endif
        queue.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func scheduleLocalNetworkProbeRecovery() {
        let hasPeer = localNetworkCheckPeer(preferredPeerID: nil) != nil
        let action = localNetworkProbeRecoveryState.reconcile(
            isBlocked: localNetworkProbeBlockedState.isBlocked
                || pairingTransportLocalNetworkState.isBlocked,
            networkServicesStarted: networkServicesStarted,
            hasDiscoveredPeer: hasPeer
        )
        switch action {
        case .none:
            break
        case .cancel:
            localNetworkProbeRecoveryWorkItem?.cancel()
            localNetworkProbeRecoveryWorkItem = nil
        case .schedule(let generation):
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.localNetworkProbeRecoveryWorkItem != nil,
                      self.localNetworkProbeRecoveryState.beginRetry(
                          generation: generation
                      ) else {
                    return
                }
                self.localNetworkProbeRecoveryWorkItem = nil
                self.runLocalNetworkProbeRecovery()
            }
            localNetworkProbeRecoveryWorkItem = workItem
            let delay = localNetworkProbeRecoveryState.nextRetryInterval()
            queue.asyncAfter(
                deadline: .now() + delay,
                execute: workItem
            )
        }
    }

    private func runLocalNetworkProbeRecovery() {
        let hasPeer = localNetworkCheckPeer(preferredPeerID: nil) != nil
        let isBlocked = localNetworkProbeBlockedState.isBlocked
            || pairingTransportLocalNetworkState.isBlocked
        let pairingIsInFlight = hasPairingInFlightForNetworkCheck
        let probeIsInFlight = localNetworkProbeConnection != nil
            || localNetworkDiscoveryCompletion != nil
        if pairingIsInFlight {
            logNetworkCheckDeferredForPairing(reason: "local-probe-recovery")
        }
        guard LocalNetworkProbeRecoveryState.shouldStartProbe(
            isBlocked: isBlocked,
            networkServicesStarted: networkServicesStarted,
            pairingIsInFlight: pairingIsInFlight,
            hasDiscoveredPeer: hasPeer,
            probeIsInFlight: probeIsInFlight
        ) else {
            // Pairing pauses connection-level retries. A missing peer cancels
            // the timer in reconcile and discovery will restart it when a
            // peer appears.
            scheduleLocalNetworkProbeRecovery()
            return
        }
        guard let peer = localNetworkCheckPeer(preferredPeerID: nil) else {
            scheduleLocalNetworkProbeRecovery()
            return
        }
        localNetworkProbeRecoveryState.recordRetryAttempt()
        startLocalNetworkProbe(
            to: peer,
            completion: { _ in },
            isAutomaticRecovery: true
        )
    }

    private func stopLocalNetworkProbeRecovery() {
        localNetworkProbeRecoveryState.stop()
        localNetworkProbeRecoveryWorkItem?.cancel()
        localNetworkProbeRecoveryWorkItem = nil
    }

    private func logNetworkCheckDeferredForPairing(reason: String) {
        MacKVMLogger.pairing.info(
            "phase=network-check.deferred reason=\(reason, privacy: .public) activeOutbound=\(self.activeOutboundRequestID != nil) trackedRequests=\(self.requestConnections.count + self.requestMessages.count) incomingConnections=\(self.unauthenticatedConnections.count) pendingConfirmation=\(self.pendingPairingConfirmationRequestID != nil) persistenceJobs=\(self.pairingPersistenceJobs.count) retryPending=\(self.pendingRetryPeer != nil || self.pendingRetryWorkItem != nil) localNetworkProbeInFlight=\(self.localNetworkProbeConnection != nil)"
        )
    }

    private func notifyLocalNetworkAccessRecovered(peerID: UUID?) {
        let expectedEpoch = localNetworkAccessStateEpoch.current()
        Task { @MainActor [weak self] in
            guard let self,
                  self.localNetworkAccessStateEpoch.current() == expectedEpoch
            else {
                return
            }
            self.onLocalNetworkAccessRecovered?(peerID)
        }
    }

    private func restartBlockedNetworkService(
        _ component: NetworkServiceComponent
    ) {
        #if DEBUG
        if networkRecoveryMissingComponentsForTesting != nil {
            networkRecoveryRestartsForTesting.append(component)
            networkRecoveryMissingComponentsForTesting?.remove(component)
            return
        }
        #endif

        switch component {
        case .browser:
            browser?.cancel()
            browser = nil
            browserIsReady = false
            startBrowser()
        case .listener:
            listener?.cancel()
            listener = nil
            listenerIsReady = false
            startListener()
        }
    }

    private func cancelGeneralNetworkRecovery() {
        networkRecoveryGeneration &+= 1
        networkRecoveryWorkItem?.cancel()
        networkRecoveryWorkItem = nil
        networkRecoveryAttempt = 0
    }

    private func reconcileGeneralNetworkRecovery() {
        if generalNetworkRecoveryComponents.isEmpty {
            cancelGeneralNetworkRecovery()
        } else {
            scheduleNetworkRecovery()
        }
    }

    @discardableResult
    private func recordNetworkServiceError(
        component: NetworkServiceComponent,
        state: String,
        error: Error
    ) -> Bool {
        let diagnostic = NetworkServiceErrorDiagnostic.capture(
            component: component,
            state: state,
            error: error
        )
        let isPolicyDenied = (error as? NWError).map {
            NetworkServiceStatePolicy.isLocalNetworkPolicyDenied($0)
        } ?? false
        if isPolicyDenied {
            blockedNetworkRecoveryState.recordPolicyDenial(for: component)
            localNetworkAccessStateEpoch.advance()
        }
        let localNetworkAccessBlocked = isLocalNetworkAccessBlocked
        Self.networkLogger.error(
            "component=\(component.rawValue, privacy: .public) state=\(state, privacy: .public) errorDomain=\(diagnostic.domain, privacy: .public) errorCode=\(diagnostic.code, privacy: .public) policyDenied=\(isPolicyDenied, privacy: .public)"
        )
        publishMain { service in
            switch component {
            case .browser:
                service.lastBrowserError = diagnostic
            case .listener:
                service.lastListenerError = diagnostic
            }
            service.localNetworkAccessBlocked = localNetworkAccessBlocked
        }
        if isPolicyDenied {
            scheduleBlockedNetworkRecovery()
            reconcileGeneralNetworkRecovery()
        }
        scheduleLocalNetworkProbeRecovery()
        return isPolicyDenied
    }

    @discardableResult
    private func noteBlockedNetworkServiceReady(
        _ component: NetworkServiceComponent
    ) -> Bool {
        guard blockedNetworkRecoveryState.recovered(component: component) else {
            return false
        }
        localNetworkAccessStateEpoch.advance()
        let stillBlocked = blockedNetworkRecoveryState.isBlocked
        blockedNetworkRecoveryState.resetRetryBackoff()
        blockedNetworkRecoveryGeneration &+= 1
        blockedNetworkRecoveryWorkItem?.cancel()
        blockedNetworkRecoveryWorkItem = nil
        resetLocalNetworkProbeRecoveryState()
        if !stillBlocked {
            publishCurrentLocalNetworkAccessBlocked()
            return true
        } else {
            scheduleBlockedNetworkRecovery()
        }
        publishCurrentLocalNetworkAccessBlocked()
        return true
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
        if pairingTransportLocalNetworkState
            .recoveredAfterNetworkServicesReady() {
            localNetworkAccessStateEpoch.advance()
            publishCurrentLocalNetworkAccessBlocked()
        }
        let recoveredAfterFailure = networkRecoveryAttempt > 0
            || networkRecoveryWorkItem != nil
        networkRecoveryAttempt = 0
        networkRecoveryGeneration &+= 1
        networkRecoveryWorkItem?.cancel()
        networkRecoveryWorkItem = nil
        return recoveredAfterFailure
    }

    private var isLocalNetworkAccessBlocked: Bool {
        LocalNetworkAccessBlockedPolicy.isBlocked(
            by: blockedNetworkRecoveryState.isBlocked,
            pairingTransportLocalNetworkState.isBlocked,
            localNetworkProbeBlockedState.isBlocked
        )
    }

    private func publishCurrentLocalNetworkAccessBlocked() {
        let isBlocked = isLocalNetworkAccessBlocked
        publishMain { $0.localNetworkAccessBlocked = isBlocked }
        scheduleLocalNetworkProbeRecovery()
    }

    private func recordLocalNetworkProbeResult(
        _ result: LocalNetworkCheckResult,
        isAutomaticRecovery: Bool,
        peerID: UUID? = nil
    ) {
        // Every completed probe fences an earlier main-actor recovery callback,
        // including inconclusive results that leave the visible block intact.
        localNetworkAccessStateEpoch.advance()
        let probeSourceChanged = localNetworkProbeBlockedState.record(result)
        let transportSourceChanged = result == .reachable
            && isAutomaticRecovery
            && pairingTransportLocalNetworkState
                .recoveredAfterSuccessfulLocalNetworkProbe()
        if result == .reachable {
            resetLocalNetworkProbeRecoveryState()
        }
        if probeSourceChanged || transportSourceChanged {
            publishCurrentLocalNetworkAccessBlocked()
        } else {
            scheduleLocalNetworkProbeRecovery()
        }
        if result == .reachable, !isLocalNetworkAccessBlocked {
            notifyLocalNetworkAccessRecovered(peerID: peerID)
        }
    }

    private func isCurrentPairingTransport(
        requestID: UUID,
        connection: NWConnection,
        statusContext: PairingStatusContext?
    ) -> Bool {
        guard activeOutboundRequestID == requestID,
              requestConnections[requestID] === connection,
              let statusContext,
              let currentContext = pairingStatusContext(for: requestID),
              statusContext.peerID == currentContext.peerID,
              statusContext.expectedGeneration
                == currentContext.expectedGeneration,
              statusContext.expectedSigningPublicKey
                == currentContext.expectedSigningPublicKey else {
            return false
        }
        return PairingStatusPublicationPolicy.allows(
            expectedGeneration: statusContext.expectedGeneration,
            currentGeneration: registry.generation(for: statusContext.peerID),
            expectedSigningPublicKey: statusContext.expectedSigningPublicKey,
            currentSigningPublicKey: registry.publicKey(
                for: statusContext.peerID
            )
        )
    }

    static func areNetworkServicesReady(
        listenerPresent: Bool,
        browserPresent: Bool,
        listenerReady: Bool,
        browserReady: Bool
    ) -> Bool {
        listenerPresent && browserPresent && listenerReady && browserReady
    }

    private var hasPairingInFlightForNetworkCheck: Bool {
        #if DEBUG
        if let networkRecoveryPairingOverrideForTesting {
            return networkRecoveryPairingOverrideForTesting
        }
        #endif

        return LocalNetworkCheckPolicy.hasPairingInFlight(
            activeOutboundRequest: activeOutboundRequestID != nil,
            trackedRequestCount: requestConnections.count
                + requestMessages.count,
            incomingConnectionCount: unauthenticatedConnections.count,
            pendingConfirmation: pendingPairingConfirmationRequestID != nil,
            persistenceJobCount: pairingPersistenceJobs.count,
            hasScheduledRetry: pendingRetryPeer != nil
                || pendingRetryWorkItem != nil
        )
    }

    private func finishLocalNetworkCheckForPairing() {
        if let connection = localNetworkProbeConnection {
            finishLocalNetworkProbe(
                connection,
                generation: localNetworkProbeGeneration,
                result: .busy
            )
        } else if localNetworkDiscoveryCompletion != nil {
            finishLocalNetworkDiscoveryWait(
                generation: localNetworkProbeGeneration,
                result: .busy
            )
        }
    }

    private func localNetworkCheckPeer(
        preferredPeerID: UUID?
    ) -> DiscoveredPeer? {
        let peerID = LocalNetworkCheckPolicy.preferredPeerID(
            requestedPeerID: preferredPeerID,
            pairedPeerIDs: registry.pairedPeerIDs,
            availablePeerIDs: Array(discoveredPeersByID.keys)
        )
        return peerID.flatMap { discoveredPeersByID[$0] }
    }

    private func waitForLocalNetworkPeer(
        preferredPeerID: UUID?,
        isAutomatic: Bool,
        completion: @escaping (LocalNetworkCheckResult) -> Void
    ) {
        localNetworkProbeGeneration &+= 1
        let generation = localNetworkProbeGeneration
        localNetworkDiscoveryPreferredPeerID = preferredPeerID
        localNetworkDiscoveryCompletion = completion

        // With both services present, a manual check rebuilds discovery.
        // Automatic checks preserve a ready browser, but restart an existing
        // browser that is not ready so the bounded wait can find a peer.
        // Missing services are started in place, with the legacy manual path
        // kept intact when only one component is available.
        let browserWasPresent = browser != nil
        let listenerWasPresent = listener != nil
        if !listenerWasPresent || !browserWasPresent {
            startMissingNetworkServices(includingBlockedComponents: true)
        }
        if browserWasPresent && LocalNetworkCheckPolicy
            .shouldRefreshBrowserForDiscoveryWait(
                isAutomatic: isAutomatic,
                browserExists: browserWasPresent,
                browserIsReady: browserIsReady,
                listenerExists: listenerWasPresent
            ) {
            refreshBrowserOnQueue()
        }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  LocalNetworkCheckPolicy.acceptsProbeCallback(
                      callbackGeneration: generation,
                      currentGeneration: self.localNetworkProbeGeneration
                  ),
                  self.localNetworkDiscoveryCompletion != nil else {
                return
            }
            self.resumeLocalNetworkCheckAfterDiscovery(timeoutExpired: true)
        }
        localNetworkDiscoveryTimeout = timeout
        queue.asyncAfter(
            deadline: .now() + Self.localNetworkDiscoveryWait,
            execute: timeout
        )
    }

    private func resumeLocalNetworkCheckAfterDiscovery(
        timeoutExpired: Bool
    ) {
        guard let completion = localNetworkDiscoveryCompletion else { return }
        if hasPairingInFlightForNetworkCheck {
            logNetworkCheckDeferredForPairing(reason: "discovery-wait-resume")
            finishLocalNetworkDiscoveryWait(
                generation: localNetworkProbeGeneration,
                result: .busy
            )
            return
        }
        if let peer = localNetworkCheckPeer(
            preferredPeerID: localNetworkDiscoveryPreferredPeerID
        ) {
            localNetworkDiscoveryTimeout?.cancel()
            localNetworkDiscoveryTimeout = nil
            localNetworkDiscoveryCompletion = nil
            localNetworkDiscoveryPreferredPeerID = nil
            startLocalNetworkProbe(to: peer, completion: completion)
        } else if timeoutExpired {
            finishLocalNetworkDiscoveryWait(
                generation: localNetworkProbeGeneration,
                result: .noPeer
            )
        }
    }

    private func finishLocalNetworkDiscoveryWait(
        generation: UInt64,
        result: LocalNetworkCheckResult
    ) {
        guard LocalNetworkCheckPolicy.acceptsProbeCallback(
            callbackGeneration: generation,
            currentGeneration: localNetworkProbeGeneration
        ), let completion = localNetworkDiscoveryCompletion else {
            return
        }
        localNetworkProbeGeneration &+= 1
        localNetworkDiscoveryTimeout?.cancel()
        localNetworkDiscoveryTimeout = nil
        localNetworkDiscoveryCompletion = nil
        localNetworkDiscoveryPreferredPeerID = nil
        deliverLocalNetworkCheckResult(result, completion: completion)
    }

    private func startLocalNetworkProbe(
        to peer: DiscoveredPeer,
        completion: @escaping (LocalNetworkCheckResult) -> Void,
        isAutomaticRecovery: Bool = false
    ) {
        localNetworkDiscoveryTimeout?.cancel()
        localNetworkDiscoveryTimeout = nil
        localNetworkDiscoveryCompletion = nil
        localNetworkDiscoveryPreferredPeerID = nil
        localNetworkProbeGeneration &+= 1
        let generation = localNetworkProbeGeneration
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: peer.endpoint, using: parameters)
        localNetworkProbeConnection = connection
        localNetworkProbePeerID = peer.identity.id
        localNetworkProbeCompletion = completion
        localNetworkProbeIsAutomaticRecovery = isAutomaticRecovery
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection,
                  LocalNetworkCheckPolicy.acceptsProbeCallback(
                      callbackGeneration: generation,
                      currentGeneration: self.localNetworkProbeGeneration
                  ),
                  self.localNetworkProbeConnection === connection else {
                return
            }
            let decision = LocalNetworkCheckPolicy.decision(
                for: state,
                unsatisfiedReason: connection.currentPath?.unsatisfiedReason
            )
            guard case let .finish(result) = decision else { return }
            self.finishLocalNetworkProbe(
                connection,
                generation: generation,
                result: result
            )
        }
        let timeout = DispatchWorkItem { [weak self, weak connection] in
            guard let self, let connection,
                  LocalNetworkCheckPolicy.acceptsProbeCallback(
                      callbackGeneration: generation,
                      currentGeneration: self.localNetworkProbeGeneration
                  ),
                  self.localNetworkProbeConnection === connection else {
                return
            }
            self.finishLocalNetworkProbe(
                connection,
                generation: generation,
                result: LocalNetworkCheckPolicy.timeoutResult()
            )
        }
        localNetworkProbeTimeout = timeout
        queue.asyncAfter(
            deadline: .now() + Self.localNetworkCheckTimeout,
            execute: timeout
        )
        connection.start(queue: queue)
    }

    private func finishLocalNetworkProbe(
        _ connection: NWConnection,
        generation: UInt64,
        result: LocalNetworkCheckResult
    ) {
        guard LocalNetworkCheckPolicy.acceptsProbeCallback(
            callbackGeneration: generation,
            currentGeneration: localNetworkProbeGeneration
        ), localNetworkProbeConnection === connection else {
            return
        }
        let probedPeerID = localNetworkProbePeerID
        localNetworkProbeGeneration &+= 1
        localNetworkProbeTimeout?.cancel()
        localNetworkProbeTimeout = nil
        localNetworkProbeConnection = nil
        localNetworkProbePeerID = nil
        let completion = localNetworkProbeCompletion
        localNetworkProbeCompletion = nil
        let isAutomaticRecovery = localNetworkProbeIsAutomaticRecovery
        localNetworkProbeIsAutomaticRecovery = false
        recordLocalNetworkProbeResult(
            result,
            isAutomaticRecovery: isAutomaticRecovery,
            peerID: probedPeerID
        )
        // No bytes are sent. Clearing the handler and advancing the probe
        // generation before cancel prevents this intentional close from
        // publishing a second result.
        connection.stateUpdateHandler = nil
        connection.cancel()
        if let completion {
            deliverLocalNetworkCheckResult(result, completion: completion)
        }
    }

    private func deliverLocalNetworkCheckResult(
        _ result: LocalNetworkCheckResult,
        completion: @escaping (LocalNetworkCheckResult) -> Void
    ) {
        DispatchQueue.main.async {
            completion(result)
        }
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
            let statusContext = self.pairingStatusContext(for: requestID)
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
            self.publishStatus(
                "Pairing with \(peerName) canceled",
                context: statusContext
            )
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
        finishLocalNetworkCheckForPairing()
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
        let statusContext = pairingStatusContext(for: request.requestID)
        publishMain {
            $0.pairingRetryPeer = nil
            $0.pairingActivity = .connecting(
                peerID: peer.identity.id,
                peerName: peer.name
            )
        }
        publishStatus(
            isLocalNetworkAccessBlocked
                ? LocalNetworkRecoveryGuidance.localizedMessage
                : "Connecting to \(peer.name)… If macOS asks about the firewall on "
                    + "the receiving Mac, allow it, then select Retry pairing.",
            context: statusContext
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
                if self.isCurrentPairingTransport(
                    requestID: request.requestID,
                    connection: connection,
                    statusContext: statusContext
                ) {
                    if self.pairingTransportLocalNetworkState.recovered(
                        by: request.requestID,
                        currentRequestID: self.activeOutboundRequestID
                    ) {
                        self.localNetworkAccessStateEpoch.advance()
                        self.publishCurrentLocalNetworkAccessBlocked()
                    }
                }
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
                self.publishStatus(
                    "Negotiating a security code with \(peer.name)…",
                    context: statusContext
                )
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
                        self.isLocalNetworkAccessBlocked
                            ? LocalNetworkRecoveryGuidance.localizedMessage
                            : self.pairingTransportFailureMessage(
                                peerName: peer.name,
                                detail: error.localizedDescription
                            ),
                        context: statusContext
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
                        self.isLocalNetworkAccessBlocked
                            ? LocalNetworkRecoveryGuidance.localizedMessage
                            : self.pairingTransportFailureMessage(
                                peerName: peer.name,
                                detail: "pairing connection canceled"
                            ),
                        context: statusContext
                    )
                }
            case .waiting(let error):
                guard self.isCurrentPairingTransport(
                    requestID: request.requestID,
                    connection: connection,
                    statusContext: statusContext
                ) else { return }
                let unsatisfiedReason = connection.currentPath?.unsatisfiedReason
                let isLocalNetworkDenied =
                    NetworkServiceStatePolicy.isLocalNetworkAccessDenied(
                        error: error,
                        unsatisfiedReason: unsatisfiedReason
                    )
                if isLocalNetworkDenied {
                    let bridgedError = error as NSError
                    let errorCode: Int
                    if case let .dns(dnsError) = error {
                        errorCode = Int(dnsError)
                    } else {
                        errorCode = bridgedError.code
                    }
                    let reason = unsatisfiedReason.map {
                        String(describing: $0)
                    } ?? "none"
                    Self.networkLogger.error(
                        "component=pairing-transport state=waiting request=\(MacKVMLogger.short(request.requestID), privacy: .public) errorDomain=\(bridgedError.domain, privacy: .public) errorCode=\(errorCode, privacy: .public) pathUnsatisfiedReason=\(reason, privacy: .public)"
                    )
                    self.pairingTransportLocalNetworkState.recordDenial(
                        for: request.requestID
                    )
                    self.localNetworkAccessStateEpoch.advance()
                    self.publishCurrentLocalNetworkAccessBlocked()
                }
                self.logPairingPhase(
                    "transport.waiting",
                    requestID: request.requestID,
                    peerID: peer.identity.id,
                    detail: "role=initiator error=\(error.localizedDescription)"
                )
                self.publishStatus(
                    self.isLocalNetworkAccessBlocked
                        ? LocalNetworkRecoveryGuidance.localizedMessage
                        : "Waiting for \(peer.name)… If the receiving Mac shows a "
                            + "firewall prompt, allow it, then select Retry pairing.",
                    context: statusContext
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
        let statusContext = pairingStatusContext(for: requestID)
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
                        + " to accept…",
                context: statusContext
            )
        } else {
            publishStatus("Pairing declined", context: statusContext)
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
        let requestID = pending.requestID
        guard pendingPairingAttemptTokens[requestID] == pending.id,
              !consumedPairingAttemptTokens.contains(pending.id),
              let connection = requestConnections[requestID],
              let request = requestMessages[requestID],
              request.sender.id == pending.peer.id,
              request.sender.signingPublicKey == pending.peer.signingPublicKey,
              let peerContribution = peerContributions[requestID],
              let localContribution = localContributions[requestID],
              pending.verificationCode == PairingVerificationCode.make(
                  requestID: requestID,
                  initiatorPublicKey: request.sender.signingPublicKey,
                  responderPublicKey: identity.signingPublicKey,
                  initiatorContribution: peerContribution,
                  responderContribution: localContribution
              ) else {
            // Only remove the captured UI attempt. In particular, do not let
            // a stale prompt's shared wire ID retire or otherwise affect a
            // replacement connection.
            removePendingRequest(attemptID: pending.id)
            return
        }
        // Accept and Decline are both one-shot actions. The network queue
        // serializes competing clicks, so consume the token before either
        // branch can send data or mutate pairing state.
        consumedPairingAttemptTokens.insert(pending.id)

        if accepted,
           let outboundRequestID = provisionalCollisionOutboundRequestIDs[requestID] {
            let currentGeneration = registry.generation(for: pending.peer.id)
            guard requestForgetGenerations.current(for: requestID) == currentGeneration,
                  PairingRequestPolicy.acceptsDiscoveredPeer(
                      request.sender,
                      pinnedPublicKey: registry.publicKey(for: pending.peer.id)
                  ) else {
                finish(requestID: requestID)
                return
            }
            if activeOutboundRequestID == outboundRequestID {
                guard requestTargets[outboundRequestID]?.id == pending.peer.id,
                      requestTargets[outboundRequestID]?.signingPublicKey
                        == pending.peer.signingPublicKey,
                      requestForgetGenerations.current(for: outboundRequestID)
                        == currentGeneration else {
                    finish(requestID: requestID)
                    return
                }
                // Only local consent can retire this specific selected request.
                // A later outbound request must never be cancelled by an old
                // provisional prompt, even when it targets the same peer.
                provisionalCollisionOutboundRequestIDs.removeValue(forKey: requestID)
                finish(requestID: outboundRequestID, userCancelledPersistence: true)
            } else {
                provisionalCollisionOutboundRequestIDs.removeValue(forKey: requestID)
            }
        }
        let statusContext = pairingStatusContext(for: requestID)

        logPairingPhase(
            accepted ? "user.accept" : "user.decline",
            requestID: requestID,
            peerID: pending.peer.id,
            detail: "role=responder"
        )

        let response = PairingEnvelope.decision(
            to: request,
            from: identity,
            accepted: accepted,
            senderModel: localModel
        )
        send(response, over: connection, reportsError: false) { [weak self] sent in
            guard let self else { return }
            guard self.requestConnections[requestID] === connection,
                  self.pendingPairingAttemptTokens[requestID] == pending.id else {
                return
            }
            guard sent else {
                self.logPairingPhase(
                    "decision.send.failed",
                    requestID: requestID,
                    peerID: pending.peer.id,
                    detail: "role=responder"
                )
                self.finish(requestID: requestID)
                self.publishStatus(
                    self.pairingTransportFailureMessage(
                        peerName: pending.peer.name,
                        detail: "pairing response failed"
                    ),
                    context: statusContext
                )
                return
            }
            self.logPairingPhase(
                "decision.send.confirmed",
                requestID: requestID,
                peerID: pending.peer.id,
                detail: "role=responder"
            )
            if !accepted {
                self.finish(requestID: requestID)
            }
        }
        if accepted {
            // The user action is the local acceptance. Do not make the
            // handshake depend on Network.framework's contentProcessed
            // callback, which may be delayed while the peer is sending its
            // decision at the same time. A failed send still tears down the
            // request above, and persistence remains gated by the peer's
            // signed decision, both completions, and acknowledgement.
            locallyAcceptedRequestIDs.insert(requestID)
            beginCompletionIfMutuallyAccepted(requestID: requestID)
        }
        removePendingRequest(attemptID: pending.id)
        publishStatus(
            accepted
                ? "Accepted here; completing pairing with \(pending.peer.name)…"
                : "Pairing request declined",
            context: statusContext
        )
    }

    @discardableResult
    func forget(_ peerID: UUID) -> Bool {
        // Keep trust removal synchronous with the user action. The secure
        // listener runs on another queue and must not authenticate this peer
        // while the queued discovery cleanup is waiting to run.
        let result = registry.revokeWithPersistenceResult(peerID)
        publishPairingMain(context: PairingStatusContext(
            peerID: peerID,
            expectedGeneration: result.generation,
            expectedSigningPublicKey: nil
        )) { service in
            if result.persisted {
                service.failedForgetPeerIDs.remove(peerID)
                service.status = "Pairing forgotten"
            } else {
                service.failedForgetPeerIDs.insert(peerID)
                service.status = Self.trustRemovalFailureMessage
            }
        }
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
        return result.persisted
    }

    private static let trustRemovalFailureMessage = NSLocalizedString(
        "Trust is revoked for this run, but could not be removed from storage. Retry Forget before quitting; the old pairing may return after relaunch.",
        comment: "Failed durable trust removal"
    )

    private func publishTrustRemovalFailure(
        for peerID: UUID,
        generation: UInt64
    ) {
        publishPairingMain(context: PairingStatusContext(
            peerID: peerID,
            expectedGeneration: generation,
            expectedSigningPublicKey: nil
        )) { service in
            service.failedForgetPeerIDs.insert(peerID)
            service.status = Self.trustRemovalFailureMessage
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
                    _ = self.noteNetworkServiceBecameReady(.listener)
                    self.noteNetworkServiceReady()
                    if NetworkServiceReadyStatusPolicy
                        .shouldPublishListenerReady(
                            hasBlockedComponents:
                                self.blockedNetworkRecoveryState.isBlocked
                        ) {
                        self.publishStatus("Ready on the local network")
                    }
                case .failed(let error):
                    self.listenerIsReady = false
                    let policyDenied = self.recordNetworkServiceError(
                        component: .listener,
                        state: "failed",
                        error: error
                    )
                    if policyDenied {
                        if !self.hasPairingInFlightForNetworkCheck {
                            self.publishStatus(
                                String(localized: "macOS is blocking this local network connection.")
                            )
                        }
                    } else {
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
                    }
                    self.listener?.cancel()
                    self.listener = nil
                    if !policyDenied {
                        self.scheduleNetworkRecovery()
                    }
                case .waiting(let error):
                    self.listenerIsReady = false
                    let policyDenied = self.recordNetworkServiceError(
                        component: .listener,
                        state: "waiting",
                        error: error
                    )
                    if policyDenied {
                        if !self.hasPairingInFlightForNetworkCheck {
                            self.publishStatus(
                                String(localized: "macOS is blocking this local network connection.")
                            )
                        }
                    } else {
                        self.publishStatus(
                            "Incoming pairing is waiting for the local network or "
                                + "firewall approval: \(error.localizedDescription)"
                        )
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, let listener, self.listener === listener else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            listenerIsReady = false
            let policyDenied = recordNetworkServiceError(
                component: .listener,
                state: "start-failed",
                error: error
            )
            if policyDenied {
                if !hasPairingInFlightForNetworkCheck {
                    publishStatus(
                        String(localized: "macOS is blocking this local network connection.")
                    )
                }
            } else {
                _ = cancelUnfinishedPairingsForNetworkFailure()
                publishStatus("Could not start listener: \(error.localizedDescription)")
            }
            if !policyDenied {
                scheduleNetworkRecovery()
            }
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
            self.discoveredPeersByID = Dictionary(
                uniqueKeysWithValues: discovered.map { ($0.identity.id, $0) }
            )
            self.resumeLocalNetworkCheckAfterDiscovery(timeoutExpired: false)
            self.scheduleLocalNetworkProbeRecovery()
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
                let recoveredBlockedBrowser = self
                    .noteNetworkServiceBecameReady(.browser)
                let recoveredAfterFailure = self.noteNetworkServiceReady()
                if NetworkServiceReadyStatusPolicy
                    .shouldPublishBrowserRecovered(
                        recoveredFromPolicyDenial: recoveredBlockedBrowser,
                        recoveredAfterGenericFailure: recoveredAfterFailure,
                        hasBlockedComponents:
                            self.blockedNetworkRecoveryState.isBlocked
                    ) {
                    self.publishStatus("Discovery recovered on the local network")
                }
            case .failed(let error):
                self.browserIsReady = false
                let policyDenied = self.recordNetworkServiceError(
                    component: .browser,
                    state: "failed",
                    error: error
                )
                if policyDenied {
                    if !self.hasPairingInFlightForNetworkCheck {
                        self.publishStatus(
                            String(localized: "macOS is blocking this local network connection.")
                        )
                    }
                } else {
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
                }
                self.browser = nil
                if !policyDenied {
                    self.scheduleNetworkRecovery()
                }
            case .waiting(let error):
                self.browserIsReady = false
                let policyDenied = self.recordNetworkServiceError(
                    component: .browser,
                    state: "waiting",
                    error: error
                )
                if policyDenied,
                   !self.hasPairingInFlightForNetworkCheck {
                    self.publishStatus(
                        String(localized: "macOS is blocking this local network connection.")
                    )
                }
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
        let connectionID = ObjectIdentifier(connection)
        unauthenticatedConnections[connectionID] = connection
        let shortConnectionID = String(String(describing: connectionID).suffix(8))
        MacKVMLogger.pairing.info(
            "phase=transport.accept connection=\(shortConnectionID, privacy: .public) incomingConnections=\(self.unauthenticatedConnections.count) trackedRequests=\(self.requestConnections.count + self.requestMessages.count) localNetworkProbeInFlight=\(self.localNetworkProbeConnection != nil)"
        )
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                let connectionID = ObjectIdentifier(connection)
                if self.pairingTransportLocalNetworkState
                    .recoveredFromInboundReady(
                        connectionIsTracked:
                            self.unauthenticatedConnections[connectionID]
                                === connection
                    ) {
                    self.localNetworkAccessStateEpoch.advance()
                    self.publishCurrentLocalNetworkAccessBlocked()
                }
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
            messages.forEach { message in
                if unauthenticatedConnections[connectionID] === connection {
                    let shortConnectionID = String(
                        String(describing: connectionID).suffix(8)
                    )
                    MacKVMLogger.pairing.info(
                        "phase=transport.first-frame connection=\(shortConnectionID, privacy: .public) kind=\(message.kind.rawValue, privacy: .public) incomingConnections=\(self.unauthenticatedConnections.count) trackedRequests=\(self.requestConnections.count + self.requestMessages.count)"
                    )
                }
                handle(message, on: connection)
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
                    publishStatus(
                        "Received an incomplete pairing message",
                        context: pairingStatusContext(for: connection)
                    )
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
            publishStatus(
                "Received too many pairing messages in one delivery",
                context: pairingStatusContext(for: connection)
            )
            connection.cancel()
            removeConnection(connection)
        } catch {
            MacKVMLogger.pairing.error(
                "phase=receive.invalid-frame connection=\(MacKVMLogger.short(connectionID), privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            publishStatus(
                "Received an invalid pairing message",
                context: pairingStatusContext(for: connection)
            )
            connection.cancel()
            removeConnection(connection)
        }
    }

    private func handle(_ message: PairingEnvelope, on connection: NWConnection) {
        // A real pairing frame can arrive while a reachability check is
        // pending. Cancel only the diagnostic probe; a frame-free TCP check
        // from the peer must remain invisible to pairing state.
        finishLocalNetworkCheckForPairing()
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
            let collisionRequestID = activeOutboundRequestID.flatMap { requestID in
                requestTargets[requestID]?.id == message.sender.id ? requestID : nil
            }
            let selectedOutboundPeer = collisionRequestID.flatMap { requestTargets[$0] }
            let replacesOutbound = selectedOutboundPeer?.signingPublicKey
                    == message.sender.signingPublicKey
                && !PairingRequestPolicy.keepOutboundDuringCollision(
                    localID: identity.id,
                    remoteID: message.sender.id
                )
            // Admission describes the prospective state, but duplicate IDs
            // still include the selected outbound ID. An incoming request may
            // reserve one replacement slot after identity/protocol checks.
            // Until local consent, the protected outbound is the only allowed
            // extra physical slot (maximumPendingRequests + 1); unrelated
            // admission counts both requests and cannot grow this reservation.
            let prospectiveRequests = requestMessages.filter {
                !replacesOutbound || $0.key != collisionRequestID
            }
            let decision = PairingRequestPolicy.evaluate(
                request: message,
                pinnedPublicKey: registry.publicKey(for: message.sender.id),
                activeRequestIDs: Set(requestMessages.keys),
                pendingSenderIDs: Set(
                    prospectiveRequests.values
                        .filter { $0.kind == .request }
                        .map(\.sender.id)
                ),
                activeRequestCount: prospectiveRequests.count,
                maximumPendingRequests: Self.maximumPendingRequests,
                activeUnpairedRequestCount: prospectiveRequests.values.filter {
                    $0.kind == .request
                        && $0.sender.id != identity.id
                        && registry.publicKey(for: $0.sender.id) == nil
                }.count,
                maximumUnpairedPendingRequests:
                    Self.maximumUnpairedPendingRequests,
                selectedOutboundPeer: selectedOutboundPeer
            )
            guard decision == .allow else {
                logPairingPhase(
                    "request.rejected",
                    requestID: message.requestID,
                    peerID: message.sender.id,
                    detail: "reason=\(statusMessage(for: decision))"
                )
                if activeOutboundRequestID == nil {
                    publishStatus(
                        statusMessage(for: decision),
                        context: pairingStatusContext(
                            for: message.sender.id,
                            signingPublicKey: registry.publicKey(for: message.sender.id)
                        )
                    )
                }
                connection.cancel()
                return
            }
            guard let peerCommitment = message.verificationCommitment,
                  peerCommitment.count == SHA256.Digest.byteCount else {
                logPairingPhase(
                    "request.rejected",
                    requestID: message.requestID,
                    peerID: message.sender.id,
                    detail: "reason=invalid-commitment"
                )
                if activeOutboundRequestID == nil {
                    publishStatus(
                        "Rejected an invalid pairing commitment",
                        context: pairingStatusContext(
                            for: message.sender.id,
                            signingPublicKey: registry.publicKey(for: message.sender.id)
                        )
                    )
                }
                connection.cancel()
                return
            }
            if let outboundRequestID = collisionRequestID {
                if !replacesOutbound {
                    logPairingPhase(
                        "request.collision.kept-outbound",
                        requestID: outboundRequestID,
                        peerID: message.sender.id
                    )
                    connection.cancel()
                    return
                }
                guard !provisionalCollisionOutboundRequestIDs.values.contains(outboundRequestID)
                else {
                    connection.cancel()
                    return
                }
                provisionalCollisionOutboundRequestIDs[message.requestID] = outboundRequestID
            }
            let localContribution: Data
            #if DEBUG
            if let contribution = nextLocalContributionForTesting {
                localContribution = contribution
                nextLocalContributionForTesting = nil
            } else {
                localContribution = PairingVerificationCode.makeContribution()
            }
            #else
            localContribution = PairingVerificationCode.makeContribution()
            #endif
            unauthenticatedConnections.removeValue(
                forKey: ObjectIdentifier(connection)
            )
            scheduleTimeout(
                for: connection,
                phase: .protocolNegotiation
            )
            requestConnections[message.requestID] = connection
            requestMessages[message.requestID] = message
            pendingPairingAttemptTokens[message.requestID] = UUID()
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
            let statusContext = pairingStatusContext(for: message.requestID)
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
            publishStatus(
                "Negotiating a security code with \(message.sender.name)…",
                context: statusContext
            )

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
            publishStatus(
                "Waiting for \(expectedPeer.name) to confirm the code…",
                context: pairingStatusContext(for: message.requestID)
            )

        case .reveal:
            guard let request = requestMessages[message.requestID],
                  let attemptID = pendingPairingAttemptTokens[message.requestID],
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
            guard PairingContributionPolicy.shouldRecordContribution(
                existingContribution: peerContributions[message.requestID]
            ) else {
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
            let statusContext = pairingStatusContext(for: message.requestID)
            publishPairingMain(context: statusContext) { service in
                if !service.pendingRequests.contains(where: { $0.id == attemptID }) {
                    service.pendingRequests.append(
                        PendingPairingRequest(
                            id: attemptID,
                            requestID: message.requestID,
                            peer: message.sender,
                            verificationCode: verificationCode
                        )
                    )
                }
                if statusContext?.suppressesStatus != true {
                    service.status = "\(message.sender.name) wants to pair"
                }
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
            guard PairingContributionPolicy.shouldRecordContribution(
                existingContribution: peerContributions[message.requestID]
            ) else {
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
            let statusContext = pairingStatusContext(for: message.requestID)
            publishPairingMain(context: statusContext) {
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
                "Compare security code \(verificationCode) with \(expectedPeer.name), then confirm…",
                context: pairingStatusContext(for: message.requestID)
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
                let statusContext = pairingStatusContext(for: message.requestID)
                publishStatus(
                    "\(message.sender.name) declined pairing",
                    context: statusContext
                )
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
                    "\(peer.name) confirmed; accept this request when the code matches",
                    context: pairingStatusContext(for: message.requestID)
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
        let statusContext = pairingStatusContext(for: message.requestID)
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
                                "Send failed: \(error.localizedDescription)",
                                context: statusContext
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
            publishStatus(
                "Could not encode pairing message",
                context: statusContext
            )
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
    @discardableResult
    private func revokeCancelledPersistenceTrust(
        for peerID: UUID
    ) -> PairingRegistry.RevocationResult? {
        guard latestSuccessfulPersistenceRequestIDsByPeer[peerID] == nil else {
            cancelledPersistenceTrustJobsByPeer.removeValue(forKey: peerID)
            return nil
        }
        guard let jobs = cancelledPersistenceTrustJobsByPeer[peerID] else {
            return nil
        }
        let currentGeneration = registry.generation(for: peerID)
        let currentKey = registry.publicKey(for: peerID)
        guard let matchingJob = jobs.reversed().first(where: {
            $0.expectedRegistryGeneration == currentGeneration
                && currentKey == $0.peer.signingPublicKey
        }) else {
            cancelledPersistenceTrustJobsByPeer.removeValue(forKey: peerID)
            return nil
        }
        #if DEBUG
        beforeTrustRollbackForTesting?()
        #endif
        guard let result = registry.revokeWithPersistenceResult(
            peerID,
            ifGeneration: matchingJob.expectedRegistryGeneration,
            publicKey: matchingJob.peer.signingPublicKey
        ) else {
            cancelledPersistenceTrustJobsByPeer.removeValue(forKey: peerID)
            return nil
        }
        cancelledPersistenceTrustJobsByPeer.removeValue(forKey: peerID)
        latestSuccessfulPersistenceRequestIDsByPeer.removeValue(forKey: peerID)
        logPairingPhase(
            "pairing.persist.rollback",
            requestID: matchingJob.requestID,
            peerID: peerID,
            detail: "cancelled-retry-failed persisted=\(result.persisted)"
        )
        return result
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
            var cancellationStatusGeneration = job.expectedRegistryGeneration
            var removalPersistenceFailed = false
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
                    #if DEBUG
                    beforeTrustRollbackForTesting?()
                    #endif
                    let result = registry.revokeWithPersistenceResult(
                        job.peer.id,
                        ifGeneration: job.expectedRegistryGeneration,
                        publicKey: job.peer.signingPublicKey
                    )
                    let nextGeneration = result?.generation
                    removalPersistenceFailed = result?.persisted == false
                    // Accept only the generation immediately produced by this
                    // rollback. A jump means Forget (or another revocation)
                    // raced the cleanup, so its terminal status must remain
                    // authoritative and the late cancellation is stale.
                    if let nextGeneration,
                       nextGeneration == job.expectedRegistryGeneration &+ 1 {
                        cancellationStatusGeneration = nextGeneration
                    }
                    cancelledPersistenceTrustJobsByPeer.removeValue(
                        forKey: job.peer.id
                    )
                }
            } else if isLatestPersistenceJob {
                if let result = revokeCancelledPersistenceTrust(
                    for: job.peer.id
                ) {
                    removalPersistenceFailed = !result.persisted
                    if result.generation == job.expectedRegistryGeneration &+ 1 {
                        cancellationStatusGeneration = result.generation
                    }
                }
            }
            logPairingPhase(
                "pairing.persist.discarded",
                requestID: job.requestID,
                peerID: job.peer.id,
                detail: "user-cancelled"
            )
            if removalPersistenceFailed {
                publishTrustRemovalFailure(
                    for: job.peer.id,
                    generation: cancellationStatusGeneration
                )
            } else {
                publishStatus(
                    "Pairing with \(job.peer.name) canceled",
                    // Capture after rollback so cancellation is not stale.
                    context: PairingStatusContext(
                        peerID: job.peer.id,
                        expectedGeneration: cancellationStatusGeneration,
                        expectedSigningPublicKey: nil
                    )
                )
            }
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
            var failureStatusGeneration = job.expectedRegistryGeneration
            var removalPersistenceFailed = false
            if isLatestPersistenceJob
                && latestSuccessfulPersistenceRequestIDsByPeer[job.peer.id]
                    == nil,
               let result = revokeCancelledPersistenceTrust(
                   for: job.peer.id
               ) {
                removalPersistenceFailed = !result.persisted
                // The rollback belongs to this pairing attempt's generation.
                // Publish the failure after it so the user sees why Retry is
                // needed, while a larger jump still suppresses stale status
                // after a concurrent Forget/revocation.
                if result.generation == job.expectedRegistryGeneration &+ 1 {
                    failureStatusGeneration = result.generation
                }
            }
            if removalPersistenceFailed {
                publishTrustRemovalFailure(
                    for: job.peer.id,
                    generation: failureStatusGeneration
                )
            } else {
                publishStatus(
                    "Could not save pairing with \(job.peer.name); try Pair again",
                    context: PairingStatusContext(
                        peerID: job.peer.id,
                        expectedGeneration: failureStatusGeneration,
                        expectedSigningPublicKey: nil
                    )
                )
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
            guard PairingStatusPublicationPolicy.allows(
                expectedGeneration: job.expectedRegistryGeneration,
                currentGeneration: self.registry.generation(for: peerID),
                expectedSigningPublicKey: signingPublicKey,
                currentSigningPublicKey: self.registry.publicKey(for: peerID)
            ) else {
                return
            }
            service.pairedPeerIDs.insert(peerID)
            service.failedForgetPeerIDs.remove(peerID)
            if service.pairingActivity.peerID == peerID {
                service.activeVerificationCode = nil
                service.pendingPairingConfirmation = nil
                service.pairingActivity = .idle
            }
        }
        onPairingCompleted?(peerID, job.expectedRegistryGeneration)
        publishMain { service in
            // The completion callback can pass its queue-side generation
            // check just before Forget revokes the peer. Recheck both values
            // on the main queue so this late status cannot overwrite
            // "Pairing forgotten".
            guard PairingStatusPublicationPolicy.allows(
                expectedGeneration: job.expectedRegistryGeneration,
                currentGeneration: self.registry.generation(for: peerID),
                expectedSigningPublicKey: signingPublicKey,
                currentSigningPublicKey: self.registry.publicKey(for: peerID)
            ) else {
                return
            }
            service.status = "Paired with \(job.peer.name)"
        }

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
        let pendingAttemptID = pendingPairingAttemptTokens.removeValue(
            forKey: requestID
        )
        if let pendingAttemptID {
            consumedPairingAttemptTokens.remove(pendingAttemptID)
            removePendingRequest(attemptID: pendingAttemptID)
        }
        if userCancelledPersistence {
            let provisionalRequestIDs = provisionalCollisionOutboundRequestIDs
                .filter { $0.value == requestID }.map(\.key)
            provisionalRequestIDs.forEach {
                finish(requestID: $0, userCancelledPersistence: true)
            }
        }
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
        provisionalCollisionOutboundRequestIDs.removeValue(forKey: requestID)
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
        let remainedUnauthenticated =
            unauthenticatedConnections[connectionID] === connection
        let trackedPairingRequest = requestConnections.values.contains {
            $0 === connection
        }
        let shortConnectionID = String(String(describing: connectionID).suffix(8))
        MacKVMLogger.pairing.info(
            "phase=transport.cleanup connection=\(shortConnectionID, privacy: .public) remainedUnauthenticated=\(remainedUnauthenticated) trackedPairingRequest=\(trackedPairingRequest) incomingConnections=\(self.unauthenticatedConnections.count) trackedRequests=\(self.requestConnections.count + self.requestMessages.count) localNetworkProbeInFlight=\(self.localNetworkProbeConnection != nil)"
        )
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
            let timeoutContext = requestIDForConnection(connection).flatMap {
                self.pairingStatusContext(for: $0)
            }
            if !wasPersisted {
                MacKVMLogger.pairing.error(
                    "phase=pairing.timeout timeoutPhase=\(String(describing: phase), privacy: .public) connection=\(MacKVMLogger.short(connectionID), privacy: .public)"
                )
                self.publishStatus(
                    "Pairing request timed out",
                    context: timeoutContext
                )
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

    private func removePendingRequest(attemptID: UUID) {
        publishMain { $0.pendingRequests.removeAll { $0.id == attemptID } }
    }

    private func pairingStatusContext(
        for requestID: UUID
    ) -> PairingStatusContext? {
        guard let peerID = peerIDForRequest(requestID) else {
            return nil
        }
        return PairingStatusContext(
            peerID: peerID,
            expectedGeneration: requestForgetGenerations.current(
                for: requestID
            ),
            expectedSigningPublicKey: nil,
            suppressesStatus: provisionalCollisionOutboundRequestIDs[requestID] != nil
        )
    }

    private func pairingStatusContext(
        for peerID: UUID,
        signingPublicKey: Data? = nil
    ) -> PairingStatusContext {
        PairingStatusContext(
            peerID: peerID,
            expectedGeneration: registry.generation(for: peerID),
            expectedSigningPublicKey: signingPublicKey
        )
    }

    private func requestIDForConnection(_ connection: NWConnection) -> UUID? {
        requestConnections.first { $0.value === connection }?.key
    }

    private func pairingStatusContext(
        for connection: NWConnection
    ) -> PairingStatusContext? {
        requestIDForConnection(connection).flatMap {
            pairingStatusContext(for: $0)
        }
    }

    private func publishStatus(
        _ message: String,
        context: PairingStatusContext? = nil
    ) {
        guard context?.suppressesStatus != true else { return }
        publishPairingMain(context: context) { service in
            service.status = message
        }
    }

    private func publishPairingMain(
        context: PairingStatusContext?,
        _ update: @escaping (PeerDiscoveryService) -> Void
    ) {
        publishMain { service in
            if let context,
               !PairingStatusPublicationPolicy.allows(
                   expectedGeneration: context.expectedGeneration,
                   currentGeneration: service.registry.generation(
                       for: context.peerID
                   ),
                   expectedSigningPublicKey: context.expectedSigningPublicKey,
                   currentSigningPublicKey: service.registry.publicKey(
                       for: context.peerID
                   )
               ) {
                return
            }
            update(service)
        }
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
        logPairingPhase(
            "message.rejected-unexpected",
            requestID: message.requestID,
            peerID: message.sender.id
        )
        if activeOutboundRequestID == nil
            || (activeOutboundRequestID == message.requestID
                && requestConnections[message.requestID] === connection) {
            publishStatus(
                "Rejected an unexpected pairing message",
                context: pairingStatusContext(for: message.requestID)
            )
        }
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
