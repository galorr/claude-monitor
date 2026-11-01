import Foundation
import Testing
@testable import ClaudeMonitorCore

/// Background tasks and artifacts (decisions.md D-017), shaped like the real payloads.
@Suite struct ActivityTests {
    static func bgBash(_ id: String, session: String = "s1", at: Double, description: String = "Run the suite",
                       command: String = "swift test") -> HookEvent {
        event("PostToolUse", session: session, at: at, [
            "tool_name": "Bash",
            "tool_input": ["command": command, "description": description, "run_in_background": true, "timeout": 600000],
            "tool_response": ["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": id],
        ])
    }

    static func agent(_ id: String, session: String = "s1", at: Double, type: String = "Explore") -> HookEvent {
        event("PostToolUse", session: session, at: at, [
            "tool_name": "Agent",
            "tool_input": ["description": "Scout the repo", "prompt": "…", "subagent_type": type],
            "tool_response": ["isAsync": true, "status": "async_launched", "agentId": id, "description": "Scout the repo"],
        ])
    }

    static func stop(session: String = "s1", at: Double, running: [[String: Any]]) -> HookEvent {
        event("Stop", session: session, at: at, ["last_assistant_message": "done", "background_tasks": running])
    }

    static func publish(_ url: String, session: String = "s1", at: Double, title: String? = "My Page",
                        action: String? = nil) -> HookEvent {
        var input: [String: Any] = ["file_path": "/tmp/x/page.html", "icon": "chart"]
        if let action { input["action"] = action }
        var response: [String: Any] = ["url": url, "artifact_id": "ad9d2574", "updated": false, "owned": true]
        if let title { response["title"] = title }
        return event("PostToolUse", session: session, at: at,
                     ["tool_name": "Artifact", "tool_input": input, "tool_response": response])
    }

    @Test func decodesToolFieldsFromThePayload() {
        let e = Self.bgBash("bgv3tfbel", at: 0, description: "Wait", command: "sleep 300")
        #expect(e.tool?.runInBackground == true)
        #expect(e.tool?.backgroundTaskId == "bgv3tfbel")
        #expect(e.tool?.command == "sleep 300")
        let a = Self.agent("a855", at: 0, type: "epic-planner:codebase-scout")
        #expect(a.tool?.isAsync == true && a.tool?.agentId == "a855" && a.tool?.subagentType == "epic-planner:codebase-scout")
        let s = Self.stop(at: 1, running: [["id": "bgv3tfbel", "type": "shell", "status": "running", "command": "sleep 300"],
                                           ["id": "a855", "type": "subagent", "status": "running", "agent_type": "Explore"]])
        #expect(s.backgroundTasks?.map(\.id) == ["bgv3tfbel", "a855"])
        #expect(s.backgroundTasks?[1].agentType == "Explore")
        // A Stop without the field (truncated line) is nil, an empty list is [].
        #expect(event("Stop", at: 2).backgroundTasks == nil)
        #expect(Self.stop(at: 3, running: []).backgroundTasks == [])
        // Ordinary tool calls carry nothing of interest and are not tasks.
        let read = event("PostToolUse", at: 4, ["tool_name": "Read", "tool_input": ["file_path": "/x"], "tool_response": ["ok": true]])
        #expect(read.tool?.runInBackground == false && read.tool?.backgroundTaskId == nil)
    }

    @Test func backgroundShellIsTrackedUntilAStopNoLongerListsIt() {
        var s = store([
            event("SessionStart", at: 0, ["git_root": "/Users/u/git/ivix"]),
            event("UserPromptSubmit", at: 1),
            Self.bgBash("b1", at: 2, description: "Export", command: "python export.py"),
        ])
        let key = BackgroundJob.key(sessionId: "s1", taskId: "b1")
        let t = try! #require(s.tasks[key])
        #expect(t.kind == .shell && t.isRunning && t.repo == "ivix")
        #expect(t.title == "Export" && t.detail == "python export.py")
        #expect(t.startedAt == t0.addingTimeInterval(2))

        // Still listed at the next Stop: running, last seen then.
        s.apply(Self.stop(at: 10, running: [["id": "b1", "type": "shell", "status": "running", "command": "python export.py"]]))
        #expect(s.tasks[key]?.isRunning == true)
        #expect(s.tasks[key]?.lastSeenAt == t0.addingTimeInterval(10))
        #expect(s.runningTaskCount == 1)

        // Gone from the next Stop: finished at that Stop.
        s.apply(event("UserPromptSubmit", at: 20))
        s.apply(Self.stop(at: 30, running: []))
        #expect(s.tasks[key]?.finishedAt == t0.addingTimeInterval(30))
        #expect(s.runningTaskCount == 0)
    }

    @Test func aStopWithoutTheFieldChangesNothing() {
        var s = store([Self.bgBash("b1", at: 0)])
        s.apply(event("Stop", at: 5)) // truncated line: no background_tasks
        #expect(s.tasks.values.first?.isRunning == true)
    }

    @Test func asyncSubagentIsATaskAndSyncAgentIsNot() {
        var s = store([Self.agent("a1", at: 0, type: "code-reviewer")])
        let t = try! #require(s.tasks[BackgroundJob.key(sessionId: "s1", taskId: "a1")])
        #expect(t.kind == .subagent && t.agentType == "code-reviewer" && t.title == "Scout the repo")
        s.apply(event("PostToolUse", at: 1, [
            "tool_name": "Agent", "tool_input": ["description": "Quick check", "prompt": "…"],
            "tool_response": ["content": "result", "agentId": "a2"],
        ]))
        #expect(s.tasks.count == 1)
    }

    @Test func stopSnapshotAddsTasksItHasNotSeenStarted() {
        // Task launched while the app was off, or its PostToolUse line was truncated.
        let s = store([Self.stop(at: 5, running: [
            ["id": "a9", "type": "subagent", "status": "running", "description": "Critique plan", "agent_type": "plan-critic"],
        ])])
        let t = try! #require(s.tasks[BackgroundJob.key(sessionId: "s1", taskId: "a9")])
        #expect(t.kind == .subagent && t.description == "Critique plan" && t.startedAt == t0.addingTimeInterval(5))
    }

    @Test func sessionEndAndDeadSessionsFinishTheirTasks() {
        var s = store([Self.bgBash("b1", at: 0), Self.bgBash("b2", session: "s2", at: 0)])
        s.apply(event("SessionEnd", at: 7))
        #expect(s.tasks[BackgroundJob.key(sessionId: "s1", taskId: "b1")]?.finishedAt == t0.addingTimeInterval(7))
        #expect(s.tasks[BackgroundJob.key(sessionId: "s2", taskId: "b2")]?.isRunning == true)

        var settings = MonitorSettings()
        settings.deadAfterHours = 1
        let later = t0.addingTimeInterval(2 * 3600)
        let swept = s.sweep(now: later, settings: settings, isAlive: { _ in true })
        #expect(swept.map(\.to) == [.presumedDead])
        let changed = s.sweepActivity(now: later, settings: settings)
        #expect(changed)
        #expect(s.tasks[BackgroundJob.key(sessionId: "s2", taskId: "b2")]?.isRunning == false)
    }

    @Test func taskStartedAfterALateStopIsLeftRunning() {
        // Async hooks: the launch line (t=3) lands before the Stop line (t=2) that predates it.
        var s = store([event("UserPromptSubmit", at: 0), Self.bgBash("b1", at: 3)])
        s.apply(Self.stop(at: 2, running: []))
        #expect(s.tasks.values.first?.isRunning == true)
    }

    @Test func visibleTasksRunningFirstThenRecentlyFinished() {
        var s = store([Self.bgBash("old", at: 0), Self.bgBash("done", at: 10), Self.bgBash("live", at: 20)])
        s.apply(Self.stop(at: 30, running: [["id": "live", "type": "shell", "status": "running"]]))
        // "old" and "done" finished at t=30. An hour and a bit later only "live" is visible…
        let now = t0.addingTimeInterval(30 + ActivityPolicy.finishedTaskVisibleFor + 1)
        #expect(s.visibleTasks(now: now).map(\.taskId) == ["live"])
        // …but just before that, running first, then finished ones, newest start first.
        let soon = t0.addingTimeInterval(40)
        #expect(s.visibleTasks(now: soon).map(\.taskId) == ["live", "done", "old"])
        // The sweep drops finished tasks once they are as old as hidden sessions.
        var settings = MonitorSettings()
        settings.hideEndedAfterHours = 1
        let pruned = s.sweepActivity(now: t0.addingTimeInterval(30 + 3601), settings: settings)
        #expect(pruned)
        #expect(Set(s.tasks.values.map(\.taskId)) == ["live"])
    }

    @Test func artifactsAreKeyedByUrlAndCountPublishes() {
        let url = "https://claude.ai/artifact/NSSNy2mv2JyNm996mtMbKE"
        var s = store([
            event("SessionStart", at: 0, ["git_root": "/Users/u/git/plans"]),
            Self.publish(url, at: 1),
            Self.publish(url, at: 2, title: nil),
        ])
        let a = try! #require(s.artifacts[url])
        #expect(a.title == "My Page" && a.icon == "chart" && a.repo == "plans")
        #expect(a.publishCount == 2 && a.createdAt == t0.addingTimeInterval(1) && a.updatedAt == t0.addingTimeInterval(2))

        // Reads, lists and opens are not publications; delete removes it.
        s.apply(Self.publish(url, at: 3, action: "read"))
        s.apply(Self.publish("https://claude.ai/artifact/other", at: 3, action: "list"))
        #expect(s.artifacts.count == 1 && s.artifacts[url]?.publishCount == 2)
        s.apply(Self.publish(url, at: 4, action: "delete"))
        #expect(s.artifacts.isEmpty)
    }

    @Test func artifactsNewestFirstCappedAndExpired() {
        var s = SessionStore()
        for i in 0..<(ActivityPolicy.maxVisibleArtifacts + 3) {
            s.apply(Self.publish("https://claude.ai/artifact/\(i)", at: Double(i), title: "Page \(i)"))
        }
        let visible = s.visibleArtifacts
        #expect(visible.count == ActivityPolicy.maxVisibleArtifacts)
        #expect(visible.first?.title == "Page \(ActivityPolicy.maxVisibleArtifacts + 2)")
        let expired = s.sweepActivity(now: t0.addingTimeInterval(ActivityPolicy.artifactRetention + 10), settings: MonitorSettings())
        #expect(expired)
        #expect(s.artifacts.count == ActivityPolicy.maxVisibleArtifacts + 3 - 10) // 0–9 expired (30 days + 10 s later)
        #expect(ArtifactRecord(url: "https://claude.ai/artifact/abc", title: nil, icon: nil, sessionId: "s", repo: nil,
                               createdAt: t0, updatedAt: t0, publishCount: 1).displayTitle == "artifact/abc")
    }

    @Test func oldSnapshotsDecodeWithEmptyActivity() throws {
        let json = #"{"sessions":{}}"#
        let decoded = try JSONDecoder().decode(SessionStore.self, from: Data(json.utf8))
        #expect(decoded.tasks.isEmpty && decoded.artifacts.isEmpty)
        // And a round trip keeps them.
        let s = store([Self.bgBash("b1", at: 0), Self.publish("https://claude.ai/artifact/x", at: 1)])
        let back = try JSONDecoder().decode(SessionStore.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test func engineUpdateCarriesTasksAndArtifacts() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = AppPaths(eventsFile: dir.appending(path: "events.jsonl"),
                             snapshotFile: dir.appending(path: "state.json"),
                             logFile: dir.appending(path: "app.log"))
        let lines = [Self.bgBash("b1", at: 0), Self.publish("https://claude.ai/artifact/x", at: 1)].map(Self.encode)
        try lines.joined().write(to: paths.eventsFile, atomically: true, encoding: .utf8)
        let engine = MonitorEngine(paths: paths, log: AppLog(url: paths.logFile), now: { t0.addingTimeInterval(5) })
        let update = await withCheckedContinuation { (c: CheckedContinuation<MonitorEngine.Update, Never>) in
            let box = Box()
            engine.start { u in
                guard !u.tasks.isEmpty, box.take() else { return }
                c.resume(returning: u)
            }
        }
        engine.stop()
        #expect(update.tasks.map(\.taskId) == ["b1"])
        #expect(update.artifacts.map(\.url) == ["https://claude.ai/artifact/x"])
    }

    /// Re-encodes a decoded event as a hook line (only the fields these tests need).
    static func encode(_ e: HookEvent) -> String {
        var obj: [String: Any] = [
            "session_id": e.sessionId, "hook_event_name": e.hookEventName,
            "ts": Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(e.ts),
        ]
        if let name = e.toolName { obj["tool_name"] = name }
        if let t = e.tool {
            var input: [String: Any] = [:]
            var response: [String: Any] = [:]
            if t.runInBackground { input["run_in_background"] = true }
            if let v = t.command { input["command"] = v }
            if let v = t.description { input["description"] = v }
            if let v = t.backgroundTaskId { response["backgroundTaskId"] = v }
            if let v = t.url { response["url"] = v }
            if let v = t.title { response["title"] = v }
            obj["tool_input"] = input
            obj["tool_response"] = response
        }
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self) + "\n"
    }
}

/// One-shot flag for continuations that may be offered several updates.
private final class Box: @unchecked Sendable {
    private var taken = false
    private let lock = NSLock()
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
