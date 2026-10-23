import OSLog
import SwiftUI
import UIKit

/// OSLogStore's process scope only holds entries from the current launch, so
/// diagnostics must be collected before the app is relaunched.
struct DiagnosticsShareButton: View {
    @State private var fileURL: URL?
    @State private var isCollecting = false

    var body: some View {
        if let fileURL {
            ShareLink(item: fileURL) {
                Label("Share Diagnostics", systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("diagnostics.share")
        } else {
            Button {
                collect()
            } label: {
                if isCollecting {
                    ProgressView()
                } else {
                    Label("Collect Diagnostics", systemImage: "doc.text.magnifyingglass")
                }
            }
            .disabled(isCollecting)
            .accessibilityIdentifier("diagnostics.collect")
        }
    }

    private func collect() {
        isCollecting = true
        let header = DiagnosticsExport.header()
        Task.detached(priority: .userInitiated) {
            let url = DiagnosticsExport.write(header: header)
            await MainActor.run {
                fileURL = url
                isCollecting = false
            }
        }
    }
}

enum DiagnosticsExport {
    @MainActor
    static func header() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Oppi diagnostics \(Date().ISO8601Format())\nOppi \(version) (\(build)), iOS \(UIDevice.current.systemVersion)"
    }

    static func write(header: String, window: TimeInterval = 2 * 60 * 60, maxEntries: Int = 20_000) -> URL? {
        var lines = [header, ""]
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-window))
            var count = 0
            for case let entry as OSLogEntryLog in try store.getEntries(at: since) {
                lines.append("\(entry.date.ISO8601Format()) [\(entry.level.rawValue)] \(entry.subsystem)/\(entry.category): \(entry.composedMessage)")
                count += 1
                if count >= maxEntries { break }
            }
        } catch {
            lines.append("OSLogStore failed: \(error)")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oppi-diagnostics-\(Int(Date().timeIntervalSince1970)).txt")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
