import Foundation
import Testing
@testable import ClaudeMonitorCore

@Suite struct StateMachineTests {
    @Test func specHappyPath() {
        var s = SessionStore()
        s.apply(event("SessionStart", at: 0, ["source": "startup"]))
        #expect(s.sessions["s1"]?.state == .idle)
        s.apply(event("UserPromptSubmit", at: 1, ["prompt": "hi"]))
        #expect(s.sessions["s1"]?.state == .working)
        s.apply(event("Notification", at: 2, ["notification_type": "permission_prompt", "message": "Allow?"]))
        #expect(s.sessions["s1"]?.state == .needsPermission)
        s.apply(event("PostToolUse", at: 3, ["tool_name": "Bash"]))
        #expect(s.sessions["s1"]?.state == .working)
        s.apply(event("Stop", at: 4, ["last_assistant_message": "done"]))
        #expect(s.sessions["s1"]?.state == .doneUnreviewed)
        let reviewed = s.markReviewed("s1", at: t0.addingTimeInterval(5))
        #expect(reviewed)
        #expect(s.sessions["s1"]?.state == .reviewed)
        s.apply(event("SessionEnd", at: 6, ["reason": "prompt_input_exit"]))
        #expect(s.sessions["s1"]?.state == .closed)
    }

    @Test func idlePromptAfterStopIsOnlyAReminder() {
        let s = store([
            event("UserPromptSubmit", at: 0),
            event("Stop", at: 1),
            event("Notification", at: 61, ["notification_type": "idle_prompt", "message": "Claude is waiting for your input"]),
        ])
        #expect(s.sessions["s1"]?.state == .doneUnreviewed)
    }

    @Test func idlePromptAfterReviewStaysReviewed() {
        var s = store([event("UserPromptSubmit", at: 0), event("Stop", at: 1)])
        s.markReviewed("s1", at: t0.addingTimeInterval(2))
        s.apply(event("Notification", at: 61, ["notification_type": "idle_prompt"]))
        #expect(s.sessions["s1"]?.state == .reviewed)
    }

    @Test(arguments: ["idle_prompt", "elicitation_dialog", "agent_needs_input"])
    func inputNotificationsWhileWorkingWaitForInput(type: String) {
        let s = store([event("UserPromptSubmit", at: 0), event("Notification", at: 1, ["notification_type": type])])
        #expect(s.sessions["s1"]?.state == .waitingInput)
    }

    @Test func unknownNotificationTypeChangesNothing() {
        let s = store([event("UserPromptSubmit", at: 0), event("Notification", at: 1, ["notification_type": "auth_success"])])
        #expect(s.sessions["s1"]?.state == .working)
    }

    @Test func permissionRequestThenNotificationThenApproval() {
        let s1 = store([event("UserPromptSubmit", at: 0), event("PermissionRequest", at: 1, ["tool_name": "Bash"])])
        #expect(s1.sessions["s1"]?.state == .needsPermission)
        #expect(s1.sessions["s1"]?.lastMessage == "Permission: Bash")
        let s2 = store([
            event("UserPromptSubmit", at: 0), event("PermissionRequest", at: 1, ["tool_name": "Bash"]),
            event("Notification", at: 7, ["notification_type": "permission_prompt"]),
            event("PostToolUse", at: 9, ["tool_name": "Bash"]),
        ])
        #expect(s2.sessions["s1"]?.state == .working)
        #expect(s2.sessions["s1"]?.lastMessage == "Permission: Bash")
    }

    @Test func permissionNotificationAloneSetsItsMessage() {
        let s = store([event("UserPromptSubmit", at: 0),
                       event("Notification", at: 1, ["notification_type": "permission_prompt", "message": "Allow?"])])
        #expect(s.sessions["s1"]?.lastMessage == "Allow?")
    }

    @Test func postToolUseDoesNotReopenAFinishedTurn() {
        let s = store([event("UserPromptSubmit", at: 0), event("Stop", at: 2), event("PostToolUse", at: 3)])
        #expect(s.sessions["s1"]?.state == .doneUnreviewed)
    }

    @Test func stopFailureEndsTheTurnWithTheError() {
        let s = store([event("UserPromptSubmit", at: 0), event("StopFailure", at: 1, ["error": "rate_limit"])])
        #expect(s.sessions["s1"]?.state == .doneUnreviewed)
        #expect(s.sessions["s1"]?.lastMessage == "rate_limit")
    }

    @Test func compactionMidTurnKeepsWorking() {
        let s = store([event("UserPromptSubmit", at: 0), event("SessionStart", at: 1, ["source": "compact"])])
        #expect(s.sessions["s1"]?.state == .working)
    }

    @Test func clearResetsToIdle() {
        let s = store([event("UserPromptSubmit", at: 0), event("Stop", at: 1), event("SessionStart", at: 2, ["source": "clear"])])
        #expect(s.sessions["s1"]?.state == .idle)
    }

    @Test func lateEventUpdatesMetadataButNotState() {
        let s = store([
            event("Stop", at: 10),
            event("UserPromptSubmit", at: 5, ["cwd": "/tmp/repo", "prompt": "old"]),
        ])
        let session = s.sessions["s1"]
        #expect(session?.state == .doneUnreviewed)
        #expect(session?.lastEventAt == t0.addingTimeInterval(10))
        #expect(session?.cwd == "/tmp/repo")
        #expect(session?.lastMessage == nil)
    }

    @Test func markReviewedOnlyFromReviewableStates() {
        var s = store([event("UserPromptSubmit", at: 0)])
        let notWorking = s.markReviewed("s1", at: t0)
        let missing = s.markReviewed("missing", at: t0)
        #expect(!notWorking && !missing)
        s.apply(event("Notification", at: 1, ["notification_type": "idle_prompt"]))
        let fromWaiting = s.markReviewed("s1", at: t0.addingTimeInterval(2))
        #expect(fromWaiting)
        #expect(s.sessions["s1"]?.acknowledgedAt == t0.addingTimeInterval(2))
        s.apply(event("UserPromptSubmit", at: 3))
        #expect(s.sessions["s1"]?.acknowledgedAt == nil)
    }

    @Test func resumedFromOtherSourceIsTheSameSession() {
        let s = store([
            event("SessionStart", at: 0, ["tty": "ttys003", "source": "startup"]),
            event("SessionEnd", at: 1, ["tty": "ttys003"]),
            event("SessionStart", at: 2, ["source": "resume",
                "proc_chain": ["/x/claude", "/Applications/Claude.app/Contents/MacOS/Claude"]]),
        ])
        #expect(s.sessions.count == 1)
        #expect(s.sessions["s1"]?.source == .desktop)
        #expect(s.sessions["s1"]?.state == .idle)
    }

    @Test func eventsWithoutSourceSignalsKeepTheKnownSource() {
        let s = store([event("SessionStart", at: 0, ["tty": "ttys003"]), event("Stop", at: 1)])
        #expect(s.sessions["s1"]?.source == .terminal)
    }

    @Test func repoAndEpicFromBranch() {
        let s = store([event("SessionStart", at: 0, [
            "cwd": "/Users/u/git/app/sub", "git_root": "/Users/u/git/app", "git_branch": "epic/PROJ-7/T3",
        ])])
        let session = s.sessions["s1"]
        #expect(session?.repo == "app")
        #expect(session?.epicKey == "PROJ-7")
        #expect(session?.taskId == "T3")
    }

    @Test(arguments: [
        ("epic/PROJ-7/T3", "PROJ-7", "T3"),
        ("epic/ABC/T12", "ABC", "T12"),
    ])
    func epicParses(branch: String, key: String, task: String) {
        #expect(EpicRef.parse(branch: branch) == EpicRef(epicKey: key, taskId: task))
    }

    @Test(arguments: ["main", "feature/PROJ-1-x", "epic/PROJ-7", "epic/PROJ-7/T", "epic/PROJ-7/3",
                      "epic//T1", "epic/PROJ-7/T3/extra", "epic/PROJ-7/Tx"])
    func nonEpicBranches(branch: String) {
        #expect(EpicRef.parse(branch: branch) == nil)
    }

    @Test func sortedByUrgencyThenRecency() {
        var s = store([
            event("SessionStart", session: "idle", at: 0),
            event("UserPromptSubmit", session: "working", at: 1),
            event("Stop", session: "doneOld", at: 2),
            event("Stop", session: "doneNew", at: 3),
            event("PermissionRequest", session: "perm", at: 4),
            event("Notification", session: "wait", at: 5, ["notification_type": "elicitation_dialog"]),
            event("SessionEnd", session: "closed", at: 6),
            event("Stop", session: "rev", at: 7),
        ])
        s.markReviewed("rev", at: t0.addingTimeInterval(8))
        #expect(s.sorted.map(\.id) == ["perm", "wait", "doneNew", "doneOld", "working", "idle", "rev", "closed"])
        #expect(s.attentionCount == 4)
    }

    @Test func urgencyOrderMatchesSpec() {
        let order: [SessionState] = [.needsPermission, .waitingInput, .doneUnreviewed, .stale,
                                     .working, .idle, .reviewed, .presumedDead, .closed]
        #expect(order.map(\.urgencyRank) == Array(0..<order.count))
        #expect(Set(order) == Set(SessionState.allCases))
    }
}
