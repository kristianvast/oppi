import CryptoKit
import OSLog
import UIKit

private let logger = Logger(subsystem: AppIdentifiers.subsystem, category: "Push")

/// Opt-in, end-to-end-encrypted push for each paired server (protocol/push/spec.md).
///
/// Push needs both ends to opt in: the server operator sets `push.mode` to `relay`, so the
/// server advertises `capabilities.pushNotifications.relay`, and the user turns on push for
/// that server here (off by default). Then, once per connection, this:
///
/// 1. gets this device's APNs token and notification permission;
/// 2. registers the token with the relay, with App Attest when the device supports it;
/// 3. mints a send permission for this server at the relay;
/// 4. sends the server this device's X25519 push public key for that server and the send
///    token, signed by the device's pairing key;
/// 5. checks the server's Ed25519 key against the fingerprint pinned at pairing and stores
///    it with the private key for the Notification Service Extension.
///
/// The relay sees the APNs token, never a push key or push content.
@MainActor
final class PushRegistration {
    static let shared = PushRegistration()

    /// Push keys rotate at the first registration after this age.
    static let keyRotationInterval: TimeInterval = 30 * 86_400

    private var deviceToken: String?
    private var lastDeviceTokenError: String?
    private var tokenWaiters: [CheckedContinuation<String?, Never>] = []

    #if DEBUG
    /// Replaces the registration a server's push capability starts.
    var _onRegisterForTesting: ((String?) -> Void)?
    /// Overrides the shared turn-on registration path for deterministic tests.
    var _turnOnForTesting: ((String) async -> Result<Void, PushTurnOnError>)?
    #endif

    private init() {}

    // MARK: - Opt-in

    private static func optInKey(serverId: String) -> String {
        "\(AppIdentifiers.subsystem).push.enabled.\(serverId)"
    }

    private static func permissionKey(serverId: String) -> String {
        "\(AppIdentifiers.subsystem).push.permission.\(serverId)"
    }

    private static func promptDismissedKey(serverId: String) -> String {
        "\(AppIdentifiers.subsystem).push.promptDismissed.\(serverId)"
    }

    static let stateDidChangeNotification = Notification.Name("oppi.push.registrationStateDidChange")

    /// The user turned on push for this server. Off by default.
    static func isEnabled(serverId: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: optInKey(serverId: serverId))
    }

    static func setEnabled(_ enabled: Bool, serverId: String, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: optInKey(serverId: serverId))
        NotificationCenter.default.post(name: stateDidChangeNotification, object: serverId)
    }

    /// Whether the user dismissed the session-list push prompt card for this server.
    static func isPromptDismissed(serverId: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: promptDismissedKey(serverId: serverId))
    }

    static func setPromptDismissed(_ dismissed: Bool, serverId: String, defaults: UserDefaults = .standard) {
        if dismissed {
            defaults.set(true, forKey: promptDismissedKey(serverId: serverId))
        } else {
            defaults.removeObject(forKey: promptDismissedKey(serverId: serverId))
        }
        NotificationCenter.default.post(name: stateDidChangeNotification, object: serverId)
    }

    /// Re-show a dismissed session-list push prompt if a question or permission ask arrives
    /// while push is off for this server.
    static func clearPromptDismissalOnAttentionIfNeeded(
        serverId: String?,
        defaults: UserDefaults = .standard
    ) {
        guard let serverId = serverId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverId.isEmpty,
              !isEnabled(serverId: serverId, defaults: defaults),
              isPromptDismissed(serverId: serverId, defaults: defaults)
        else {
            return
        }
        setPromptDismissed(false, serverId: serverId, defaults: defaults)
    }

    // MARK: - Registration

    /// The connection loaded a server that pushes through `relay`. Registers only when the user
    /// opted in for this server.
    func serverAdvertisesPush(api: APIClient, serverId: String?, deviceId: String?, relay: URL) {
        guard let serverId, Self.isEnabled(serverId: serverId) else { return }
        #if DEBUG
        if let onRegister = _onRegisterForTesting {
            onRegister(serverId)
            return
        }
        // Screenshot previews must not raise the system permission alert.
        if ScreenshotPreviewConfig.isEnabled { return }
        #endif
        guard let deviceId else { return }
        Task { await register(api: api, serverId: serverId, deviceId: deviceId, relay: relay) }
    }

    @discardableResult
    func register(api: APIClient, serverId: String, deviceId: String, relay: URL) async -> Bool {
        Self.reportPushFallbacks()
        switch await registerWithDetail(api: api, serverId: serverId, deviceId: deviceId, relay: relay) {
        case .success:
            return true
        case .failure:
            return false
        }
    }

    /// Shared owner action for turning on push notifications for a server.
    ///
    /// Used by both `ServerPushNotificationsSection` in Server Settings and the
    /// session-list notification ask card so neither duplicates registration or
    /// opt-in rollback logic.
    func turnOn(serverId: String, connection: ServerConnection?) async -> Result<Void, PushTurnOnError> {
        #if DEBUG
        if let hook = _turnOnForTesting {
            return await hook(serverId)
        }
        #endif
        guard let connection,
              let relay = connection.pushRelay,
              let api = connection.apiClient,
              let deviceId = connection.credentials?.deviceCredential?.deviceId
        else {
            return .failure(.missingServerConnection)
        }

        Self.setEnabled(true, serverId: serverId)
        let result = await registerWithDetail(
            api: api,
            serverId: serverId,
            deviceId: deviceId,
            relay: relay
        )
        switch result {
        case .success:
            Self.setPromptDismissed(false, serverId: serverId)
            return .success(())
        case .failure(let error):
            Self.setEnabled(false, serverId: serverId)
            return .failure(error)
        }
    }

    func registerWithDetail(
        api: APIClient,
        serverId: String,
        deviceId: String,
        relay: URL
    ) async -> Result<Void, PushTurnOnError> {
        let server = serverId.prefix(16)
        guard let environment = APNsEnvironment.current else {
            logger.error("Push registration skipped for server \(server, privacy: .public): no aps-environment")
            return .failure(.missingAPNsEnvironment)
        }
        // Request/check notification permission first so a denied or undetermined
        // authorization state is surfaced before waiting on APNs or the relay.
        guard await AttentionNotificationService.shared.notificationsAuthorized() else {
            return .failure(.notificationsNotAuthorized)
        }
        guard let token = await currentDeviceToken() else {
            return .failure(.apnsTokenUnavailable(lastDeviceTokenError))
        }
        Self.publishRedactionSnapshot()
        do {
            try await register(
                api: api,
                serverId: serverId,
                deviceId: deviceId,
                relay: relay,
                environment: environment,
                apnsToken: token,
                retryWithNewRelayRegistration: true
            )
            logger.info("Push registered with server \(server, privacy: .public) (\(environment.rawValue, privacy: .public))")
            return .success(())
        } catch let error as PushRegistrationError {
            logger.error("Push registration failed for server \(server, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failure(.serverKeyMismatch)
        } catch let error as PushRelayClient.RelayError {
            logger.error("Push registration failed for server \(server, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failure(.relayRejected(Self.describeRelayError(error)))
        } catch {
            logger.error("Push registration failed for server \(server, privacy: .public): \(String(describing: error), privacy: .public)")
            return .failure(.registrationFailed(error.localizedDescription))
        }
    }

    private static func describeRelayError(_ error: PushRelayClient.RelayError) -> String {
        switch error {
        case .gone:
            "Push relay registration expired (410)."
        case .tooManyPermissions:
            "Push relay permission limit reached (409)."
        case .rejected(let status, let code):
            if let code, !code.isEmpty {
                "Push relay rejected registration (HTTP \(status): \(code))."
            } else {
                "Push relay rejected registration (HTTP \(status))."
            }
        case .invalidResponse:
            "Push relay returned an invalid response."
        }
    }

    private func register(
        api: APIClient,
        serverId: String,
        deviceId: String,
        relay: URL,
        environment: APNsEnvironment,
        apnsToken: String,
        retryWithNewRelayRegistration: Bool
    ) async throws {
        let client = PushRelayClient(relay: relay)
        var relayRegistration = PushRelayRegistrationStore.load(relay: relay, environment: environment)
        if let existing = relayRegistration, existing.apnsToken != apnsToken {
            // A new APNs token needs a new relay registration; the old one is useless.
            try? await client.deleteRegistration(existing)
            relayRegistration = nil
        }
        let registration: PushRelayClient.Registration
        if let relayRegistration {
            registration = relayRegistration
        } else {
            registration = try await client.register(apnsToken: apnsToken, environment: environment)
            try PushRelayRegistrationStore.save(registration, relay: relay, environment: environment)
        }

        let minted: (permissionId: String, sendToken: String)
        do {
            minted = try await client.mintSendToken(registration)
        } catch PushRelayClient.RelayError.gone, PushRelayClient.RelayError.tooManyPermissions
            where retryWithNewRelayRegistration {
            // The relay forgot this device (APNs retired the token) or leaked permissions
            // filled it: start over with a fresh registration, once.
            try? await client.deleteRegistration(registration)
            PushRelayRegistrationStore.delete(relay: relay, environment: environment)
            try await register(
                api: api, serverId: serverId, deviceId: deviceId, relay: relay,
                environment: environment, apnsToken: apnsToken, retryWithNewRelayRegistration: false
            )
            return
        }

        let key = try currentOrNewKey(serverId: serverId)
        let publicKey = key.privateKey.publicKey.rawRepresentation
        let keyId = PushEnvelope.keyId(forPublicKey: publicKey).base64URLEncodedString
        let issuedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let message = PushRegistrationSignature.message(
            deviceId: deviceId,
            serverFingerprint: serverId,
            keyId: keyId,
            publicKey: publicKey,
            sendToken: minted.sendToken,
            relay: relay.absoluteString,
            issuedAt: issuedAt
        )
        let signature = try DeviceKeyProvider.shared.loadOrCreate().sign(message)
        let response = try await api.putPushRegistration(PushRegistrationRequest(
            keyId: keyId,
            publicKey: publicKey.base64URLEncodedString,
            sendToken: minted.sendToken,
            relay: relay.absoluteString,
            issuedAt: issuedAt,
            signature: signature.base64URLEncodedString
        ))

        // Pin: only the server whose identity this phone paired with may sign its pushes.
        guard let serverPublicKey = Data(base64URLEncoded: response.serverPublicKey),
              serverPublicKey.sha256Fingerprint == serverId,
              response.keyId == keyId else {
            try? await api.deletePushRegistration()
            throw PushRegistrationError.serverKeyMismatch
        }
        try PushSharedStore.saveKey(PushSharedStore.KeyRecord(
            privateKey: key.privateKey.rawRepresentation,
            serverId: serverId,
            serverPublicKey: serverPublicKey,
            createdAt: key.createdAt
        ))
        pruneKeys(serverId: serverId, keeping: 2)
        UserDefaults.standard.set(minted.permissionId, forKey: Self.permissionKey(serverId: serverId))
    }

    /// Turn push off for a server: the server forgets this device's key and token, the relay
    /// the permission, and this phone the keys.
    func disable(serverId: String, api: APIClient?, relay: URL?) async {
        Self.setEnabled(false, serverId: serverId)
        try? await api?.deletePushRegistration()
        if let relay, let environment = APNsEnvironment.current,
           let registration = PushRelayRegistrationStore.load(relay: relay, environment: environment),
           let permissionId = UserDefaults.standard.string(forKey: Self.permissionKey(serverId: serverId)) {
            try? await PushRelayClient(relay: relay).deletePermission(permissionId, registration: registration)
        }
        UserDefaults.standard.removeObject(forKey: Self.permissionKey(serverId: serverId))
        pruneKeys(serverId: serverId, keeping: 0)
    }

    /// Hand the extension's fallback records to client logs, which upload to the paired server
    /// while Send Diagnostics is on. Kept on the phone while it is off.
    private static func reportPushFallbacks() {
        guard TelemetrySettings.allowsRemoteDiagnosticsUpload else { return }
        let records = PushSharedStore.drainFallbacks()
        for (index, record) in records.enumerated() {
            var metadata = [
                "reason": record.reason,
                "shownAt": record.at.ISO8601Format(),
            ]
            if let detail = record.detail { metadata["detail"] = detail }
            ClientLog.warning(
                "PushFallback",
                "Push shown as fallback: \(record.reason)",
                metadata: metadata,
                flush: index == records.count - 1
            )
        }
    }

    // MARK: - Keys

    private struct PendingKey {
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let createdAt: Date
    }

    /// The newest key for this server unless it is due for rotation.
    private func currentOrNewKey(serverId: String) throws -> PendingKey {
        if let newest = PushSharedStore.allKeys().first(where: { $0.serverId == serverId }),
           Date().timeIntervalSince(newest.createdAt) < Self.keyRotationInterval,
           let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: newest.privateKey) {
            return PendingKey(privateKey: privateKey, createdAt: newest.createdAt)
        }
        return PendingKey(privateKey: Curve25519.KeyAgreement.PrivateKey(), createdAt: Date())
    }

    /// Keep the newest keys for a server: the previous one still opens pushes sealed before
    /// the server learned the new key.
    private func pruneKeys(serverId: String, keeping count: Int) {
        for record in PushSharedStore.allKeys().filter({ $0.serverId == serverId }).dropFirst(count) {
            if let keyId = try? record.keyId { PushSharedStore.deleteKey(keyId: keyId) }
        }
    }

    // MARK: - Redaction snapshot

    /// Give the extension the current App Lock and scoped-lock state. Called on registration
    /// and whenever either changes.
    /// App Lock counts as on whenever its timeout is set, even while the device has no
    /// passcode: the extension errs toward hiding.
    static func publishRedactionSnapshot(
        appLockEnabled: Bool = AppLockSettings.timeout().isEnabled,
        flags: Set<ScopedLockScope> = ScopedLockService.shared.flags
    ) {
        let scopes = Set(flags.map { scope -> PushRedactionSnapshot.Scope in
            switch scope {
            case .server(let serverId):
                PushRedactionSnapshot.Scope(serverId: serverId, workspaceId: nil, sessionId: nil)
            case .workspace(let serverId, let workspaceId):
                PushRedactionSnapshot.Scope(serverId: serverId, workspaceId: workspaceId, sessionId: nil)
            case .session(let serverId, let sessionId):
                PushRedactionSnapshot.Scope(serverId: serverId, workspaceId: nil, sessionId: sessionId)
            }
        })
        do {
            try PushSharedStore.saveRedactionSnapshot(
                PushRedactionSnapshot(appLockEnabled: appLockEnabled, lockedScopes: scopes)
            )
        } catch {
            // The extension then redacts everything.
            logger.error("Push redaction snapshot not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - APNs token

    /// Called from AppDelegate when APNs issues the device token.
    func didRegisterForRemoteNotifications(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        lastDeviceTokenError = nil
        resumeTokenWaiters(with: token)
    }

    /// Called from AppDelegate when APNs registration fails, including on a build
    /// signed without the Push Notifications entitlement.
    func didFailToRegisterForRemoteNotifications(error: Error) {
        logger.error("Failed to register for remote notifications: \(error.localizedDescription, privacy: .public)")
        lastDeviceTokenError = error.localizedDescription
        resumeTokenWaiters(with: nil)
    }

    /// APNs registration needs no notification permission; asking for it waits until a
    /// token proves this build can receive pushes.
    private func currentDeviceToken() async -> String? {
        if let deviceToken { return deviceToken }
        return await withCheckedContinuation { continuation in
            tokenWaiters.append(continuation)
            if tokenWaiters.count == 1 {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    private func resumeTokenWaiters(with token: String?) {
        let waiters = tokenWaiters
        tokenWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: token)
        }
    }
}

enum PushRegistrationError: Error {
    /// The server answered with an identity key other than the one pinned at pairing.
    case serverKeyMismatch
}

enum PushTurnOnError: LocalizedError, Equatable, Sendable {
    case missingServerConnection
    case missingAPNsEnvironment
    case notificationsNotAuthorized
    case apnsTokenUnavailable(String?)
    case serverKeyMismatch
    case relayRejected(String)
    case registrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingServerConnection:
            "Server connection is not ready. Wait for the server to connect and try again."
        case .missingAPNsEnvironment:
            "This build does not include the Push Notifications entitlement (no aps-environment)."
        case .notificationsNotAuthorized:
            "Notifications are turned off for Oppi in iOS Settings."
        case .apnsTokenUnavailable(let detail):
            if let detail, !detail.isEmpty {
                "APNs device token unavailable: \(detail)"
            } else {
                "Could not obtain an APNs device token from iOS."
            }
        case .serverKeyMismatch:
            "Server identity key did not match the paired server fingerprint."
        case .relayRejected(let detail):
            detail
        case .registrationFailed(let detail):
            "Push registration failed: \(detail)"
        }
    }
}

/// Body of `PUT /me/push-registration` (spec §5).
struct PushRegistrationRequest: Encodable, Equatable, Sendable {
    let keyId: String
    let publicKey: String
    let sendToken: String
    let relay: String
    let issuedAt: Int64
    let signature: String
}

struct PushRegistrationResponse: Decodable, Equatable, Sendable {
    let serverPublicKey: String
    let keyId: String
}
