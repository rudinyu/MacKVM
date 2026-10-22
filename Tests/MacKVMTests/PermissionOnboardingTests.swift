import Foundation
import XCTest
@testable import MacKVM

final class PermissionOnboardingTests: XCTestCase {
    func testNoMissingPermissionsWhenBothAreGranted() {
        XCTAssertEqual(
            PermissionOnboardingPolicy.missingPermissions(
                inputMonitoringGranted: true,
                accessibilityGranted: true
            ),
            []
        )
    }

    func testReportsOnlyInputMonitoringWhenItIsMissing() {
        XCTAssertEqual(
            PermissionOnboardingPolicy.missingPermissions(
                inputMonitoringGranted: false,
                accessibilityGranted: true
            ),
            [.inputMonitoring]
        )
    }

    func testReportsOnlyAccessibilityWhenItIsMissing() {
        XCTAssertEqual(
            PermissionOnboardingPolicy.missingPermissions(
                inputMonitoringGranted: true,
                accessibilityGranted: false
            ),
            [.accessibility]
        )
    }

    func testReportsBothMissingPermissionsInSetupOrder() {
        XCTAssertEqual(
            PermissionOnboardingPolicy.missingPermissions(
                inputMonitoringGranted: false,
                accessibilityGranted: false
            ),
            [.inputMonitoring, .accessibility]
        )
    }

    func testInputMonitoringSettingsOpenWhenRequestLeavesPermissionMissing() {
        XCTAssertTrue(
            PermissionOnboardingPolicy
                .shouldOpenInputMonitoringSettingsAfterRequest(
                    for: .inputMonitoring,
                    inputMonitoringGranted: false
                )
        )
    }

    func testInputMonitoringSettingsStayClosedWhenRequestGrantsPermission() {
        XCTAssertFalse(
            PermissionOnboardingPolicy
                .shouldOpenInputMonitoringSettingsAfterRequest(
                    for: .inputMonitoring,
                    inputMonitoringGranted: true
                )
        )
    }

    func testAccessibilityRequestDoesNotOpenInputMonitoringSettings() {
        XCTAssertFalse(
            PermissionOnboardingPolicy
                .shouldOpenInputMonitoringSettingsAfterRequest(
                    for: .accessibility,
                    inputMonitoringGranted: false
                )
        )
    }

    func testAccessibilitySettingsOpenWhenEffectiveInputGateRemainsClosed() {
        XCTAssertTrue(
            PermissionOnboardingPolicy
                .shouldOpenAccessibilitySettingsAfterRequest(
                    for: .accessibility,
                    accessibilityGranted: false
                )
        )
    }

    func testAccessibilitySettingsStayClosedWhenEffectiveInputGateOpens() {
        XCTAssertFalse(
            PermissionOnboardingPolicy
                .shouldOpenAccessibilitySettingsAfterRequest(
                    for: .accessibility,
                    accessibilityGranted: true
                )
        )
    }

    func testInputMonitoringRequestDoesNotOpenAccessibilitySettings() {
        XCTAssertFalse(
            PermissionOnboardingPolicy
                .shouldOpenAccessibilitySettingsAfterRequest(
                    for: .inputMonitoring,
                    accessibilityGranted: false
                )
        )
    }

    func testChecklistStartsWithLocalNetworkAwareness() {
        let state = PermissionOnboardingPolicy.checklistState(
            localNetworkAccessReviewed: false,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        )

        XCTAssertEqual(state.nextPermission, .localNetwork)
        XCTAssertFalse(state.isChecklistComplete)
        XCTAssertFalse(state.isReadyForInputSharing)
        XCTAssertEqual(
            state.checklist,
            [
                PermissionOnboardingChecklistItem(
                    permission: .localNetwork,
                    status: .current
                ),
                PermissionOnboardingChecklistItem(
                    permission: .inputMonitoring,
                    status: .waiting
                ),
                PermissionOnboardingChecklistItem(
                    permission: .accessibility,
                    status: .waiting
                )
            ]
        )
    }

    func testFirstTrackedBuildInvalidatesAnExistingReviewAcknowledgement() {
        withDefaults { defaults in
            defaults.set(
                true,
                forKey: OnboardingDefaults.localNetworkAccessReviewedKey
            )

            XCTAssertFalse(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    hadExistingDeviceCredentials: true,
                    currentBuild: "1.102.03(100)"
                )
            )
            XCTAssertFalse(
                defaults.bool(
                    forKey: OnboardingDefaults.localNetworkAccessReviewedKey
                )
            )
            XCTAssertEqual(
                defaults.string(forKey: OnboardingDefaults.lastExecutedBuildKey),
                "1.102.03(100)"
            )
        }
    }

    func testBuildUpgradeInvalidatesTheLocalNetworkReview() {
        withDefaults { defaults in
            defaults.set(
                "1.102.02(99)",
                forKey: OnboardingDefaults.lastExecutedBuildKey
            )
            defaults.set(
                true,
                forKey: OnboardingDefaults.localNetworkAccessReviewedKey
            )

            XCTAssertFalse(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    hadExistingDeviceCredentials: true,
                    currentBuild: "1.102.03(100)"
                )
            )
            XCTAssertFalse(
                defaults.bool(
                    forKey: OnboardingDefaults.localNetworkAccessReviewedKey
                )
            )
            XCTAssertEqual(
                defaults.string(forKey: OnboardingDefaults.lastExecutedBuildKey),
                "1.102.03(100)"
            )
        }
    }

    func testLegacyReviewMigrationStillWorksAfterBuildTrackingExists() {
        withDefaults { defaults in
            defaults.set(
                "1.102.03(100)",
                forKey: OnboardingDefaults.lastExecutedBuildKey
            )

            XCTAssertTrue(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    hadExistingDeviceCredentials: true,
                    currentBuild: "1.102.03(100)"
                )
            )
        }
    }

    func testNewInstallationStillRequiresTheLocalNetworkStep() {
        withDefaults { defaults in
            XCTAssertFalse(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    hadExistingDeviceCredentials: false,
                    currentBuild: "1.102.03(100)"
                )
            )
            XCTAssertEqual(
                defaults.object(
                    forKey: OnboardingDefaults.localNetworkAccessReviewedKey
                ) as? Bool,
                false
            )
            XCTAssertFalse(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    // Simulates the next launch, after the first launch has
                    // persisted a newly-created device identity.
                    hadExistingDeviceCredentials: true,
                    currentBuild: "1.102.03(100)"
                )
            )
            XCTAssertEqual(
                defaults.object(
                    forKey: OnboardingDefaults.localNetworkAccessReviewedKey
                ) as? Bool,
                false
            )
        }
    }

    func testExplicitLocalNetworkDenialIsNotOverwrittenByMigration() {
        withDefaults { defaults in
            defaults.set(
                "1.102.03(100)",
                forKey: OnboardingDefaults.lastExecutedBuildKey
            )
            defaults.set(
                false,
                forKey: OnboardingDefaults.localNetworkAccessReviewedKey
            )

            XCTAssertFalse(
                OnboardingDefaults.resolveLocalNetworkAccessReviewed(
                    defaults: defaults,
                    hadExistingDeviceCredentials: true,
                    currentBuild: "1.102.03(100)"
                )
            )
        }
    }

    func testExplicitLocalNetworkBlockOutranksOldProbeAndSocketResults() {
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: true,
                isExplicitlyBlocked: true,
                isChecking: true,
                latestCheckResult: .reachable
            ),
            .blocked
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: true,
                isExplicitlyBlocked: true,
                isChecking: false,
                latestCheckResult: .noPeer
            ),
            .blocked
        )
    }

    func testChecklistAdvancesInOrderAfterEachCompletedRequirement() {
        let afterNetworkReview = PermissionOnboardingPolicy.checklistState(
            localNetworkAccessReviewed: true,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        )
        XCTAssertEqual(afterNetworkReview.nextPermission, .inputMonitoring)
        XCTAssertEqual(
            afterNetworkReview.checklist.map(\.status),
            [.complete, .current, .waiting]
        )

        let afterInputMonitoring = PermissionOnboardingPolicy.checklistState(
            localNetworkAccessReviewed: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        )
        XCTAssertEqual(afterInputMonitoring.nextPermission, .accessibility)
        XCTAssertEqual(
            afterInputMonitoring.checklist.map(\.status),
            [.complete, .complete, .current]
        )
    }

    func testChecklistCanBeCompleteWhenAllRequirementsAreSatisfied() {
        let state = PermissionOnboardingPolicy.checklistState(
            localNetworkAccessReviewed: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )

        XCTAssertNil(state.nextPermission)
        XCTAssertTrue(state.isChecklistComplete)
        XCTAssertTrue(state.isReadyForInputSharing)
        XCTAssertEqual(state.checklist.map(\.status), [.complete, .complete, .complete])
    }

    func testInputSharingReadinessDoesNotPretendToVerifyLocalNetworkAccess() {
        let state = PermissionOnboardingPolicy.checklistState(
            localNetworkAccessReviewed: false,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        )

        XCTAssertEqual(state.nextPermission, .localNetwork)
        XCTAssertFalse(state.isChecklistComplete)
        XCTAssertTrue(state.isReadyForInputSharing)
    }

    func testOnlyInputMonitoringAndAccessibilityCanBeRequestedInApp() {
        XCTAssertFalse(MacKVMPermission.localNetwork.canRequestInApp)
        XCTAssertTrue(MacKVMPermission.inputMonitoring.canRequestInApp)
        XCTAssertTrue(MacKVMPermission.accessibility.canRequestInApp)
    }

    func testLocalNetworkStatusUsesCurrentEvidenceOnly() {
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: false,
                isExplicitlyBlocked: false,
                isChecking: false,
                latestCheckResult: nil
            ),
            .unverified
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: false,
                isExplicitlyBlocked: true,
                isChecking: false,
                latestCheckResult: nil
            ),
            .blocked
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: false,
                isExplicitlyBlocked: false,
                isChecking: true,
                latestCheckResult: nil
            ),
            .checking
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: true,
                isExplicitlyBlocked: false,
                isChecking: false,
                latestCheckResult: nil
            ),
            .working
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: true,
                isExplicitlyBlocked: true,
                isChecking: false,
                latestCheckResult: nil
            ),
            .blocked
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: true,
                isExplicitlyBlocked: false,
                isChecking: false,
                latestCheckResult: .unconfirmed
            ),
            .unconfirmed
        )
        XCTAssertEqual(
            LocalNetworkSetupStatus.resolve(
                hasCurrentAuthenticatedConnection: false,
                isExplicitlyBlocked: true,
                isChecking: false,
                latestCheckResult: .reachable
            ),
            .blocked
        )
    }

    func testOnlySuccessfulLocalNetworkEvidenceAdvancesTheSetupStep() {
        XCTAssertTrue(LocalNetworkSetupStatus.working.hasPositiveOperationalEvidence)
        XCTAssertTrue(LocalNetworkSetupStatus.reachable.hasPositiveOperationalEvidence)

        let uncertainStatuses: [LocalNetworkSetupStatus] = [
            .blocked,
            .checking,
            .unverified,
            .unconfirmed,
            .busy,
            .noPeer,
            .unavailable
        ]
        XCTAssertTrue(
            uncertainStatuses.allSatisfy {
                !$0.hasPositiveOperationalEvidence
            }
        )
    }

    func testReviewedUnknownOrBlockedAccessStillOffersSettingsAndCheck() {
        let unknown = LocalNetworkSetupActionPresentation.resolve(
            status: .unverified,
            accessWasReviewed: true,
            isAwaitingPromptResponse: false,
            canAcknowledgeCurrentPrompt: false,
            networkServicesStarted: true
        )
        XCTAssertTrue(unknown.showsSettingsAction)
        XCTAssertTrue(unknown.showsCheckAction)
        XCTAssertFalse(unknown.showsEnableAction)
        XCTAssertFalse(unknown.showsPromptAcknowledgement)

        let blocked = LocalNetworkSetupActionPresentation.resolve(
            status: .blocked,
            accessWasReviewed: true,
            isAwaitingPromptResponse: true,
            canAcknowledgeCurrentPrompt: false,
            networkServicesStarted: true
        )
        XCTAssertTrue(blocked.showsSettingsAction)
        XCTAssertTrue(blocked.showsCheckAction)
        XCTAssertFalse(blocked.showsEnableAction)
        XCTAssertFalse(blocked.showsPromptAcknowledgement)
        XCTAssertFalse(blocked.showsAwaitingPromptHint)
    }

    func testUpgradedExistingInstallationWithStalePromptFlagUsesUnknownActions() {
        let presentation = LocalNetworkSetupActionPresentation.resolve(
            status: .unverified,
            accessWasReviewed: false,
            isAwaitingPromptResponse: true,
            canAcknowledgeCurrentPrompt: false,
            networkServicesStarted: true
        )

        XCTAssertTrue(presentation.showsSettingsAction)
        XCTAssertTrue(presentation.showsCheckAction)
        XCTAssertFalse(presentation.showsEnableAction)
        XCTAssertFalse(presentation.showsPromptAcknowledgement)
        XCTAssertFalse(presentation.showsAwaitingPromptHint)
        XCTAssertEqual(
            LocalNetworkSetupStatus.unverified.supportLabel,
            "Access not verified"
        )
    }

    func testUnconfirmedAndUnavailableResultsOfferSettingsAndCheck() {
        let statuses: [LocalNetworkSetupStatus] = [
            .checking,
            .unverified,
            .unconfirmed,
            .busy,
            .noPeer,
            .unavailable
        ]

        for status in statuses {
            let presentation = LocalNetworkSetupActionPresentation.resolve(
                status: status,
                accessWasReviewed: false,
                isAwaitingPromptResponse: false,
                canAcknowledgeCurrentPrompt: false,
                networkServicesStarted: true
            )

            XCTAssertTrue(presentation.showsSettingsAction, "\(status)")
            XCTAssertTrue(presentation.showsCheckAction, "\(status)")
            XCTAssertFalse(presentation.showsEnableAction, "\(status)")
            XCTAssertFalse(presentation.showsPromptAcknowledgement, "\(status)")
        }
    }

    func testFreshUnreviewedSetupOffersEnableAndSettings() {
        let presentation = LocalNetworkSetupActionPresentation.resolve(
            status: .unverified,
            accessWasReviewed: false,
            isAwaitingPromptResponse: false,
            canAcknowledgeCurrentPrompt: false,
            networkServicesStarted: false
        )

        XCTAssertTrue(presentation.showsEnableAction)
        XCTAssertTrue(presentation.showsSettingsAction)
        XCTAssertFalse(presentation.showsCheckAction)
        XCTAssertFalse(presentation.showsPromptAcknowledgement)
    }

    func testAwaitingPromptOffersAcknowledgementAndSettings() {
        let presentation = LocalNetworkSetupActionPresentation.resolve(
            status: .checking,
            accessWasReviewed: false,
            isAwaitingPromptResponse: true,
            canAcknowledgeCurrentPrompt: true,
            networkServicesStarted: true
        )

        XCTAssertFalse(presentation.showsEnableAction)
        XCTAssertTrue(presentation.showsPromptAcknowledgement)
        XCTAssertTrue(presentation.showsSettingsAction)
        XCTAssertFalse(presentation.showsCheckAction)
        XCTAssertTrue(presentation.showsAwaitingPromptHint)
    }

    func testPositiveEvidenceHidesActionsAndUnknownAfterRecoveryIsSafe() {
        let upgradedInstallationAfterProbe =
            LocalNetworkSetupActionPresentation.resolve(
                status: .reachable,
                accessWasReviewed: false,
                isAwaitingPromptResponse: false,
                canAcknowledgeCurrentPrompt: false,
                networkServicesStarted: true
            )
        let freshInstallationAfterGrant =
            LocalNetworkSetupActionPresentation.resolve(
                status: .working,
                accessWasReviewed: false,
                isAwaitingPromptResponse: true,
                canAcknowledgeCurrentPrompt: true,
                networkServicesStarted: true
            )
        XCTAssertEqual(upgradedInstallationAfterProbe, .hidden)
        XCTAssertEqual(freshInstallationAfterGrant, .hidden)
        XCTAssertEqual(
            upgradedInstallationAfterProbe,
            freshInstallationAfterGrant
        )

        // Once the successful probe ends the old prompt workflow, a later
        // inconclusive snapshot offers Settings/check without suggesting the
        // user must toggle Local Network off and on or enable it again.
        let laterUnknown = LocalNetworkSetupActionPresentation.resolve(
            status: .unverified,
            accessWasReviewed: false,
            isAwaitingPromptResponse: false,
            canAcknowledgeCurrentPrompt: false,
            networkServicesStarted: true
        )
        XCTAssertFalse(laterUnknown.showsEnableAction)
        XCTAssertFalse(laterUnknown.showsPromptAcknowledgement)
        XCTAssertFalse(laterUnknown.showsAwaitingPromptHint)
        XCTAssertTrue(laterUnknown.showsSettingsAction)
        XCTAssertTrue(laterUnknown.showsCheckAction)
        XCTAssertEqual(LocalNetworkSetupStatus.unverified.supportLabel, "Access not verified")
    }

    func testNewAuthenticatedPeerInvalidatesOlderNetworkCheckEvidence() {
        let firstPeer = UUID()
        let secondPeer = UUID()

        XCTAssertTrue(
            LocalNetworkStatusFreshnessPolicy.hasNewAuthenticatedPeer(
                previousPeerID: nil,
                currentPeerID: firstPeer
            )
        )
        XCTAssertFalse(
            LocalNetworkStatusFreshnessPolicy.hasNewAuthenticatedPeer(
                previousPeerID: firstPeer,
                currentPeerID: firstPeer
            )
        )
        XCTAssertTrue(
            LocalNetworkStatusFreshnessPolicy.hasNewAuthenticatedPeer(
                previousPeerID: firstPeer,
                currentPeerID: secondPeer
            )
        )
        XCTAssertFalse(
            LocalNetworkStatusFreshnessPolicy.hasNewAuthenticatedPeer(
                previousPeerID: firstPeer,
                currentPeerID: nil
            )
        )
    }

    func testLocalNetworkPermissionLifecycleIgnoresNilAndPeerReplays() {
        let peerID = UUID()
        var lifecycle = LocalNetworkPermissionLifecycleState()
        let initialState = lifecycle

        XCTAssertEqual(
            lifecycle.authenticatedConnectionDidChange(to: nil),
            .unchanged
        )
        XCTAssertEqual(lifecycle, initialState)

        XCTAssertTrue(
            lifecycle.beginPermissionRequest(networkServicesStarted: false)
        )
        XCTAssertTrue(lifecycle.isAwaitingResponse)
        XCTAssertTrue(lifecycle.canAcknowledgeCurrentPrompt)
        XCTAssertFalse(
            lifecycle.beginPermissionRequest(networkServicesStarted: false)
        )

        XCTAssertEqual(
            lifecycle.authenticatedConnectionDidChange(to: peerID),
            .connected(peerID)
        )
        XCTAssertFalse(lifecycle.isAwaitingResponse)
        XCTAssertFalse(lifecycle.canAcknowledgeCurrentPrompt)

        let connectedState = lifecycle
        XCTAssertEqual(
            lifecycle.authenticatedConnectionDidChange(to: peerID),
            .unchanged
        )
        XCTAssertEqual(lifecycle, connectedState)
        XCTAssertFalse(lifecycle.completePermissionRequest())

        XCTAssertEqual(
            lifecycle.authenticatedConnectionDidChange(to: nil),
            .disconnected
        )
        let disconnectedState = lifecycle
        XCTAssertEqual(
            lifecycle.authenticatedConnectionDidChange(to: nil),
            .unchanged
        )
        XCTAssertEqual(lifecycle, disconnectedState)
        XCTAssertEqual(
            lifecycle.authenticatedConnectionDidChange(to: peerID),
            .connected(peerID)
        )
    }

    func testReachableLocalNetworkEvidenceExpiresAndCanBeRefreshed() {
        let peerID = UUID()
        let startedAt = Date(timeIntervalSince1970: 2_000)
        var evidence = LocalNetworkCheckEvidence()
        evidence.record(.reachable, at: startedAt, peerID: peerID)

        XCTAssertEqual(
            evidence.currentResult(
                now: startedAt.addingTimeInterval(
                    LocalNetworkCheckEvidence.reachableEvidenceLifetime - 1
                ),
                availablePeerIDs: [peerID]
            ),
            .reachable
        )
        XCTAssertNil(
            evidence.currentResult(
                now: startedAt.addingTimeInterval(
                    LocalNetworkCheckEvidence.reachableEvidenceLifetime
                ),
                availablePeerIDs: [peerID]
            )
        )

        XCTAssertTrue(
            evidence.expireReachableEvidence(
                now: startedAt.addingTimeInterval(
                    LocalNetworkCheckEvidence.reachableEvidenceLifetime
                ),
                availablePeerIDs: [peerID]
            )
        )
        XCTAssertNil(evidence.result)
        XCTAssertEqual(evidence.checkedAt, startedAt)
        XCTAssertFalse(
            evidence.expireReachableEvidence(
                now: startedAt.addingTimeInterval(90),
                availablePeerIDs: [peerID]
            )
        )

        let refreshedAt = startedAt.addingTimeInterval(90)
        evidence.record(.reachable, at: refreshedAt, peerID: peerID)
        XCTAssertEqual(
            evidence.currentResult(
                now: refreshedAt,
                availablePeerIDs: [peerID]
            ),
            .reachable
        )
    }

    func testPeerLossAndAuthenticatedDisconnectInvalidateReachabilityEvidence() {
        let peerID = UUID()
        let startedAt = Date(timeIntervalSince1970: 3_000)
        var evidence = LocalNetworkCheckEvidence()
        evidence.record(.reachable, at: startedAt, peerID: peerID)

        XCTAssertFalse(
            evidence.invalidateIfPeerUnavailable(
                availablePeerIDs: [peerID]
            )
        )
        XCTAssertTrue(
            evidence.invalidateIfPeerUnavailable(availablePeerIDs: [])
        )
        XCTAssertNil(evidence.currentResult(
            now: startedAt,
            availablePeerIDs: []
        ))
        XCTAssertEqual(evidence.checkedAt, startedAt)

        evidence.record(.reachable, at: startedAt, peerID: peerID)
        var connectionState = LocalNetworkPermissionLifecycleState(
            latestAuthenticatedPeerID: peerID
        )
        let disconnect = connectionState.authenticatedConnectionDidChange(
            to: nil
        )
        XCTAssertEqual(disconnect, .disconnected)
        XCTAssertTrue(evidence.invalidate(for: disconnect))
        XCTAssertNil(evidence.currentResult(
            now: startedAt,
            availablePeerIDs: [peerID]
        ))
        XCTAssertFalse(evidence.invalidate(for: .unchanged))
    }

    func testLateDiscoveryCheckCompletionCannotOverwritePeerSpecificSuccess() {
        let peerID = UUID()
        let actualProbeAt = Date(timeIntervalSince1970: 3_500)
        var evidence = LocalNetworkCheckEvidence()
        evidence.record(.reachable, at: actualProbeAt, peerID: peerID)

        XCTAssertFalse(
            evidence.recordManualCheckCompletion(
                .reachable,
                at: actualProbeAt.addingTimeInterval(0.1)
            )
        )
        XCTAssertEqual(evidence.result, .reachable)
        XCTAssertEqual(evidence.peerID, peerID)
        XCTAssertEqual(evidence.checkedAt, actualProbeAt)
        XCTAssertEqual(
            evidence.currentResult(
                now: actualProbeAt.addingTimeInterval(1),
                availablePeerIDs: [peerID]
            ),
            .reachable
        )
    }

    func testAutomaticNetworkChecksRespectFreshEvidenceAndActiveWork() {
        let start = Date(timeIntervalSince1970: 4_000)
        func shouldStart(
            hasAuthenticatedConnection: Bool = false,
            hasPairing: Bool = false,
            hasPendingConnection: Bool = false,
            hasFreshReachableEvidence: Bool = false
        ) -> Bool {
            LocalNetworkCheckLifecyclePolicy.shouldStartAutomaticCheck(
                isPolling: true,
                networkServicesStarted: true,
                checkInProgress: false,
                lastStartedAt: start,
                now: start.addingTimeInterval(
                    LocalNetworkCheckLifecyclePolicy
                        .minimumAutomaticCheckInterval
                ),
                hasActiveAuthenticatedConnection: hasAuthenticatedConnection,
                hasActivePairing: hasPairing,
                hasPendingConnectionAttempt: hasPendingConnection,
                hasFreshReachableEvidence: hasFreshReachableEvidence
            )
        }

        XCTAssertFalse(shouldStart(hasAuthenticatedConnection: true))
        XCTAssertFalse(shouldStart(hasPairing: true))
        XCTAssertFalse(shouldStart(hasPendingConnection: true))
        XCTAssertFalse(shouldStart(hasFreshReachableEvidence: true))
        XCTAssertTrue(shouldStart())

        XCTAssertTrue(
            LocalNetworkCheckLifecyclePolicy.canRunManualCheck(
                hasActiveAuthenticatedConnection: false,
                hasActivePairing: false,
                hasPendingConnectionAttempt: true
            )
        )
        XCTAssertFalse(
            LocalNetworkCheckLifecyclePolicy.canRunManualCheck(
                hasActiveAuthenticatedConnection: true,
                hasActivePairing: false,
                hasPendingConnectionAttempt: false
            )
        )
        XCTAssertFalse(
            LocalNetworkCheckLifecyclePolicy.canRunManualCheck(
                hasActiveAuthenticatedConnection: false,
                hasActivePairing: true,
                hasPendingConnectionAttempt: false
            )
        )
    }

    @MainActor
    func testRepeatedSettingsActivationKeepsAutomaticCheckRateLimit() {
        let scheduler = ManualPermissionRefreshScheduler()
        var refreshCount = 0
        let monitor = PermissionRefreshMonitor(
            interval: 2,
            scheduler: scheduler
        ) {
            refreshCount += 1
        }
        monitor.surfaceAppeared(UUID())
        monitor.surfaceAppeared(UUID())
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            LocalNetworkCheckLifecyclePolicy.shouldStartAutomaticCheck(
                isPolling: monitor.isPolling,
                networkServicesStarted: true,
                checkInProgress: false,
                lastStartedAt: nil,
                now: start
            )
        )

        for _ in 0 ..< 6 {
            monitor.applicationWillResignActive()
            monitor.applicationWillResignActive()
            monitor.applicationDidBecomeActive()
            monitor.applicationDidBecomeActive()
            XCTAssertFalse(
                LocalNetworkCheckLifecyclePolicy.shouldStartAutomaticCheck(
                    isPolling: monitor.isPolling,
                    networkServicesStarted: true,
                    checkInProgress: false,
                    lastStartedAt: start,
                    now: start.addingTimeInterval(1)
                )
            )
        }

        XCTAssertEqual(scheduler.activeTimerCount, 1)
        XCTAssertEqual(refreshCount, 0)
        scheduler.fireActiveTimers()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(
            LocalNetworkCheckLifecyclePolicy.shouldStartAutomaticCheck(
                isPolling: monitor.isPolling,
                networkServicesStarted: true,
                checkInProgress: false,
                lastStartedAt: start,
                now: start.addingTimeInterval(
                    LocalNetworkCheckLifecyclePolicy.minimumAutomaticCheckInterval
                )
            )
        )
    }

    @MainActor
    func testVisiblePermissionRefreshContinuesWhileApplicationIsInactive() {
        let scheduler = ManualPermissionRefreshScheduler()
        var refreshCount = 0
        let monitor = PermissionRefreshMonitor(
            interval: 2,
            scheduler: scheduler
        ) {
            refreshCount += 1
        }
        let menuSurface = UUID()
        let windowSurface = UUID()

        monitor.surfaceAppeared(menuSurface)
        monitor.surfaceAppeared(windowSurface)
        XCTAssertTrue(monitor.isPolling)
        XCTAssertEqual(scheduler.activeTimerCount, 1)
        XCTAssertEqual(scheduler.scheduledIntervals, [2])

        monitor.applicationWillResignActive()

        XCTAssertFalse(monitor.applicationIsActive)
        scheduler.fireActiveTimers()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(monitor.isPolling)

        monitor.surfaceDisappeared(menuSurface)
        XCTAssertTrue(monitor.isPolling)
        monitor.surfaceDisappeared(windowSurface)
        XCTAssertFalse(monitor.isPolling)
        XCTAssertEqual(scheduler.activeTimerCount, 0)
    }

    @MainActor
    func testTerminationStopsVisiblePermissionRefresh() {
        let scheduler = ManualPermissionRefreshScheduler()
        var refreshCount = 0
        let monitor = PermissionRefreshMonitor(
            interval: 2,
            scheduler: scheduler
        ) {
            refreshCount += 1
        }
        monitor.surfaceAppeared(UUID())
        XCTAssertTrue(monitor.isPolling)

        monitor.terminate()

        scheduler.fireActiveTimers()
        XCTAssertFalse(monitor.isPolling)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(monitor.visibleSurfaces.isEmpty)
    }

    func testPrivacySettingsURLsCoverEveryChecklistRequirement() {
        XCTAssertEqual(
            PrivacySettings.url(for: .localNetwork)?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        )
        XCTAssertEqual(
            PrivacySettings.url(for: .inputMonitoring)?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        )
        XCTAssertEqual(
            PrivacySettings.url(for: .accessibility)?.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "PermissionOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        body(defaults)
    }
}

@MainActor
private final class ManualPermissionRefreshScheduler:
    PermissionRefreshScheduling {
    private(set) var scheduledIntervals: [TimeInterval] = []
    private var timers: [ManualPermissionRefreshTimer] = []

    var activeTimerCount: Int {
        timers.filter(\.isActive).count
    }

    func schedule(
        every interval: TimeInterval,
        action: @escaping () -> Void
    ) -> any PermissionRefreshTimerToken {
        scheduledIntervals.append(interval)
        let timer = ManualPermissionRefreshTimer(action: action)
        timers.append(timer)
        return timer
    }

    func fireActiveTimers() {
        timers.filter(\.isActive).forEach { $0.fire() }
    }
}

@MainActor
private final class ManualPermissionRefreshTimer: PermissionRefreshTimerToken {
    private let action: () -> Void
    private(set) var isActive = true

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func fire() {
        guard isActive else { return }
        action()
    }

    func invalidate() {
        isActive = false
    }
}
