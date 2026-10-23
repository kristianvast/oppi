import Foundation
import SwiftUI
import Testing
@testable import Oppi

@Suite("Session list Your Turn sorting")
struct WorkspaceDetailSortTests {
    private let baseTime = Date(timeIntervalSince1970: 1_700_000_000)

    /// Your Turn rows as every session list sections them.
    private func yourTurn(
        _ entries: [SessionListEntry],
        hasAskInQueue: @escaping (String) -> Bool
    ) -> [SessionListEntry] {
        let attention = { (session: Session) in SessionListAttentionCounts(askCount: hasAskInQueue(session.id) ? 1 : 0) }
        return SessionInboxGrouping.split(
            items: entries,
            session: \.representative,
            attention: { attention($0.session) },
            sectionKind: { $0.sectionKind(attention: attention) },
            isBlocked: { $0.isBlocked(attention: attention) }
        ).yourTurn
    }

    private func yourTurnSorted(_ sessions: [Session], hasAskInQueue: @escaping (String) -> Bool) -> [Session] {
        yourTurn(SessionListEntries.flat(sessions), hasAskInQueue: hasAskInQueue).map(\.session)
    }

    /// A question from a folded child ranks the whole thread like a question on its own row.
    @Test func threadWithAskingChildSortsAboveOlderPlainRow() {
        let plain = makeSession(id: "plain", lastActivity: baseTime)
        let root = makeSession(id: "root", lastActivity: baseTime.addingTimeInterval(60))
        let child = makeSession(id: "child", parent: "root", lastActivity: baseTime.addingTimeInterval(120))
        let sessions = [plain, root, child]

        let rows = yourTurn(
            SessionListEntries.threads(listed: sessions, loaded: sessions),
            hasAskInQueue: { $0 == "child" }
        )

        #expect(rows.map(\.id) == ["root", "plain"])
    }

    private func makeSession(
        id: String,
        parent: String? = nil,
        status: SessionStatus = .ready,
        createdAt: Date? = nil,
        lastActivity: Date? = nil,
        program: ProgramStatus? = nil
    ) -> Session {
        let created = createdAt ?? baseTime
        var session = Session(
            id: id,
            workspaceId: "ws1",
            workspaceName: "Test",
            name: "Session \(id)",
            status: status,
            createdAt: created,
            lastActivity: lastActivity ?? created,
            model: "test/model",
            messageCount: 0,
            tokens: TokenUsage(input: 0, output: 0),
            cost: 0
        )
        session.parentSessionId = parent
        session.programStatus = program
        return session
    }

    private func blocked(_ kind: ProgramStatusKind) -> ProgramStatus {
        ProgramStatus(state: .blocked, kind: kind, since: baseTime)
    }

    /// Blocked comes from the server's program status, so an editor dialog (blocked, kind
    /// question) sorts like an ask and needs no pending-ask count.
    @Test func blockedSessionsSortAheadOfOlderPlainRowsWithoutAnAskCount() {
        let plain = makeSession(id: "plain", lastActivity: baseTime.addingTimeInterval(-300))
        let approval = makeSession(id: "approval", lastActivity: baseTime, program: blocked(.permission))
        let editor = makeSession(id: "editor", lastActivity: baseTime.addingTimeInterval(60), program: blocked(.question))
        let done = makeSession(
            id: "done",
            lastActivity: baseTime.addingTimeInterval(-600),
            program: ProgramStatus(state: .done, since: baseTime)
        )

        let sorted = yourTurnSorted([plain, done, editor, approval], hasAskInQueue: { _ in false })

        // Blocked first (oldest activity first among them), then done and idle in the existing order.
        #expect(sorted.map(\.id) == ["approval", "editor", "done", "plain"])
    }

    @Test func threadWithABlockedChildSortsAsBlocked() {
        let plain = makeSession(id: "plain", lastActivity: baseTime.addingTimeInterval(-300))
        let root = makeSession(id: "root", lastActivity: baseTime)
        let child = makeSession(id: "child", parent: "root", program: blocked(.auth))
        let sessions = [plain, root, child]

        let rows = yourTurn(
            SessionListEntries.threads(listed: sessions, loaded: sessions),
            hasAskInQueue: { _ in false }
        )

        #expect(rows.map(\.id) == ["root", "plain"])
    }

    @Test func sameTier_olderVisibleActivityComesFirst() {
        let older = makeSession(id: "older", lastActivity: baseTime)
        let newer = makeSession(id: "newer", lastActivity: baseTime.addingTimeInterval(60))

        let sorted = yourTurnSorted(
            [newer, older],
            hasAskInQueue: { _ in false }
        )

        #expect(sorted.map(\.id) == ["older", "newer"])
    }

    @Test func visibleActivityWinsOverCreationTime() {
        let createdEarlierButNewerActivity = makeSession(
            id: "created-first",
            createdAt: baseTime,
            lastActivity: baseTime.addingTimeInterval(120)
        )
        let createdLaterButOlderActivity = makeSession(
            id: "activity-first",
            createdAt: baseTime.addingTimeInterval(60),
            lastActivity: baseTime.addingTimeInterval(30)
        )

        let sorted = yourTurnSorted(
            [createdEarlierButNewerActivity, createdLaterButOlderActivity],
            hasAskInQueue: { _ in false }
        )

        #expect(sorted.map(\.id) == ["activity-first", "created-first"])
    }

    @Test func asksStayAheadOfPlainSessions() {
        let ask = makeSession(id: "ask", lastActivity: baseTime)
        let plain = makeSession(id: "plain", lastActivity: baseTime.addingTimeInterval(-120))

        let sorted = yourTurnSorted(
            [plain, ask],
            hasAskInQueue: { $0 == "ask" }
        )

        #expect(sorted.map(\.id) == ["ask", "plain"])
    }

    @Test func equalVisibleActivityFallsBackToCreationTime() {
        let older = makeSession(
            id: "older",
            createdAt: baseTime,
            lastActivity: baseTime.addingTimeInterval(30)
        )
        let newer = makeSession(
            id: "newer",
            createdAt: baseTime.addingTimeInterval(60),
            lastActivity: baseTime.addingTimeInterval(30)
        )

        let sorted = yourTurnSorted(
            [newer, older],
            hasAskInQueue: { _ in false }
        )

        #expect(sorted.map(\.id) == ["older", "newer"])
    }

    @Test func liveHomeMirrorSessionsSortAheadOfOtherMirrorsAndPlainSessionsWithinTier() {
        var plain = makeSession(id: "plain", lastActivity: baseTime.addingTimeInterval(-300))
        plain.workspaceName = "Project"

        var projectMirror = makeSession(id: "project-mirror", lastActivity: baseTime.addingTimeInterval(-120))
        projectMirror.workspaceName = "Project"
        projectMirror.runtime = .piTui
        projectMirror.mirror = PiTuiMirrorSessionMetadata(status: "connected")

        var homeMirror = makeSession(id: "home-mirror", lastActivity: baseTime)
        homeMirror.workspaceName = "Home"
        homeMirror.runtime = .piTui
        homeMirror.mirror = PiTuiMirrorSessionMetadata(status: "connected")

        var disconnectedHomeMirror = makeSession(id: "disconnected-home", lastActivity: baseTime.addingTimeInterval(-600))
        disconnectedHomeMirror.workspaceName = "Home"
        disconnectedHomeMirror.runtime = .piTui
        disconnectedHomeMirror.mirror = PiTuiMirrorSessionMetadata(status: "disconnected")

        let sorted = yourTurnSorted(
            [plain, disconnectedHomeMirror, projectMirror, homeMirror],
            hasAskInQueue: { _ in false }
        )

        #expect(sorted.map(\.id) == ["home-mirror", "project-mirror", "disconnected-home", "plain"])
    }

    @Test func workingSectionPromotesLiveHomeMirrorsBeforeOtherWorkingSessions() {
        var newerManaged = makeSession(
            id: "managed",
            status: .busy,
            createdAt: baseTime.addingTimeInterval(120),
            lastActivity: baseTime.addingTimeInterval(120)
        )
        newerManaged.workspaceName = "Project"

        var olderHomeMirror = makeSession(
            id: "home-mirror",
            status: .busy,
            createdAt: baseTime,
            lastActivity: baseTime
        )
        olderHomeMirror.workspaceName = "Home"
        olderHomeMirror.runtime = .piTui
        olderHomeMirror.mirror = PiTuiMirrorSessionMetadata(status: "connected")

        let split = SessionInboxGrouping.split(
            items: SessionListEntries.flat([newerManaged, olderHomeMirror]),
            session: \.representative,
            attention: { _ in .none }
        )

        #expect(split.working.map(\.id) == ["home-mirror", "managed"])
    }

    @Test func workspaceListPromotesHomeWhenIdleCountsAndActivityTie() {
        let alpha = Workspace(id: "w-alpha", name: "Alpha", createdAt: baseTime, updatedAt: baseTime)
        let home = Workspace(id: "w-home", name: "Home", createdAt: baseTime, updatedAt: baseTime)
        let sorted = sortedWorkspacesForList([alpha, home], summaries: [:])

        #expect(sorted.map(\.id) == ["w-home", "w-alpha"])
    }

    @Test func deleteConfirmationClearsPendingBeforeDeleteCallback() {
        let session = makeSession(id: "delete-me")
        var pendingSession: Session? = session
        var didDelete = false
        var pendingWasClearedBeforeDelete = false

        SessionDeleteConfirmationPolicy.confirm(
            session: session,
            clearPending: { pendingSession = nil },
            performDelete: { deleted in
                didDelete = deleted.id == session.id
                pendingWasClearedBeforeDelete = pendingSession == nil
            }
        )

        #expect(didDelete)
        #expect(pendingSession == nil)
        #expect(pendingWasClearedBeforeDelete)
    }

    @Test func deleteSwipeActionOnlyOpensConfirmation() {
        #expect(SessionDeleteConfirmationPolicy.swipeButtonRole == nil)
    }

    @Test func knownWorkspaceNotFoundDoesNotPresentBlockingLoadError() {
        let shouldPresent = WorkspaceDetailLoadErrorPolicy.shouldPresent(
            error: APIError.server(status: 404, message: "Workspace not found"),
            workspaceId: "ws-known",
            hadVisibleData: false,
            knownWorkspaceIds: ["ws-known"]
        )

        #expect(!shouldPresent)
    }

    @Test func unknownWorkspaceNotFoundStillPresentsLoadError() {
        let shouldPresent = WorkspaceDetailLoadErrorPolicy.shouldPresent(
            error: APIError.server(status: 404, message: "Workspace not found"),
            workspaceId: "ws-missing",
            hadVisibleData: false,
            knownWorkspaceIds: ["ws-known"]
        )

        #expect(shouldPresent)
    }
}

@Suite("Workspace Delete Confirmation")
struct WorkspaceDeleteConfirmationTests {
    @Test func confirmationCopyRemovesRecordKeepsFilesAndWarnsSessions() {
        let message = WorkspaceDeleteConfirmationPolicy.deleteMessage(
            for: makeTestWorkspace(id: "ws-notes", name: "Notes")
        )

        #expect(
            message
                == "This removes the Oppi workspace record for \"Notes\". Files on disk stay. Sessions in this workspace may become unreachable."
        )
    }

    @Test func deleteSwipeActionOnlyOpensConfirmation() {
        #expect(WorkspaceDeleteConfirmationPolicy.swipeButtonRole == nil)
    }

    @Test func deleteConfirmationClearsPendingBeforeDeleteCallback() {
        let workspace = makeTestWorkspace(id: "ws-delete", name: "Delete Me")
        var pendingWorkspace: Workspace? = workspace
        var didDelete = false
        var pendingWasClearedBeforeDelete = false

        WorkspaceDeleteConfirmationPolicy.confirm(
            workspace: workspace,
            clearPending: { pendingWorkspace = nil },
            performDelete: { deleted in
                didDelete = deleted.id == workspace.id
                pendingWasClearedBeforeDelete = pendingWorkspace == nil
            }
        )

        #expect(didDelete)
        #expect(pendingWorkspace == nil)
        #expect(pendingWasClearedBeforeDelete)
    }
}

@Suite("Workspace icon picker catalog")
struct WorkspaceIconPickerCatalogTests {
    @Test func emptySearchReturnsEveryCuratedSymbol() {
        #expect(IconSymbolCatalog.availableOptions(matching: "").count == IconSymbolCatalog.options.count)
    }

    @Test func searchMatchesLabelsAndSymbolNamesCaseInsensitively() {
        #expect(IconSymbolCatalog.availableOptions(matching: "CODE").contains { $0.symbolName == "chevron.left.forwardslash.chevron.right" })
        #expect(IconSymbolCatalog.availableOptions(matching: "branch").contains { $0.symbolName == "arrow.triangle.branch" })
    }

    @Test func unmatchedSearchReturnsNoSymbols() {
        #expect(IconSymbolCatalog.availableOptions(matching: "definitely-not-an-icon").isEmpty)
    }

    @Test func curatedSymbolsResolveToHumanFacingLabels() {
        #expect(IconSymbolCatalog.label(for: "chevron.left.forwardslash.chevron.right") == "Code")
        #expect(IconSymbolCatalog.label(for: "🧠") == nil)
    }
}

@Suite("Workspace Pi Resource Error Policy")
struct WorkspacePiResourceErrorPolicyTests {
    @Test func cancellationDoesNotPresentAsSettingsError() {
        #expect(!WorkspacePiResourceErrorPolicy.shouldPresent(CancellationError()))
        #expect(!WorkspacePiResourceErrorPolicy.shouldPresent(URLError(.cancelled)))
    }

    @Test func nonCancellationErrorPresentsAsSettingsError() {
        #expect(WorkspacePiResourceErrorPolicy.shouldPresent(URLError(.notConnectedToInternet)))
        #expect(WorkspacePiResourceErrorPolicy.shouldPresent(APIError.server(status: 500, message: "boom")))
    }
}
