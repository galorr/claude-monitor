import Foundation
import Testing
@testable import ClaudeMonitorCore

/// Replays the real (anonymised) Phase 0 capture.
@Suite struct FixtureTests {
    @Test func everyCapturedLineDecodes() throws {
        let lines = try Fixture.lines()
        var store = SessionStore()
        var problems: [String] = []
        let malformed = MonitorEngine.process(lines, into: &store) { problems.append($0) }.malformed
        #expect(lines.count == 80)
        #expect(malformed == 0, "\(problems)")
        #expect(store.sessions.count == 10)
    }

    @Test(arguments: [
        ("f7d2f39a", SessionSource.desktop),   // Code tab, Local
        ("cbef0ed4", .desktop),                // closed by app quit (SessionEnd only)
        ("2e76b2db", .terminal),               // Terminal.app
        ("07e2b3cf", .terminal),               // VS Code integrated terminal
    ])
    func sourceDetection(prefix: String, expected: SessionSource) throws {
        let id = try Fixture.sessionId(prefix)
        let s = store(try Fixture.events()).sessions[id]
        #expect(s?.source == expected)
    }

    @Test func desktopSessionWalksThroughPermission() throws {
        let id = try Fixture.sessionId("f7d2f39a")
        let events = try Fixture.events().filter { $0.sessionId == id }
        var s = SessionStore()
        var states: [SessionState] = []
        for e in events {
            s.apply(e)
            states.append(s.sessions[id]!.state)
        }
        #expect(events.map(\.hookEventName) == [
            "SessionStart", "UserPromptSubmit", "PostToolUse", "PermissionRequest",
            "Notification", "PostToolUse", "Stop",
        ])
        #expect(states == [
            .idle, .working, .working, .needsPermission,
            .needsPermission, .working, .doneUnreviewed,
        ])
        #expect(s.sessions[id]?.lastMessage == "<assistant message>")
    }

    @Test(arguments: ["2e76b2db", "cbef0ed4", "63396207", "07e2b3cf", "64bd563d", "fc5d4d4d", "521d1c4e"])
    func endedSessionsAreClosed(prefix: String) throws {
        let id = try Fixture.sessionId(prefix)
        #expect(store(try Fixture.events()).sessions[id]?.state == .closed)
    }

    @Test func sessionWithoutStartIsCreatedFromFirstEvent() throws {
        // fc5d4d4d was already running when the hooks were installed: first event is idle_prompt.
        let id = try Fixture.sessionId("fc5d4d4d")
        let first = try #require(try Fixture.events().first { $0.sessionId == id })
        #expect(first.notificationType == "idle_prompt")
        let s = store([first]).sessions[id]
        #expect(s?.state == .waitingInput)
        #expect(s?.repo == "plugins-repo")
        #expect(s?.tty == "ttys001")
    }

    @Test func terminalSessionWalksThroughTwoPermissions() throws {
        // Second prompt was answered within 6s, so no permission_prompt Notification fired.
        let url = Fixture.repoRoot.appending(path: "fixtures/terminal-permission-2026-10-18.jsonl")
        let events = try Fixture.lines(url).map(HookEvent.decode)
        var s = SessionStore()
        var states: [SessionState] = []
        for e in events {
            s.apply(e)
            states.append(s.sessions[e.sessionId]!.state)
        }
        #expect(states == [
            .idle, .working, .needsPermission, .needsPermission,
            .working, .needsPermission, .working, .doneUnreviewed,
        ])
        #expect(s.sessions.values.first?.source == .terminal)
    }
}
