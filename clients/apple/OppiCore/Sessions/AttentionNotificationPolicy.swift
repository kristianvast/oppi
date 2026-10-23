import Foundation

/// UIKit-free attention-notification policy shared by iOS and Mac painters.
///
/// Local banners exist for agent asks, and for `done` while the app runs in the
/// background on a server that pushes: that server skips its push to a device
/// holding a live stream. `SESSION_DONE` / `SESSION_ERROR` / `SESSION_BLOCKED`
/// are also the tap-routing categories for remote session-event payloads
/// (ended, done, error, blocked).
enum AttentionNotificationPolicy: Sendable {
    static let askCategoryId = SessionNotificationCategory.ask
    static let sessionDoneCategoryId = SessionNotificationCategory.sessionDone
    static let sessionErrorCategoryId = SessionNotificationCategory.sessionError
    static let sessionBlockedCategoryId = SessionNotificationCategory.sessionBlocked

    static let sessionCategoryIds = [
        askCategoryId,
        sessionDoneCategoryId,
        sessionErrorCategoryId,
        sessionBlockedCategoryId,
    ]

    static func shouldNotify(
        isAppActive: Bool,
        requestSessionId: String,
        activeSessionId: String?
    ) -> Bool {
        guard isAppActive else {
            return true
        }
        return requestSessionId != activeSessionId
    }

    /// Session id carried by a local ask banner or a remote session-event push.
    static func navigationSessionId(
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> String? {
        guard sessionCategoryIds.contains(categoryIdentifier) else { return nil }
        guard let sessionId = userInfo["sessionId"] as? String else {
            return nil
        }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func askRequestIdentifier(sessionId: String) -> String {
        "ask-\(sessionId)"
    }

    static func sessionDoneRequestIdentifier(sessionId: String) -> String {
        "done-\(sessionId)"
    }

    /// A store update that moves a top-level session into `done`, matching the server's
    /// `done` push rule: delegated sessions report to their parent, and a first-seen status
    /// is not a transition.
    static func enteredDone(previous: Session?, current: Session) -> Bool {
        guard current.parentSessionId == nil,
              current.programStatus?.state == .done,
              let previousState = previous?.programStatus?.state else {
            return false
        }
        return previousState != .done
    }

    /// A session with neither a name nor a last message: like the server, Oppi posts no alert
    /// that cannot say what it is about.
    static func sessionDoneIsAnonymous(sessionName: String?, lastMessage: String?) -> Bool {
        notificationLine(sessionName) == nil && notificationLine(lastMessage) == nil
    }

    /// One trimmed line, nil when blank, capped at `max` characters like the server's push text.
    static func notificationLine(_ text: String?, max: Int = 240) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count <= max ? line : String(line.prefix(max - 1)) + "\u{2026}"
    }

    /// Local stand-in for the server's `done` push: same title, body, category, and
    /// tap-routing key (`sessionId`). The push names the session; this banner hides the name
    /// and the last message while App Lock or a scoped lock covers it, like ask banners.
    /// Callers skip the banner when `sessionDoneIsAnonymous`.
    static func sessionDonePayload(
        sessionId: String,
        sessionName: String?,
        lastMessage: String? = nil,
        revealsSessionName: Bool
    ) -> AttentionNotificationPayload {
        let name = notificationLine(sessionName)
        let detail = notificationLine(lastMessage)
        let text = PushAlertPresentation.fixedText(event: .done, kind: nil)
        return AttentionNotificationPayload(
            identifier: sessionDoneRequestIdentifier(sessionId: sessionId),
            title: text.title,
            subtitle: revealsSessionName ? (name ?? "") : "",
            body: revealsSessionName ? (detail ?? text.body) : text.body,
            categoryIdentifier: sessionDoneCategoryId,
            userInfo: [
                "event": "done",
                "sessionId": sessionId,
            ],
            threadIdentifier: sessionId,
            targetContentIdentifier: sessionId
        )
    }

    /// Body that names no question text.
    static func redactedAskBody(questionCount: Int) -> String {
        questionCount == 1
            ? String(localized: "Open Oppi to answer a question.")
            : String(localized: "Open Oppi to answer questions.")
    }

    /// - Parameters:
    ///   - sessionName: the session's name or first prompt. When given and revealed, it is the
    ///     subtitle and the body counts the remaining questions; otherwise the subtitle counts them.
    ///   - revealsQuestionText: false while iOS App Lock or a scoped lock is on, so the
    ///     banner, Lock Screen, and Notification Center never show the question or the session.
    static func askPayload(
        for ask: AskRequest,
        sessionName: String? = nil,
        revealsQuestionText: Bool = true
    ) -> AttentionNotificationPayload {
        let questionCount = ask.questions.count
        let first = ask.questions.first
        let firstQuestion = notificationLine(first?.question, max: 500)
        let name = revealsQuestionText ? notificationLine(sessionName, max: 80) : nil
        let countLabel = questionCount == 1 ? String(localized: "1 question") : "\(questionCount) questions"
        let body: String
        if revealsQuestionText, let firstQuestion {
            var lines = [firstQuestion]
            let options = (first?.options ?? []).compactMap { notificationLine($0.label, max: 80) }
            if !options.isEmpty {
                lines.append(options.joined(separator: " \u{00b7} "))
            }
            let more = questionCount - 1
            if name != nil, more > 0 {
                lines.append(more == 1 ? String(localized: "+1 more question") : "+\(more) more questions")
            }
            body = lines.joined(separator: "\n")
        } else {
            body = redactedAskBody(questionCount: questionCount)
        }

        return AttentionNotificationPayload(
            identifier: askRequestIdentifier(sessionId: ask.sessionId),
            title: String(localized: "Question from agent"),
            subtitle: name ?? countLabel,
            body: body,
            categoryIdentifier: askCategoryId,
            userInfo: [
                "kind": "ask",
                "askId": ask.id,
                "sessionId": ask.sessionId,
            ],
            threadIdentifier: ask.sessionId,
            targetContentIdentifier: ask.sessionId
        )
    }
}

struct AttentionNotificationPayload: Equatable, Sendable {
    let identifier: String
    let title: String
    let subtitle: String
    let body: String
    let categoryIdentifier: String
    let userInfo: [String: String]
    let threadIdentifier: String
    let targetContentIdentifier: String
}
