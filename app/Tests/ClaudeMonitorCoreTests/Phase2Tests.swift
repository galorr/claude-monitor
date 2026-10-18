import Foundation
import Testing
@testable import ClaudeMonitorCore

/// Notifications, review and the sweeper (spec Phase 2, decisions.md D-011).
@Suite struct SweeperTests {
    let settings = MonitorSettings()
    let alive: (Int) -> Bool = { _ in true }

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    @Test func workingGoesStaleAfterTenQuietMinutes() {
        var s = store([event("UserPromptSubmit", at: 0)])
        #expect(s.sweep(now: at(599), settings: settings, isAlive: alive).isEmpty)
        let changes = s.sweep(now: at(601), settings: settings, isAlive: alive)
        #expect(changes == [StateChange(sessionId: "s1", from: .working, to: .stale, at: at(601))])
        #expect(s.sessions["s1"]?.state == .stale)
    }

    @Test(arguments: [SessionState.needsPermission, .waitingInput, .doneUnreviewed])
    func onlyWorkingGoesStale(state: SessionState) {
        var s = store([event("UserPromptSubmit", at: 0), stateEvent(state, at: 1)])
        #expect(s.sessions["s1"]?.state == state)
        #expect(s.sweep(now: at(3600), settings: settings, isAlive: alive).isEmpty)
    }

    @Test(arguments: [SessionState.idle, .working, .needsPermission, .waitingInput, .doneUnreviewed, .reviewed])
    func anyOpenStateIsPresumedDeadAfterSixHours(state: SessionState) {
        var s = store([event("SessionStart", at: 0), stateEvent(state, at: 1)])
        if state == .reviewed { s.markReviewed("s1", at: at(2)) }
        _ = s.sweep(now: at(6 * 3600), settings: settings, isAlive: alive)
        #expect(s.sessions["s1"]?.state != .presumedDead)
        _ = s.sweep(now: at(6 * 3600 + 2), settings: settings, isAlive: alive)
        #expect(s.sessions["s1"]?.state == .presumedDead)
    }

    @Test func killedTerminalIsPresumedDeadOnNextSweep() {
        // Spec Phase 2 test: kill a terminal mid-session → presumed_dead, not stuck in working.
        var s = store([event("UserPromptSubmit", at: 0, ["claude_pid": 4242, "tty": "ttys009"])])
        let changes = s.sweep(now: at(30), settings: settings, isAlive: { $0 != 4242 })
        #expect(changes.map(\.to) == [.presumedDead])
        #expect(s.sessions["s1"]?.state == .presumedDead)
    }

    @Test func finishedSessionKeepsItsResultWhenTheProcessExits() {
        var s = store([event("UserPromptSubmit", at: 0, ["claude_pid": 4242]), event("Stop", at: 1)])
        #expect(s.sweep(now: at(30), settings: settings, isAlive: { _ in false }).isEmpty)
        #expect(s.sessions["s1"]?.state == .doneUnreviewed)
    }

    @Test func sessionWithoutPidIsOnlyJudgedByTime() {
        var s = store([event("UserPromptSubmit", at: 0)])
        #expect(s.sweep(now: at(30), settings: settings, isAlive: { _ in false }).isEmpty)
    }

    @Test func closedSessionsAreNotSwept() {
        var s = store([event("SessionEnd", at: 0, ["claude_pid": 1])])
        #expect(s.sweep(now: at(7 * 86400), settings: settings, isAlive: { _ in false }).isEmpty)
        #expect(s.sessions["s1"]?.state == .closed)
    }

    @Test func eventAfterPresumedDeadRevivesTheSession() {
        var s = store([event("UserPromptSubmit", at: 0, ["claude_pid": 7])])
        _ = s.sweep(now: at(10), settings: settings, isAlive: { _ in false })
        s.apply(event("PostToolUse", at: 20, ["claude_pid": 8]))
        #expect(s.sessions["s1"]?.state == .working)
        #expect(s.sessions["s1"]?.claudePid == 8)
    }

    @Test func thresholdsComeFromSettings() {
        var custom = MonitorSettings()
        custom.staleAfterMinutes = 1
        var s = store([event("UserPromptSubmit", at: 0)])
        #expect(s.sweep(now: at(61), settings: custom, isAlive: alive).map(\.to) == [.stale])
    }

    @Test func endedSessionsAreHiddenAfterADay() {
        var s = store([
            event("SessionEnd", session: "old", at: 0),
            event("SessionEnd", session: "recent", at: 80000),
            event("Stop", session: "doneOld", at: 0),
        ])
        _ = s.sweep(now: at(1), settings: settings, isAlive: alive)
        let ids = s.visible(now: at(86401), settings: settings).map(\.id)
        #expect(ids == ["doneOld", "recent"])
    }

    func stateEvent(_ state: SessionState, at seconds: Double) -> HookEvent {
        switch state {
        case .needsPermission: event("PermissionRequest", at: seconds, ["tool_name": "Bash"])
        case .waitingInput: event("Notification", at: seconds, ["notification_type": "elicitation_dialog"])
        case .doneUnreviewed, .reviewed: event("Stop", at: seconds)
        case .working: event("UserPromptSubmit", at: seconds)
        default: event("SessionStart", at: seconds)
        }
    }
}

@Suite struct ReviewTests {
    @Test func reviewAllOnlyTouchesDoneSessions() {
        var s = store([
            event("Stop", session: "a", at: 0),
            event("Stop", session: "b", at: 1),
            event("Notification", session: "c", at: 2, ["notification_type": "elicitation_dialog"]),
            event("UserPromptSubmit", session: "d", at: 3),
        ])
        #expect(s.markAllDoneReviewed(at: t0.addingTimeInterval(4)) == 2)
        #expect(s.sessions["a"]?.state == .reviewed)
        #expect(s.sessions["b"]?.state == .reviewed)
        #expect(s.sessions["c"]?.state == .waitingInput)
        #expect(s.sessions["d"]?.state == .working)
        #expect(s.attentionCount == 1)
    }
}

@Suite struct NotificationTests {
    let now = t0.addingTimeInterval(100)

    @Test func applyReportsStateChanges() {
        var s = SessionStore()
        #expect(s.apply(event("SessionStart", at: 0)) == StateChange(sessionId: "s1", from: nil, to: .idle, at: t0))
        #expect(s.apply(event("PostToolUse", at: 1)) != nil)  // idle → working
        #expect(s.apply(event("PostToolUse", at: 2)) == nil)  // still working
        s.apply(event("Stop", at: 3))
        // The 60s idle reminder after Stop changes nothing, so it cannot notify twice.
        #expect(s.apply(event("Notification", at: 63, ["notification_type": "idle_prompt"])) == nil)
        #expect(s.apply(event("UserPromptSubmit", at: 1)) == nil)  // late event
    }

    @Test(arguments: [
        (SessionState.needsPermission, true), (.waitingInput, true), (.doneUnreviewed, true),
        (.working, false), (.idle, false), (.stale, false), (.presumedDead, false), (.closed, false),
    ])
    func onlyAttentionStatesNotify(to: SessionState, expected: Bool) {
        let change = StateChange(sessionId: "s1", from: .working, to: to, at: now)
        #expect(NotificationPolicy.shouldNotify(change, now: now) == expected)
    }

    @Test func oldChangesStaySilent() {
        let change = StateChange(sessionId: "s1", from: .working, to: .doneUnreviewed, at: t0)
        #expect(NotificationPolicy.shouldNotify(change, now: t0.addingTimeInterval(299)))
        #expect(!NotificationPolicy.shouldNotify(change, now: t0.addingTimeInterval(301)))
    }

    @Test func permissionApprovedWithinTheBatchIsSilent() {
        var s = SessionStore()
        let lines = [
            event("UserPromptSubmit", at: 0),
            event("PermissionRequest", at: 1, ["tool_name": "Bash"]),
            event("PostToolUse", at: 2, ["tool_name": "Bash"]),
        ]
        let changes = lines.compactMap { s.apply($0) }
        #expect(MonitorEngine.sessionsToNotify(changes, store: s, now: now).isEmpty)
    }

    @Test func oneNotificationPerSessionPerBatch() {
        var s = SessionStore()
        let changes = [
            event("PermissionRequest", at: 1, ["tool_name": "Bash"]),
            event("Notification", at: 7, ["notification_type": "permission_prompt"]),
            event("Stop", session: "other", at: 8),
        ].compactMap { s.apply($0) }
        let notify = MonitorEngine.sessionsToNotify(changes, store: s, now: now)
        #expect(notify.map(\.id) == ["s1", "other"])
        #expect(notify.first?.lastMessage == "Permission: Bash")
    }

    @Test func replayingTheCaptureAtLaunchNotifiesNobody() throws {
        var s = SessionStore()
        let changes = MonitorEngine.process(try Fixture.lines(), into: &s).changes
        #expect(!changes.isEmpty)
        #expect(MonitorEngine.sessionsToNotify(changes, store: s, now: Date()).isEmpty)
    }

    @Test func contentUsesRepoStateTaskAndMessage() {
        let s = store([
            event("SessionStart", at: 0, ["git_root": "/x/app", "git_branch": "epic/PROJ-7/T3"]),
            event("PermissionRequest", at: 1, ["tool_name": "Write"]),
        ]).sessions["s1"]!
        let c = NotificationPolicy.content(for: s)
        #expect(c.title == "app: Needs permission (T3)")
        #expect(c.body == "Permission: Write")
    }
}

@Suite struct EngineSweepTests {
    @Test func engineMarksAKilledSessionDeadAndPublishesIt() async throws {
        let dir = try tempDir()
        let paths = AppPaths(eventsFile: dir.appending(path: "events.jsonl"),
                             snapshotFile: dir.appending(path: "state.json"),
                             logFile: dir.appending(path: "app.log"))
        let line = #"{"session_id":"s1","hook_event_name":"UserPromptSubmit","ts":"2027-01-15T08:00:00.000Z","claude_pid":4242}"#
        try Data((line + "\n").utf8).write(to: paths.eventsFile)

        let updates = AsyncStream<MonitorEngine.Update>.makeStream()
        let engine = MonitorEngine(paths: paths, log: AppLog(url: paths.logFile),
                                   isAlive: { $0 != 4242 },
                                   now: { Date(timeIntervalSince1970: 1_800_000_000) })
        engine.start { updates.continuation.yield($0) }
        defer { engine.stop() }

        // Initial publish, ingest, then the launch sweep.
        var last: MonitorEngine.Update?
        for await u in updates.stream {
            last = u
            if u.sessions.first?.state == .presumedDead { break }
        }
        #expect(last?.sessions.first?.state == .presumedDead)
        #expect(last?.notify.isEmpty == true)
        let log = try String(contentsOf: paths.logFile, encoding: .utf8)
        #expect(log.contains("working → presumed_dead"))
    }
}
