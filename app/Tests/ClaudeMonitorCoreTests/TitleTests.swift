import Foundation
import Testing
@testable import ClaudeMonitorCore

/// Session titles from the transcript (decisions.md D-019).
@Suite struct TitleTests {
    static func line(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    static func aiTitle(_ t: String) -> String { line(["type": "ai-title", "aiTitle": t, "sessionId": "s1"]) }
    static func customTitle(_ t: String) -> String { line(["type": "custom-title", "customTitle": t, "sessionId": "s1"]) }
    static let user = line(["type": "user", "message": ["content": "the title is \"x\""]])

    static func transcript(_ lines: [String], in dir: URL) throws -> String {
        let url = dir.appending(path: "s1.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func newestAiTitleWins() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try Self.transcript([Self.aiTitle("First idea"), Self.user, Self.aiTitle("Spec check for staging"), Self.user], in: dir)
        #expect(TranscriptTitle.read(path: path) == "Spec check for staging")
    }

    @Test func renameBeatsAiTitle() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try Self.transcript([Self.customTitle("my name"), Self.aiTitle("Auto title"), Self.user], in: dir)
        #expect(TranscriptTitle.read(path: path) == "my name")
    }

    @Test func noTitleOrNoFileIsNil() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try Self.transcript([Self.user, Self.aiTitle("  ")], in: dir)
        #expect(TranscriptTitle.read(path: path) == nil)
        #expect(TranscriptTitle.read(path: dir.appending(path: "missing.jsonl").path) == nil)
    }

    @Test func onlyTheTailIsRead() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let filler = Self.line(["type": "api-request-blob", "blob": String(repeating: "a", count: TranscriptTitle.tailBytes)])
        let path = try Self.transcript([Self.customTitle("old rename"), filler, Self.aiTitle("Recent")], in: dir)
        #expect(TranscriptTitle.read(path: path) == "Recent")
    }

    @Test func defaultPathMatchesClaudeCodeLayout() {
        #expect(TranscriptTitle.defaultPath(sessionId: "s1", cwd: "/Users/me/git/ivix-apps/.claude/wt_1", home: "/Users/me")
                == "/Users/me/.claude/projects/-Users-me-git-ivix-apps--claude-wt-1/s1.jsonl")
    }

    @Test func hookTranscriptPathIsKept() {
        let s = store([event("SessionStart", at: 0, ["transcript_path": "/t/s1.jsonl", "cwd": "/r/ace"])])
        #expect(s.sessions["s1"]?.transcriptPath == "/t/s1.jsonl")
        #expect(s.sessions["s1"]?.displayName == "ace")
    }

    @Test func titleNamesTheSessionAndNotification() {
        var s = store([event("Stop", at: 0, ["cwd": "/r/ace", "git_branch": "main"])])
        let first = s.setTitle("s1", "Spec check")
        let again = s.setTitle("s1", "Spec check")
        #expect(first && !again)
        let session = s.sessions["s1"]!
        #expect(session.displayName == "Spec check")
        #expect(NotificationPolicy.content(for: session).title == "Spec check: Done")
        #expect(NotificationPolicy.content(for: session).subtitle == "ace  ·  main")
    }

    @Test func snapshotWithoutTitleStillDecodes() throws {
        let s = store([event("SessionStart", at: 0, ["cwd": "/r/ace"])])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        var sessions = json["sessions"] as! [String: [String: Any]]
        sessions["s1"]?.removeValue(forKey: "title")
        sessions["s1"]?.removeValue(forKey: "transcriptPath")
        json["sessions"] = sessions
        let back = try JSONDecoder().decode(SessionStore.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.sessions["s1"]?.title == nil)
    }

    @Test func engineReadsTitleFromTranscript() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = try Self.transcript([Self.aiTitle("Spec check for staging")], in: dir)
        let paths = AppPaths(eventsFile: dir.appending(path: "events.jsonl"),
                             snapshotFile: dir.appending(path: "state.json"),
                             logFile: dir.appending(path: "app.log"))
        let hook = Self.line(["session_id": "s1", "hook_event_name": "SessionStart", "cwd": "/r/ace",
                              "transcript_path": transcript, "ts": "2026-11-19T10:00:00.000Z"])
        try (hook + "\n").write(to: paths.eventsFile, atomically: true, encoding: .utf8)
        let engine = MonitorEngine(paths: paths, log: AppLog(url: paths.logFile))
        let titled = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
            let once = Once()
            engine.start { u in
                guard let t = u.sessions.first?.title, once.take() else { return }
                c.resume(returning: t)
            }
        }
        engine.stop()
        #expect(titled == "Spec check for staging")
    }
}

private final class Once: @unchecked Sendable {
    private var taken = false
    private let lock = NSLock()
    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}
