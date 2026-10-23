import CryptoKit
import Foundation
import os
import Security

/// Push state the app writes and the Notification Service Extension reads, while the phone
/// may be locked (spec §1, §2.5, §2.6):
///
/// - push keys in the shared keychain group, `AfterFirstUnlockThisDeviceOnly`;
/// - the redaction snapshot and the replay ledger as App Group files with
///   `completeUntilFirstUserAuthentication` protection.
///
/// Read failures fail closed: no key means the fallback text and an unreadable snapshot
/// means everything is redacted. An unreadable replay ledger is reset instead, so one bad
/// file cannot turn every later push into the fallback; a ledger that cannot be saved
/// rejects the push.
enum PushSharedStore {
    /// Same subsystem and category as the app's push logging. Never log plaintext or keys.
    static let logger = Logger(subsystem: "dev.chenda.Oppi", category: "Push")

    // MARK: - Push keys

    struct KeyRecord: Codable, Equatable, Sendable {
        /// 32-byte raw X25519 private key.
        let privateKey: Data
        let serverId: String
        /// Raw Ed25519 identity key of that server, checked against its pinned fingerprint.
        let serverPublicKey: Data
        let createdAt: Date

        var keyId: Data {
            get throws {
                let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
                return PushEnvelope.keyId(forPublicKey: key.publicKey.rawRepresentation)
            }
        }

        var material: PushKeyMaterial {
            PushKeyMaterial(privateKey: privateKey, serverPublicKey: serverPublicKey, serverId: serverId)
        }
    }

    static let keyService = "\(SharedConstants.keychainService).push-key"

    private static func keyQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
            kSecAttrAccessGroup as String: SharedConstants.keychainAccessGroup,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    static func loadKey(keyId: Data) -> KeyRecord? {
        var query = keyQuery(account: keyId.base64URLEncodedString)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(KeyRecord.self, from: data)
    }

    static func saveKey(_ record: KeyRecord) throws {
        let account = try record.keyId.base64URLEncodedString
        let data = try JSONEncoder().encode(record)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            // Pushes arrive while the phone is locked; the key never leaves this device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let update = SecItemUpdate(keyQuery(account: account) as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PushStoreError.keychain(update) }
        let add = keyQuery(account: account).merging(attributes) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw PushStoreError.keychain(status) }
    }

    /// Every stored push key, newest first.
    static func allKeys() -> [KeyRecord] {
        var query = keyQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [Data] else { return [] }
        return items
            .compactMap { try? JSONDecoder().decode(KeyRecord.self, from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func deleteKey(keyId: Data) {
        SecItemDelete(keyQuery(account: keyId.base64URLEncodedString) as CFDictionary)
    }

    // MARK: - App Group files

    private static func stateDirectory() throws -> URL {
        let container = try CrossProcessFileLock.appGroupContainer(identifier: SharedConstants.appGroupIdentifier)
        let directory = container.appendingPathComponent("push-state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: 0o700,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
        return directory
    }

    private static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Redaction snapshot

    static func saveRedactionSnapshot(_ snapshot: PushRedactionSnapshot) throws {
        let url = try stateDirectory().appendingPathComponent("redaction.json")
        try write(JSONEncoder().encode(snapshot), to: url)
    }

    /// `.unknown` (redact everything) when missing or unreadable.
    static func loadRedactionSnapshot() -> PushRedactionSnapshot {
        guard let url = try? stateDirectory().appendingPathComponent("redaction.json"),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PushRedactionSnapshot.self, from: data) else {
            return .unknown
        }
        return snapshot
    }

    // MARK: Fallback journal

    static func recordFallback(reason: String, detail: String?, now: Date) {
        do {
            let url = try stateDirectory().appendingPathComponent("fallbacks.json")
            try PushFallbackJournal.append(PushFallbackRecord(at: now, reason: reason, detail: detail), to: url)
        } catch {
            let nsError = error as NSError
            logger.error(
                "Push fallback not recorded (\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public))"
            )
        }
    }

    static func drainFallbacks() -> [PushFallbackRecord] {
        guard let url = try? stateDirectory().appendingPathComponent("fallbacks.json") else { return [] }
        return PushFallbackJournal.drain(url)
    }

    // MARK: Replay ledger

    /// Outcome of the replay check. Anything but `accepted` shows the fallback; the
    /// unavailable cases say why, so a broken ledger is not reported as a replay.
    enum ReplayCheck: Equatable, Sendable {
        case accepted
        case replay
        case ledgerUnavailable(String)
        case ledgerNotSaved(String)

        var failureDetail: String? {
            switch self {
            case .accepted, .replay: nil
            case .ledgerUnavailable(let detail), .ledgerNotSaved(let detail): detail
            }
        }
    }

    /// Record a push's message id for `keyId` (spec §2.5 step 7).
    static func checkMessage(_ messageId: Data, keyId: Data, now: Date) -> ReplayCheck {
        guard let directory = try? stateDirectory(),
              let container = try? CrossProcessFileLock.appGroupContainer(
                identifier: SharedConstants.appGroupIdentifier
              ) else {
            logger.error("Push replay ledger unavailable; showing the fallback")
            return .ledgerUnavailable("appGroup")
        }
        do {
            return try CrossProcessFileLock.withLock(serverId: "push-replay", container: container) {
                checkMessage(
                    messageId,
                    keyId: keyId,
                    now: now,
                    ledgerURL: directory.appendingPathComponent("replay.json"),
                    liveKeyIds: { Set(allKeys().compactMap { try? $0.keyId.base64URLEncodedString }) }
                )
            }
        } catch CrossProcessFileLock.LockError.openFailed(let code) {
            logger.error("Push replay lock not opened (errno \(code, privacy: .public)); showing the fallback")
            return .ledgerUnavailable("lockOpenFailed errno=\(code)")
        } catch {
            logger.error("Push replay lock not acquired; showing the fallback")
            return .ledgerUnavailable("lockFailed")
        }
    }

    /// The ledger read-modify-write; the caller holds the cross-process lock.
    static func checkMessage(
        _ messageId: Data,
        keyId: Data,
        now: Date,
        ledgerURL url: URL,
        liveKeyIds: () -> Set<String>
    ) -> ReplayCheck {
        var ledger = PushReplayLedger()
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                ledger = try JSONDecoder().decode(PushReplayLedger.self, from: Data(contentsOf: url))
            } catch {
                // Resetting forgets ids accepted within the last window, so a replay of one of
                // them could show once more. Keeping the bad file would show the fallback for
                // every push from now on.
                let nsError = error as NSError
                logger.error(
                    "Push replay ledger unreadable (\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)); resetting it"
                )
            }
        }
        guard ledger.accept(messageId: messageId, keyId: keyId, now: now) else { return .replay }
        // Entries for deleted keys go with them.
        ledger.retainKeys(liveKeyIds().union([keyId.base64URLEncodedString]))
        do {
            try write(JSONEncoder().encode(ledger), to: url)
            return .accepted
        } catch {
            let nsError = error as NSError
            logger.error(
                "Push replay ledger not saved (\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)); showing the fallback"
            )
            return .ledgerNotSaved("\(nsError.domain) \(nsError.code)")
        }
    }
}

enum PushStoreError: Error, Equatable {
    case keychain(OSStatus)
}
