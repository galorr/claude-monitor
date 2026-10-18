import Foundation
import Testing
@testable import ClaudeMonitorCore

/// Mongo sync against the in-memory reference store (spec Phase 3, decisions.md D-013).
/// The same flows run against a real mongod in ClaudeMonitorMongoTests.

/// Records every status the sync reports; waits by polling.
final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [SyncEngine.Status] = []

    func record(_ s: SyncEngine.Status) { lock.withLock { statuses.append(s) } }
    var last: SyncEngine.Status? { lock.withLock { statuses.last } }

    func wait(timeout: Duration = .seconds(10), until match: (SyncEngine.Status) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let s = last, match(s) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }
}

extension SyncEngine.Options {
    static let fast: Self = {
        var o = Self()
        o.pollInterval = .milliseconds(50)
        o.initialBackoff = .milliseconds(20)
        o.maxBackoff = .milliseconds(100)
        return o
    }()
}

func testPaths() throws -> AppPaths {
    let dir = try tempDir()
    return AppPaths(eventsFile: dir.appending(path: "events.jsonl"),
                    snapshotFile: dir.appending(path: "state.json"),
                    logFile: dir.appending(path: "app.log"))
}

/// `n` distinct, valid event lines for one session, one second apart.
func syntheticLines(_ n: Int, session: String = "s1", from start: Int = 0) -> String {
    (start..<start + n).map { i in
        let ts = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(t0.addingTimeInterval(Double(i)))
        return #"{"session_id":"\#(session)","hook_event_name":"PostToolUse","ts":"\#(ts)","event_id":"e\#(i)"}"#
    }.joined(separator: "\n") + "\n"
}

func appendText(_ text: String, to url: URL) throws {
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let h = try FileHandle(forWritingTo: url)
    defer { try? h.close() }
    try h.seekToEnd()
    try h.write(contentsOf: Data(text.utf8))
}

@Suite struct SyncEngineTests {
    func makeSync(_ paths: AppPaths, _ store: InMemoryStore, _ recorder: StatusRecorder,
                  target: String = "mem://a") async -> SyncEngine {
        let sync = SyncEngine(paths: paths, log: AppLog(url: paths.logFile), options: .fast) { recorder.record($0) }
        await sync.configure(connect: { store }, target: target, retentionDays: 30)
        return sync
    }

    @Test func backlogDrainsAfterAnOutageWithoutDuplicates() async throws {
        let paths = try testPaths()
        try FileManager.default.copyItem(at: Fixture.captureURL, to: paths.eventsFile)
        let unique = Set(try Fixture.lines().compactMap { StoredEvent.from(line: $0)?.eventId }).count

        let store = InMemoryStore()
        await store.setDown(true)
        let recorder = StatusRecorder()
        let sync = await makeSync(paths, store, recorder)

        #expect(await recorder.wait { $0 == .offline(backlog: 80) })
        // Sessions keep running while Mongo is down.
        try appendText(syntheticLines(5), to: paths.eventsFile)
        #expect(await recorder.wait { $0 == .offline(backlog: 85) })

        await store.setDown(false)
        #expect(await recorder.wait { $0 == .connected(backlog: 0) })
        #expect(await store.events.count == unique + 5)

        // Replaying the whole file (sync state lost) writes no duplicates.
        await sync.stop()
        try FileManager.default.removeItem(at: paths.syncStateFile)
        let again = await makeSync(paths, store, StatusRecorder())
        #expect(await again.currentStatus != .notConfigured)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await store.events.count == unique + 5)
        await again.stop()
    }

    @Test func batchesAreAtMost200AndCommittedOneByOne() async throws {
        let paths = try testPaths()
        try appendText(syntheticLines(450), to: paths.eventsFile)
        let store = InMemoryStore()
        await store.failEventInserts(calls: [2])  // the second batch fails once
        let recorder = StatusRecorder()
        let sync = await makeSync(paths, store, recorder)

        #expect(await recorder.wait { $0 == .connected(backlog: 0) })
        // First batch is not re-sent after the failure: its offset was already committed.
        #expect(await store.eventBatches == [200, 200, 50])
        #expect(await store.events.count == 450)
        let saved = try JSONDecoder().decode(SyncState.self, from: Data(contentsOf: paths.syncStateFile))
        let size = try FileManager.default.attributesOfItem(atPath: paths.eventsFile.path)[.size] as? NSNumber
        #expect(saved.events.offset == size?.uint64Value)
        await sync.stop()
    }

    @Test func partialLastLineWaitsForItsNewline() async throws {
        let paths = try testPaths()
        let lines = syntheticLines(2)
        try appendText(String(lines.dropLast(10)), to: paths.eventsFile)
        let store = InMemoryStore()
        let recorder = StatusRecorder()
        let sync = await makeSync(paths, store, recorder)
        #expect(await recorder.wait { $0 == .connected(backlog: 0) })
        #expect(await store.events.count == 1)
        try appendText(String(lines.suffix(10)), to: paths.eventsFile)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await store.events.count == 2)
        await sync.stop()
    }

    @Test func newTargetSyncsEverythingAgain() async throws {
        let paths = try testPaths()
        try appendText(syntheticLines(3), to: paths.eventsFile)
        let first = InMemoryStore()
        let recorder = StatusRecorder()
        let sync = await makeSync(paths, first, recorder, target: "mem://a")
        #expect(await recorder.wait { $0 == .connected(backlog: 0) })

        let second = InMemoryStore()
        await sync.configure(connect: { second }, target: "mem://b", retentionDays: 30)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await second.events.count == 3)
        await sync.stop()
    }

    @Test func sessionsAreUpsertedAndTransitionsSynced() async throws {
        let paths = try testPaths()
        let s = store([event("UserPromptSubmit", at: 0), event("Stop", at: 5)])
        try TransitionJournal(url: paths.transitionsFile).append([
            StateChange(sessionId: "s1", from: nil, to: .working, at: t0),
            StateChange(sessionId: "s1", from: .working, to: .doneUnreviewed, at: t0.addingTimeInterval(5)),
        ])
        let mem = InMemoryStore()
        let recorder = StatusRecorder()
        let sync = SyncEngine(paths: paths, log: AppLog(url: paths.logFile), options: .fast) { recorder.record($0) }
        await sync.enqueue(Array(s.sessions.values))
        await sync.configure(connect: { mem }, target: "mem://a", retentionDays: 30)
        #expect(await recorder.wait { $0 == .connected(backlog: 0) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await mem.sessions["s1"]?.state == .doneUnreviewed)
        #expect(await mem.transitions.count == 2)
        await sync.stop()
    }

    @Test func notConfiguredMeansNoSync() async throws {
        let paths = try testPaths()
        let sync = SyncEngine(paths: paths, log: AppLog(url: paths.logFile))
        await sync.configure(connect: nil, target: nil, retentionDays: 30)
        #expect(await sync.currentStatus == .notConfigured)
        await #expect(throws: SyncEngine.SyncError.notConnected) {
            try await sync.stats(.day)
        }
    }

    @Test func enqueueKeepsTheNewestCopy() async throws {
        let paths = try testPaths()
        let newer = store([event("UserPromptSubmit", at: 0), event("Stop", at: 9)]).sessions["s1"]!
        let older = store([event("UserPromptSubmit", at: 0)]).sessions["s1"]!
        let mem = InMemoryStore()
        let recorder = StatusRecorder()
        let sync = SyncEngine(paths: paths, log: AppLog(url: paths.logFile), options: .fast) { recorder.record($0) }
        await sync.enqueue([newer])
        await sync.enqueue([older])  // arrived late
        await sync.configure(connect: { mem }, target: "mem://a", retentionDays: 30)
        #expect(await recorder.wait { $0 == .connected(backlog: 0) })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await mem.sessions["s1"]?.state == .doneUnreviewed)
        await sync.stop()
    }
}

@Suite struct PersistenceTests {
    @Test func upsertSkipsWhenTheStoredSessionIsNewer() async throws {
        let mem = InMemoryStore()
        let newer = store([event("UserPromptSubmit", at: 0), event("Stop", at: 9)]).sessions["s1"]!
        let older = store([event("UserPromptSubmit", at: 0)]).sessions["s1"]!
        #expect(try await mem.upsertSession(newer))
        #expect(try await !mem.upsertSession(older))
        #expect(await mem.sessions["s1"]?.state == .doneUnreviewed)
    }

    @Test func eventWithoutIdGetsAStableHash() {
        let line = Data(#"{"session_id":"s1","hook_event_name":"Stop","ts":"2027-01-15T08:00:00.000Z"}"#.utf8)
        let a = StoredEvent.from(line: line)
        #expect(a?.eventId.hasPrefix("sha256:") == true)
        #expect(a?.eventId == StoredEvent.from(line: line)?.eventId)
        #expect(StoredEvent.from(line: Data("nope".utf8)) == nil)
    }

    @Test func transitionIdsAreDeterministic() {
        let c = StateChange(sessionId: "s1", from: .working, to: .stale, at: t0)
        #expect(StoredTransition(c).id == StoredTransition(c).id)
        #expect(StoredTransition(c).id == "s1|stale|1800000000000")
    }

    @Test func journalRoundTrips() throws {
        let url = try tempDir().appending(path: "transitions.jsonl")
        let changes = [StateChange(sessionId: "s1", from: nil, to: .idle, at: t0.addingTimeInterval(0.123))]
        try TransitionJournal(url: url).append(changes)
        let lines = try Fixture.lines(url)
        #expect(lines.count == 1)
        #expect(TransitionJournal.decode(lines[0]) == StoredTransition(changes[0]))
    }

    @Test func mediansFollowTheNextTransition() {
        func t(_ to: SessionState, _ at: Double, _ session: String = "s1") -> StoredTransition {
            StoredTransition(StateChange(sessionId: session, from: nil, to: to, at: t0.addingTimeInterval(at)))
        }
        let list = [
            t(.needsPermission, 0), t(.working, 30),
            t(.needsPermission, 100), t(.working, 110),
            t(.doneUnreviewed, 200), t(.reviewed, 260),
            t(.doneUnreviewed, 300), t(.working, 310),  // not reviewed: excluded
            t(.needsPermission, 5, "s2"),               // still waiting: no duration yet
            t(.needsPermission, -50), t(.working, -40), // before the range
        ]
        let waits = StatsMath.waits(list, since: t0)
        #expect(waits.permission.sorted() == [10, 30])
        #expect(waits.review == [60])
        #expect(StatsMath.median(waits.permission) == 20)
        #expect(StatsMath.median([]) == nil)
        #expect(StatsMath.median([5, 1, 3]) == 3)
    }

    @Test func statsGroupRecentSessions() async throws {
        let mem = InMemoryStore()
        let s = store([
            event("SessionStart", session: "a", at: 0, ["git_root": "/x/api", "tty": "ttys001"]),
            event("Stop", session: "b", at: 1, ["cwd": "/x/web"]),
            event("Stop", session: "c", at: 2, ["cwd": "/x/web"]),
            event("Stop", session: "old", at: -100000),
        ])
        for session in s.sessions.values { _ = try await mem.upsertSession(session) }
        let stats = try await mem.stats(since: t0.addingTimeInterval(-10))
        #expect(stats.sessions == 3)
        #expect(stats.byState == [Bucket(key: "done_unreviewed", count: 2), Bucket(key: "idle", count: 1)])
        #expect(stats.byRepo == [Bucket(key: "web", count: 2), Bucket(key: "api", count: 1)])
        #expect(stats.bySource == [Bucket(key: "unknown", count: 2), Bucket(key: "terminal", count: 1)])
    }

    @Test func historyPagesNewestFirstWithoutGaps() async throws {
        let mem = InMemoryStore()
        // Two events share a timestamp: the (ts, event_id) cursor must not skip one.
        var lines = syntheticLines(6).split(separator: "\n").map { Data($0.utf8) }
        lines.append(Data(#"{"session_id":"s1","hook_event_name":"Stop","ts":"2027-01-15T08:00:02.000Z","event_id":"e2b"}"#.utf8))
        try await mem.insertEvents(lines.compactMap(StoredEvent.from))
        var seen: [String] = []
        var cursor: HistoryCursor?
        repeat {
            let page = try await mem.history(sessionId: "s1", after: cursor, limit: 2)
            seen += page.items.map(\.eventId)
            cursor = page.next
        } while cursor != nil
        #expect(seen == ["e5", "e4", "e3", "e2b", "e2", "e1", "e0"])
    }

    @Test func durationFormatting() {
        #expect(StatsMath.format(45) == "45s")
        #expect(StatsMath.format(185) == "3m 05s")
        #expect(StatsMath.format(7800) == "2h 10m")
    }
}

@Suite struct EngineJournalTests {
    @Test func engineJournalsHookAndUserTransitions() async throws {
        let paths = try testPaths()
        let ts = { (s: Int) in "2027-01-15T08:00:0\(s).000Z" }
        try appendText(#"{"session_id":"s1","hook_event_name":"UserPromptSubmit","ts":"\#(ts(0))"}"# + "\n"
                       + #"{"session_id":"s1","hook_event_name":"Stop","ts":"\#(ts(1))"}"# + "\n", to: paths.eventsFile)
        let updates = AsyncStream<MonitorEngine.Update>.makeStream()
        let engine = MonitorEngine(paths: paths, log: AppLog(url: paths.logFile))
        engine.start { updates.continuation.yield($0) }
        defer { engine.stop() }

        var iterator = updates.stream.makeAsyncIterator()
        _ = await iterator.next()                       // initial publish
        let ingested = await iterator.next()
        #expect(ingested?.changed.map(\.id) == ["s1"])
        engine.markReviewed("s1")
        let reviewed = await iterator.next()
        #expect(reviewed?.changed.first?.state == .reviewed)

        let journal = try Fixture.lines(paths.transitionsFile).compactMap(TransitionJournal.decode)
        #expect(journal.map(\.to) == [.working, .doneUnreviewed, .reviewed])
        #expect(journal.first?.from == nil)
    }

    @Test func firstUpdateCarriesEverySessionForResync() async throws {
        let paths = try testPaths()
        var s = SessionStore()
        MonitorEngine.process(try Fixture.lines(), into: &s)
        try EngineSnapshot(cursor: TailCursor(), store: s).save(to: paths.snapshotFile)
        let updates = AsyncStream<MonitorEngine.Update>.makeStream()
        let engine = MonitorEngine(paths: paths, log: AppLog(url: paths.logFile))
        engine.start { updates.continuation.yield($0) }
        defer { engine.stop() }
        var iterator = updates.stream.makeAsyncIterator()
        #expect(await iterator.next()?.changed.count == s.sessions.count)
    }

    @Test func missingJournalIsBackfilledFromTheEventsFile() async throws {
        let paths = try testPaths()
        try FileManager.default.copyItem(at: Fixture.captureURL, to: paths.eventsFile)
        var s = SessionStore()
        let expected = MonitorEngine.process(try Fixture.lines(), into: &s).changes.map(StoredTransition.init)
        // Already caught up (snapshot at the end of the file), but no journal yet.
        let size = try FileManager.default.attributesOfItem(atPath: paths.eventsFile.path)[.size] as! NSNumber
        try EngineSnapshot(cursor: TailCursor(offset: size.uint64Value), store: s).save(to: paths.snapshotFile)

        let updates = AsyncStream<MonitorEngine.Update>.makeStream()
        let engine = MonitorEngine(paths: paths, log: AppLog(url: paths.logFile))
        engine.start { updates.continuation.yield($0) }
        var iterator = updates.stream.makeAsyncIterator()
        _ = await iterator.next()
        engine.stop()
        let journal = try Fixture.lines(paths.transitionsFile).compactMap(TransitionJournal.decode)
        // Then the launch sweep journals its own changes (the fixture sessions are old).
        #expect(Array(journal.prefix(expected.count)) == expected)
        #expect(journal.dropFirst(expected.count).allSatisfy { $0.to == .presumedDead || $0.to == .stale })
        #expect(!expected.isEmpty)
    }

    @Test func readerReportsLineEndsAcrossBlankLines() throws {
        let url = try tempDir().appending(path: "events.jsonl")
        try appendText("ab\n\ncd\n", to: url)
        let r = try EventFileReader.readNewLines(path: url.path, cursor: TailCursor())
        #expect(r.lines.count == 2)
        #expect(r.lineEnds == [3, 7])
        #expect(EventFileReader.countLines(path: url.path, after: TailCursor(offset: 3, inode: r.cursor.inode)) == 2)
    }

    @Test func oldSettingsDecodeWithNewDefaults() throws {
        let old = #"{"staleAfterMinutes":5,"deadAfterHours":6,"hideEndedAfterHours":24,"notificationsEnabled":false}"#
        let s = try JSONDecoder().decode(MonitorSettings.self, from: Data(old.utf8))
        #expect(s.staleAfterMinutes == 5)
        #expect(!s.notificationsEnabled)
        #expect(s.retentionDays == 30)
    }
}

@Suite struct MongoURITests {
    @Test(arguments: [
        ("mongodb://127.0.0.1:27017/agent_memory?directConnection=true", true),
        ("mongodb://localhost/db", true),
        ("mongodb://user:p@ss@127.0.0.1:27017/db", true),
        ("mongodb://[::1]:27017/db", true),
        ("mongodb://127.0.0.1:27017,10.0.0.5:27017/db", false),
        ("mongodb://0.0.0.0:27017/db", false),
        ("mongodb+srv://cluster.example.net/db", false),
        ("not a uri", false),
    ])
    func loopback(uri: String, expected: Bool) {
        #expect(MongoURI.isLoopback(uri) == expected)
    }

    @Test func targetIdHidesTheURI() {
        let id = MongoURI.targetId("mongodb://u:secret@127.0.0.1/db")
        #expect(!id.contains("secret"))
        #expect(id == MongoURI.targetId("mongodb://u:secret@127.0.0.1/db"))
    }
}
