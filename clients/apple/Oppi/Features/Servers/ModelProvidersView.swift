import SwiftUI
import UIKit
import UserNotifications

enum ProviderSetupState: Equatable {
    case unknown
    case unavailable
    case needsConfiguration
    case configured

    init(
        providerStatuses: [ProviderAuthProviderStatus],
        authenticatedModelCount: Int = 0,
        hasExternalTerminalLauncher: Bool = false
    ) {
        self = (providerStatuses.contains(where: \.authenticated)
            || authenticatedModelCount > 0
            || hasExternalTerminalLauncher)
            ? .configured
            : .needsConfiguration
    }
}

enum PushNotificationPromptCardState: Equatable, Sendable {
    case hidden
    case turnOn
    case openSettings
}

enum PushNotificationPromptPolicy {
    enum AuthorizationStatus: Equatable, Sendable {
        case notDetermined
        case denied
        case authorized

        init(systemStatus: UNAuthorizationStatus) {
            switch systemStatus {
            case .authorized, .provisional, .ephemeral:
                self = .authorized
            case .denied:
                self = .denied
            case .notDetermined:
                self = .notDetermined
            @unknown default:
                self = .notDetermined
            }
        }
    }

    static func cardState(
        authorizationStatus: AuthorizationStatus,
        isOptedIn: Bool,
        relayAdvertised: Bool,
        isDismissed: Bool
    ) -> PushNotificationPromptCardState {
        guard relayAdvertised, !isDismissed else { return .hidden }
        if isOptedIn, authorizationStatus == .authorized {
            return .hidden
        }
        switch authorizationStatus {
        case .denied:
            return .openSettings
        case .notDetermined, .authorized:
            return .turnOn
        }
    }
}

struct SessionListPushPromptSection: View {
    let serverId: String
    let connection: ServerConnection?

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var authorizationStatus: PushNotificationPromptPolicy.AuthorizationStatus = .notDetermined
    @State private var isOptedIn = false
    @State private var isDismissed = false
    @State private var isTurningOn = false
    @State private var inlineError: String?

    private var cardState: PushNotificationPromptPolicy.PushCardPresentation {
        PushNotificationPromptPolicy.PushCardPresentation(
            state: PushNotificationPromptPolicy.cardState(
                authorizationStatus: authorizationStatus,
                isOptedIn: isOptedIn,
                relayAdvertised: ReleaseFeatures.pushNotificationsEnabled && connection?.pushRelay != nil,
                isDismissed: isDismissed
            )
        )
    }

    var body: some View {
        Group {
            if cardState.isVisible {
                ProviderSetupPromptListSection {
                    cardContent
                }
            }
        }
        .task(id: serverId) {
            inlineError = nil
            await refreshState()
        }
        .onChange(of: connection?.pushRelay) { _, _ in
            Task { await refreshState() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await refreshState() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PushRegistration.stateDidChangeNotification)) { _ in
            Task { await refreshState() }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Label("Get notified when agents need you", systemImage: "bell.badge.fill")
                    .font(.headline)
                    .foregroundStyle(.themeFg)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    dismissPrompt()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.themeComment)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification prompt")
                .accessibilityIdentifier("workspace.pushPrompt.dismiss")
            }

            Text(
                cardState.state == .openSettings
                    ? "Allow notifications for Oppi in iOS Settings so questions and approvals can alert you."
                    : "Turn on encrypted push notifications for this server to get questions, approvals, and finished runs."
            )
            .font(.subheadline)
            .foregroundStyle(.themeComment)

            if let inlineError, !inlineError.isEmpty {
                Label(inlineError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.themeOrange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("workspace.pushPrompt.error")
            }

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                if cardState.state == .openSettings {
                    Button("Open Settings") {
                        openNotificationSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("workspace.pushPrompt.openSettings")
                } else {
                    Button {
                        turnOnPush()
                    } label: {
                        HStack(spacing: 8) {
                            if isTurningOn {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Turn on")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isTurningOn)
                    .accessibilityIdentifier("workspace.pushPrompt.turnOn")
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.themeComment.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.themeComment.opacity(0.18), lineWidth: 1)
        )
        .accessibilityIdentifier("workspace.pushPrompt.card")
    }

    private func refreshState() async {
        isOptedIn = PushRegistration.isEnabled(serverId: serverId)
        isDismissed = PushRegistration.isPromptDismissed(serverId: serverId)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = PushNotificationPromptPolicy.AuthorizationStatus(
            systemStatus: settings.authorizationStatus
        )
    }

    private func turnOnPush() {
        guard !isTurningOn else { return }
        isTurningOn = true
        inlineError = nil
        Task {
            let outcome = await PushRegistration.shared.turnOn(
                serverId: serverId,
                connection: connection
            )
            await refreshState()
            isTurningOn = false
            switch outcome {
            case .success:
                inlineError = nil
            case .failure(let error):
                inlineError = error.errorDescription
            }
        }
    }

    private func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        openURL(url)
    }

    private func dismissPrompt() {
        PushRegistration.setPromptDismissed(true, serverId: serverId)
        isDismissed = true
    }
}

extension PushNotificationPromptPolicy {
    struct PushCardPresentation: Equatable {
        let state: PushNotificationPromptCardState
        var isVisible: Bool { state != .hidden }
    }
}

enum ProviderSetupPromptPolicy {
    static func shouldShow(for state: ProviderSetupState) -> Bool {
        state == .needsConfiguration
    }

    /// Keep the All Sessions empty-state copy from stacking under the setup card.
    static func shouldShowInboxEmptyState(isEmpty: Bool, showsProviderSetup: Bool) -> Bool {
        isEmpty && !showsProviderSetup
    }
}

struct ServerVersionPromptCard: View {
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(ServerUpdatePresentation.minimumVersionNoticeTitle, systemImage: "arrow.down.app")
                .font(.headline)
                .foregroundStyle(.themeFg)

            Text(ServerUpdatePresentation.minimumVersionNoticeMessage)
                .font(.subheadline)
                .foregroundStyle(.themeComment)

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                Button(ServerUpdatePresentation.minimumVersionNoticeAction, action: onOpen)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("workspace.minimumServerVersion.open")

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.themeComment.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.themeComment.opacity(0.18), lineWidth: 1)
        )
        .accessibilityIdentifier("workspace.minimumServerVersion.notice")
    }
}

struct ProviderSetupPromptCard: View {
    let message: String
    let openAccessibilityIdentifier: String
    let onConfigure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Finish server setup", systemImage: "key.fill")
                .font(.headline)
                .foregroundStyle(.themeFg)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.themeComment)

            HStack(spacing: 0) {
                Spacer(minLength: 0)

                Button("Configure Model Provider", action: onConfigure)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(openAccessibilityIdentifier)

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.themeComment.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.themeComment.opacity(0.18), lineWidth: 1)
        )
    }
}

struct ProviderSetupPromptListSection<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Section {
            content
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }
}

struct ProviderConfigurationPresentation: Equatable {
    let state: ProviderSetupState

    var showsLoading: Bool { state == .unknown }
    var showsProviderSections: Bool {
        state == .needsConfiguration || state == .configured
    }

    func summary(connectedCount: Int) -> String {
        switch state {
        case .unknown:
            "Loading…"
        case .unavailable:
            "Unavailable"
        case .needsConfiguration:
            "Needs setup"
        case .configured:
            "\(connectedCount) connected"
        }
    }
}

struct ServerDetailsScopedDestinationView: View {
    @Environment(ServerStore.self) private var serverStore
    @Environment(ConnectionCoordinator.self) private var coordinator

    let target: ServerDetailsNavTarget

    private var server: PairedServer? {
        ServerSelection.resolveVisible(
            activeId: coordinator.activeServerId,
            frozenId: target.serverId,
            from: serverStore.servers
        )
    }

    var body: some View {
        if let server {
            ServerSettingsRootView(server: server)
                .id(server.id)
        } else {
            unavailableServerView
        }
    }

    private var unavailableServerView: some View {
        ContentUnavailableView(
            "Server Unavailable",
            systemImage: "server.rack",
            description: Text("This paired server is no longer available.")
        )
        .navigationTitle(HostSwitcherDestination.serverSettings.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ModelProvidersScopedDestinationView: View {
    @Environment(ServerStore.self) private var serverStore
    @Environment(ConnectionCoordinator.self) private var coordinator

    let target: ModelProvidersNavTarget

    private var server: PairedServer? {
        ServerSelection.resolveVisible(
            activeId: coordinator.activeServerId,
            frozenId: target.serverId,
            from: serverStore.servers
        )
    }

    var body: some View {
        if let server {
            // Keyed by the navigation target, not the visible host: a host-pill
            // switch must not destroy the view and drop a live provider sign-in.
            // ModelProvidersManagementView resets host-local state when the host changes.
            ModelProvidersManagementView(server: server)
                .id(target.serverId)
        } else {
            ContentUnavailableView(
                "Server Unavailable",
                systemImage: "server.rack",
                description: Text("This paired server is no longer available.")
            )
            .navigationTitle(HostSwitcherDestination.modelProviders.title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
