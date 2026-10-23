import Foundation

/// One push the Notification Service Extension showed as the fixed fallback text. Holds the
/// rejection reason only, never anything from the push.
struct PushFallbackRecord: Codable, Equatable, Sendable {
    let at: Date
    /// `PushEnvelopeRejection` raw value, or `timeout`.
    let reason: String
    /// Why replay state was unavailable, for example `lockOpenFailed errno=1`.
    let detail: String?
}

/// The extension appends a record per fallback; the app drains them into client logs, so
/// the paired server's diagnostics name the reason without the phone's system log.
///
/// Not locked across processes: an append racing a drain can lose a record, which is
/// acceptable for diagnostics and keeps a failing lock from hiding its own report.
enum PushFallbackJournal {
    static let capacity = 50

    static func append(_ record: PushFallbackRecord, to url: URL) throws {
        var records = read(url)
        records.append(record)
        try write(Array(records.suffix(capacity)), to: url)
    }

    static func drain(_ url: URL) -> [PushFallbackRecord] {
        let records = read(url)
        if !records.isEmpty { try? FileManager.default.removeItem(at: url) }
        return records
    }

    private static func read(_ url: URL) -> [PushFallbackRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PushFallbackRecord].self, from: data)) ?? []
    }

    private static func write(_ records: [PushFallbackRecord], to url: URL) throws {
        // Written while the phone may be locked, like the replay ledger.
        try JSONEncoder().encode(records)
            .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
