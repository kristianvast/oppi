import Testing
@testable import Oppi

@Suite("AttentionNotificationService")
@MainActor
struct AttentionNotificationServiceTests {

    @Test func notifiesWhenAppIsBackgrounded() {
        #expect(
            AttentionNotificationService.shouldNotify(
                isAppActive: false,
                requestSessionId: "s1",
                activeSessionId: "s1"
            )
        )
    }

    @Test func askBannerNamesSessionAndListsChoices() {
        let ask = AskRequest(
            id: "ask-1",
            sessionId: "s1",
            questions: [
                AskQuestion(
                    id: "q1",
                    question: " Which database? ",
                    options: [AskOption(value: "pg", label: "Postgres"), AskOption(value: "lite", label: "SQLite")],
                    multiSelect: false
                ),
                AskQuestion(id: "q2", question: "Migrate now?", options: [], multiSelect: false),
            ],
            allowCustom: true,
            timeout: nil
        )

        let payload = AttentionNotificationPolicy.askPayload(for: ask, sessionName: "Fix login")
        #expect(payload.subtitle == "Fix login")
        #expect(payload.body == "Which database?\nPostgres \u{00b7} SQLite\n+1 more question")

        // A lock hides the session and the question alike.
        let locked = AttentionNotificationPolicy.askPayload(
            for: ask,
            sessionName: "Fix login",
            revealsQuestionText: false
        )
        #expect(locked.subtitle == "2 questions")
        #expect(locked.body == AttentionNotificationPolicy.redactedAskBody(questionCount: 2))
    }

    @Test func doneBannerSaysWhatFinishedOrIsSkipped() {
        #expect(AttentionNotificationPolicy.sessionDoneIsAnonymous(sessionName: " ", lastMessage: nil))
        #expect(!AttentionNotificationPolicy.sessionDoneIsAnonymous(sessionName: nil, lastMessage: "Fixed it."))

        let payload = AttentionNotificationPolicy.sessionDonePayload(
            sessionId: "s1",
            sessionName: "Fix login",
            lastMessage: "Fixed the\n\nlogin test.",
            revealsSessionName: true
        )
        #expect(payload.subtitle == "Fix login")
        #expect(payload.body == "Fixed the login test.")

        let locked = AttentionNotificationPolicy.sessionDonePayload(
            sessionId: "s1",
            sessionName: "Fix login",
            lastMessage: "Fixed the login test.",
            revealsSessionName: false
        )
        #expect(locked.subtitle.isEmpty)
        #expect(locked.body == PushAlertPresentation.fixedText(event: .done, kind: nil).body)
    }

    @Test func notifiesWhenForegroundedForDifferentSession() {
        #expect(
            AttentionNotificationService.shouldNotify(
                isAppActive: true,
                requestSessionId: "s2",
                activeSessionId: "s1"
            )
        )
    }

    @Test func doesNotNotifyWhenForegroundedForActiveSession() {
        #expect(
            !AttentionNotificationService.shouldNotify(
                isAppActive: true,
                requestSessionId: "s1",
                activeSessionId: "s1"
            )
        )
    }

    @Test func notifiesWhenForegroundedWithoutActiveSession() {
        #expect(
            AttentionNotificationService.shouldNotify(
                isAppActive: true,
                requestSessionId: "s1",
                activeSessionId: nil
            )
        )
    }

    @Test func tapBeforeNavigationHandlerIsDeliveredOnceWhenWired() {
        let service = AttentionNotificationService.shared
        service.onNavigateToSession = nil
        var deliveredSessionIds: [String] = []

        service.handleAskNotificationTap(sessionId: "ask-session")
        #expect(deliveredSessionIds.isEmpty)

        service.onNavigateToSession = { deliveredSessionIds.append($0) }
        #expect(deliveredSessionIds == ["ask-session"])

        service.onNavigateToSession = { deliveredSessionIds.append($0) }
        #expect(deliveredSessionIds == ["ask-session"])
        service.onNavigateToSession = nil
    }

    @Test func navigationSessionIdReadsAskAndRemoteSessionPayloads() {
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: AttentionNotificationService.askCategoryId,
                userInfo: ["sessionId": "ask-session"]
            ) == "ask-session"
        )
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: AttentionNotificationService.sessionDoneCategoryId,
                userInfo: ["sessionId": "ended-session"]
            ) == "ended-session"
        )
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: AttentionNotificationService.sessionErrorCategoryId,
                userInfo: ["sessionId": "error-session"]
            ) == "error-session"
        )
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: AttentionNotificationService.sessionBlockedCategoryId,
                userInfo: ["sessionId": "blocked-session", "event": "blocked", "kind": "permission"]
            ) == "blocked-session"
        )
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: AttentionNotificationService.askCategoryId,
                userInfo: ["sessionId": "  "]
            ) == nil
        )
        #expect(
            AttentionNotificationService.navigationSessionId(
                categoryIdentifier: "OTHER",
                userInfo: ["sessionId": "ignored"]
            ) == nil
        )
    }
}

@Suite("Invite pairing gate")
struct InvitePairingGateTests {
    @Test func secondInviteProceedsWhilePreviousAttemptIsInFlight() {
        var gate = InvitePairingGate()
        let first = gate.beginIncoming()
        gate.markStarted(first)
        #expect(gate.inFlight)

        let second = gate.beginIncoming()
        #expect(gate.shouldRun(second))
        #expect(!gate.shouldRun(first))

        gate.markStarted(second)
        #expect(gate.inFlight)
        gate.markFinished(first)
        #expect(gate.inFlight)
        gate.markFinished(second)
        #expect(!gate.inFlight)
    }
}

@Suite("Session deep-link navigation policy")
struct SessionDeepLinkNavigationPolicyTests {
    @Test func unavailableNotificationDuringLaunchIsParked() {
        let disposition = SessionDeepLinkNavigationPolicy.disposition(
            sessionIsAvailable: false,
            launchPhase: .resolving,
            startupComplete: false,
            inviteBootstrapInFlight: false,
            parkingAllowed: true
        )

        #expect(disposition == .park)
    }

    @Test func parkedNotificationOpensAfterLaunchPopulatesSession() {
        let launchDisposition = SessionDeepLinkNavigationPolicy.disposition(
            sessionIsAvailable: false,
            launchPhase: .resolving,
            startupComplete: false,
            inviteBootstrapInFlight: false,
            parkingAllowed: true
        )
        let consumedDisposition = SessionDeepLinkNavigationPolicy.disposition(
            sessionIsAvailable: true,
            launchPhase: .ready,
            startupComplete: true,
            inviteBootstrapInFlight: false,
            parkingAllowed: false
        )

        #expect(launchDisposition == .park)
        #expect(consumedDisposition == .open)
    }

    @Test func unavailableNotificationParksAfterUIIsReadyWhileStartupContinues() {
        let disposition = SessionDeepLinkNavigationPolicy.disposition(
            sessionIsAvailable: false,
            launchPhase: .ready,
            startupComplete: false,
            inviteBootstrapInFlight: false,
            parkingAllowed: true
        )

        #expect(disposition == .park)
    }

    @Test func unavailableNotificationFallsBackAfterStartupCompletes() {
        let disposition = SessionDeepLinkNavigationPolicy.disposition(
            sessionIsAvailable: false,
            launchPhase: .ready,
            startupComplete: true,
            inviteBootstrapInFlight: false,
            parkingAllowed: true
        )

        #expect(disposition == .showWorkspaceRoot)
    }

    @Test @MainActor func startupCompletionIsMarkedAfterStartupWorkFinishes() async {
        var events: [String] = []

        await AppStartupSequence.run(
            startupWork: {
                events.append("session_refresh_started")
                await Task.yield()
                events.append("session_refresh_finished")
            },
            markComplete: {
                events.append("startup_complete")
            }
        )

        #expect(events == [
            "session_refresh_started",
            "session_refresh_finished",
            "startup_complete",
        ])
    }
}

@Suite("Session deep-link session resolution")
struct SessionDeepLinkSessionResolutionTests {
    @Test func fetchServerIdsPrefersActiveThenAskOwners() {
        #expect(
            SessionDeepLinkSessionResolution.fetchServerIds(
                activeServerId: "active",
                serverIdsWithPendingAsk: ["ask-owner", "active"]
            ) == ["active", "ask-owner"]
        )
        #expect(
            SessionDeepLinkSessionResolution.fetchServerIds(
                activeServerId: nil,
                serverIdsWithPendingAsk: ["ask-owner"]
            ) == ["ask-owner"]
        )
        #expect(
            SessionDeepLinkSessionResolution.fetchServerIds(
                activeServerId: "active",
                serverIdsWithPendingAsk: []
            ) == ["active"]
        )
    }
}

@Suite("Session notification open path")
@MainActor
struct SessionNotificationOpenPathTests {
    @Test func tapOpensBusySessionWithStreamJSONAskAndRoute() async throws {
        let sessionId = AttentionNotificationService.navigationSessionId(
            categoryIdentifier: AttentionNotificationService.askCategoryId,
            userInfo: ["sessionId": "child"]
        )
        let openedSessionId = try #require(sessionId)

        let (connection, _) = makeTestConnection(sessionId: "parent")
        connection.setSplitStreamCapabilitiesForTesting(sessionStream: true)
        connection.sessionStore.upsert(
            makeTestSession(id: "parent", workspaceId: "w1", status: .busy)
        )
        connection.sessionStore.upsert(
            makeTestSession(id: openedSessionId, workspaceId: "w1", status: .stopped)
        )

        var streamConnects = 0
        connection._connectStreamForTesting = {
            streamConnects += 1
            return AsyncStream { _ in }
        }
        connection._getSessionRecordForTesting = { id in
            makeTestSession(id: id, workspaceId: "w1", name: "Child", status: .busy)
        }
        connection._getSessionDialogsForTesting = { _ in
            APIClient.SessionDialogsResponse(
                dialogs: [
                    ExtensionUIRequest.DialogSnapshot(
                        id: "ask-live",
                        method: "ask",
                        questions: [
                            AskQuestion(
                                id: "q1",
                                question: "Answer me",
                                options: [],
                                multiSelect: false
                            ),
                        ],
                        allowCustom: true
                    ),
                ],
                serverNow: 1
            )
        }

        let navigation = AppNavigation()
        navigation.launchPhase = .ready
        navigation.showQuickSession = true
        QuickSessionTrigger.shared.isPresented = true
        navigation.openWorkspaceSession(.init(
            serverId: "server-1",
            sessionId: "parent",
            workspaceId: "w1"
        ))

        await SessionNotificationOpen.openResolved(
            sessionId: openedSessionId,
            serverId: "server-1",
            connection: connection,
            navigation: navigation,
            source: .externalURL
        )

        #expect(!navigation.showQuickSession)
        #expect(!QuickSessionTrigger.shared.isPresented)
        #expect(navigation.workspaceStackDiagnosticContext.sessionId == "child")
        #expect(navigation.workspacePath.count == 1)
        #expect(connection.focusedSessionId == "child")
        #expect(connection.sessionStore.session(id: "child")?.status == .busy)
        #expect(connection.focusedSessionStreamURLForTesting?.path == "/workspaces/w1/sessions/child/stream")
        #expect(streamConnects == 1)
        #expect(ChatView.resolvedComposerAskRequest(
            connection.askRequestStore.pending(for: "child"),
            hasReviewComment: false
        )?.id == "ask-live")

        connection.disconnectStream()
    }
}
