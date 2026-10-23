import Foundation
@testable import Oppi
import Testing

@Suite("Provider setup prompt policy")
@MainActor
struct ProviderSetupPromptPolicyTests {
    @Test func unknownStatusShowsLoadingWithoutProviderSections() {
        let presentation = ProviderConfigurationPresentation(state: .unknown)

        #expect(!ProviderSetupPromptPolicy.shouldShow(for: .unknown))
        #expect(presentation.showsLoading)
        #expect(!presentation.showsProviderSections)
        #expect(presentation.summary(connectedCount: 0) == "Loading…")
    }

    @Test func failedStatusShowsUnavailableWithoutProviderSectionsOrPrompt() {
        let presentation = ProviderConfigurationPresentation(state: .unavailable)

        #expect(!ProviderSetupPromptPolicy.shouldShow(for: .unavailable))
        #expect(!presentation.showsLoading)
        #expect(!presentation.showsProviderSections)
        #expect(presentation.summary(connectedCount: 0) == "Unavailable")
    }

    @Test func confirmedMissingConfigurationPrompts() {
        #expect(ProviderSetupPromptPolicy.shouldShow(for: .needsConfiguration))
    }

    @Test func modelProvidersRowUsesNeedsSetupAndConnectedCount() {
        let needsSetup = ProviderConfigurationPresentation(state: .needsConfiguration)
        let configured = ProviderConfigurationPresentation(state: .configured)

        #expect(needsSetup.summary(connectedCount: 0) == "Needs setup")
        #expect(configured.summary(connectedCount: 2) == "2 connected")
    }

    @Test func successfulEmptyOrUnauthenticatedStatusNeedsConfiguration() {
        #expect(ProviderSetupState(providerStatuses: []) == .needsConfiguration)
        #expect(ProviderSetupState(providerStatuses: [provider(authenticated: false)]) == .needsConfiguration)
    }

    @Test func authenticatedProviderMarksServerConfigured() {
        let state = ProviderSetupState(providerStatuses: [provider(authenticated: true)])

        #expect(state == .configured)
        #expect(!ProviderSetupPromptPolicy.shouldShow(for: state))
    }

    @Test func authenticatedModelsMarkServerConfiguredEvenWhenProviderStatusIsUnauthenticated() {
        let state = ProviderSetupState(
            providerStatuses: [provider(authenticated: false)],
            authenticatedModelCount: 24
        )

        #expect(state == .configured)
        #expect(!ProviderSetupPromptPolicy.shouldShow(for: state))
    }

    @Test func externalTerminalLauncherMarksServerConfiguredWithoutProviderOrCatalogModels() {
        let state = ProviderSetupState(
            providerStatuses: [provider(authenticated: false)],
            authenticatedModelCount: 0,
            hasExternalTerminalLauncher: true
        )

        #expect(state == .configured)
        #expect(!ProviderSetupPromptPolicy.shouldShow(for: state))
    }

    @Test(arguments: [
        // (authStatus, isOptedIn, relayAdvertised, isDismissed, expectedCardState)
        (PushNotificationPromptPolicy.AuthorizationStatus.notDetermined, false, true, false, PushNotificationPromptCardState.turnOn),
        (.authorized, false, true, false, .turnOn),
        (.denied, false, true, false, .openSettings),
        (.denied, true, true, false, .openSettings),
        (.notDetermined, true, true, false, .turnOn),
        (.authorized, true, true, false, .hidden),
        (.notDetermined, false, false, false, .hidden),
        (.notDetermined, false, true, true, .hidden),
        (.denied, false, true, true, .hidden),
    ])
    func pushNotificationPromptCardStateMapping(
        authStatus: PushNotificationPromptPolicy.AuthorizationStatus,
        isOptedIn: Bool,
        relayAdvertised: Bool,
        isDismissed: Bool,
        expected: PushNotificationPromptCardState
    ) {
        let actual = PushNotificationPromptPolicy.cardState(
            authorizationStatus: authStatus,
            isOptedIn: isOptedIn,
            relayAdvertised: relayAdvertised,
            isDismissed: isDismissed
        )
        #expect(actual == expected)
    }

    @Test func pushPromptDismissalClearsWhenAttentionArrivesWhilePushIsOff() {
        let serverId = "test-push-prompt-\(UUID().uuidString)"
        defer {
            PushRegistration.setEnabled(false, serverId: serverId)
            PushRegistration.setPromptDismissed(false, serverId: serverId)
        }

        PushRegistration.setEnabled(false, serverId: serverId)
        PushRegistration.setPromptDismissed(true, serverId: serverId)
        #expect(PushRegistration.isPromptDismissed(serverId: serverId))

        PushRegistration.clearPromptDismissalOnAttentionIfNeeded(serverId: serverId)
        #expect(!PushRegistration.isPromptDismissed(serverId: serverId))
    }

    @Test func pushPromptDismissalDoesNotClearWhenPushIsAlreadyEnabled() {
        let serverId = "test-push-prompt-enabled-\(UUID().uuidString)"
        defer {
            PushRegistration.setEnabled(false, serverId: serverId)
            PushRegistration.setPromptDismissed(false, serverId: serverId)
        }

        PushRegistration.setEnabled(true, serverId: serverId)
        PushRegistration.setPromptDismissed(true, serverId: serverId)
        PushRegistration.clearPromptDismissalOnAttentionIfNeeded(serverId: serverId)
        #expect(PushRegistration.isPromptDismissed(serverId: serverId))
    }

    @Test func inboxEmptyStateHidesWhileProviderSetupPromptIsShowing() {
        #expect(
            !ProviderSetupPromptPolicy.shouldShowInboxEmptyState(
                isEmpty: true,
                showsProviderSetup: true
            )
        )
    }

    @Test func inboxEmptyStateShowsWhenInboxIsEmptyWithoutProviderSetup() {
        #expect(
            ProviderSetupPromptPolicy.shouldShowInboxEmptyState(
                isEmpty: true,
                showsProviderSetup: false
            )
        )
    }

    @Test func inboxEmptyStateStaysHiddenWhenInboxHasSessions() {
        #expect(
            !ProviderSetupPromptPolicy.shouldShowInboxEmptyState(
                isEmpty: false,
                showsProviderSetup: true
            )
        )
        #expect(
            !ProviderSetupPromptPolicy.shouldShowInboxEmptyState(
                isEmpty: false,
                showsProviderSetup: false
            )
        )
    }

    private func provider(authenticated: Bool) -> ProviderAuthProviderStatus {
        ProviderAuthProviderStatus(
            id: "provider",
            name: "Provider",
            supportsApiKey: true,
            oauth: nil,
            authenticated: authenticated,
            credentialType: authenticated ? .apiKey : nil,
            expiresAt: nil,
            maskedKey: nil
        )
    }
}
