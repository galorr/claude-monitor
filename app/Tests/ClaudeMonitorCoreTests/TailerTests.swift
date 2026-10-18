import Foundation
import Testing
@testable import ClaudeMonitorCore

@Suite struct TailerTests {
    func line(_ e: String, _ sid: String = "s1", _ sec: Int = 0) -> String {
        #"{"session_id":"\#(sid)","hook_event_name":"\#(e)","ts":"2027-01-15T08:00:\#(String(format: "%02d", sec)).000Z"}"#
    }

    func append(_ text: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
        try h.close()
    }

    @Test func missingFileYieldsNothing() throws {
        let r = try EventFileReader.readNewLines(path: "/nonexistent/events.jsonl", cursor: TailCursor())
        #expect(r.lines.isEmpty)
        #expect(r.cursor.offset == 0)
    }

    @Test func partialLineIsHeldBackUntilComplete() throws {
        let url = try tempDir().appending(path: "events.jsonl")
        let first = line("SessionStart") + "\n"
        let second = line("Stop", "s1", 1)
        try append(first + second.prefix(20), to: url)

        let r1 = try EventFileReader.readNewLines(path: url.path, cursor: TailCursor())
        #expect(r1.lines.count == 1)
        #expect(r1.cursor.offset == UInt64(first.utf8.count))

        try append(String(second.dropFirst(20)) + "\n", to: url)
        let r2 = try EventFileReader.readNewLines(path: url.path, cursor: r1.cursor)
        #expect(r2.lines.map { String(decoding: $0, as: UTF8.self) } == [second])
        #expect(!r2.rotated)

        let r3 = try EventFileReader.readNewLines(path: url.path, cursor: r2.cursor)
        #expect(r3.lines.isEmpty)
        #expect(r3.cursor == r2.cursor)
    }

    @Test func truncationRestartsFromZero() throws {
        let url = try tempDir().appending(path: "events.jsonl")
        try append(line("SessionStart") + "\n" + line("Stop", "s1", 1) + "\n", to: url)
        let r1 = try EventFileReader.readNewLines(path: url.path, cursor: TailCursor())
        try Data((line("SessionStart", "s2") + "\n").utf8).write(to: url) // same inode, smaller
        let r2 = try EventFileReader.readNewLines(path: url.path, cursor: r1.cursor)
        #expect(r2.rotated)
        #expect(r2.lines.count == 1)
    }

    @Test func replacedFileRestartsFromZero() throws {
        let dir = try tempDir()
        let url = dir.appending(path: "events.jsonl")
        try append(line("SessionStart") + "\n", to: url)
        let r1 = try EventFileReader.readNewLines(path: url.path, cursor: TailCursor())
        // Rotation: move away, new file at the same path (new inode), longer than the old offset.
        try FileManager.default.moveItem(at: url, to: dir.appending(path: "events.1.jsonl"))
        try append(line("SessionStart", "s2") + "\n" + line("Stop", "s2", 1) + "\n", to: url)
        let r2 = try EventFileReader.readNewLines(path: url.path, cursor: r1.cursor)
        #expect(r2.rotated)
        #expect(r2.lines.count == 2)
    }

    @Test func malformedLinesAreSkippedAndReported() {
        let lines = [
            Data(line("SessionStart").utf8),
            Data("not json".utf8),
            Data(#"{"session_id":"s1"}"#.utf8),
            Data(#"{"session_id":"s1","hook_event_name":"Stop","ts":"yesterday"}"#.utf8),
            Data("[1,2]".utf8),
            Data(line("UserPromptSubmit", "s1", 1).utf8),
        ]
        var store = SessionStore()
        var reports: [String] = []
        let malformed = MonitorEngine.process(lines, into: &store) { reports.append($0) }.malformed
        #expect(malformed == 4)
        #expect(reports.count == 4)
        #expect(store.sessions["s1"]?.state == .working)
    }

    @Test func batchIsAppliedInTimestampOrder() {
        let lines = [line("Stop", "s1", 5), line("UserPromptSubmit", "s1", 1)].map { Data($0.utf8) }
        var store = SessionStore()
        MonitorEngine.process(lines, into: &store)
        #expect(store.sessions["s1"]?.state == .doneUnreviewed)
    }

    @Test func wrongFieldTypesDecodeAsNil() throws {
        let e = try HookEvent.decode(Data(#"{"session_id":"s1","hook_event_name":"StopFailure","ts":"2027-01-15T08:00:00Z","error":{"type":"x"},"tty":42}"#.utf8))
        #expect(e.kind == .stopFailure)
        #expect(e.error == nil)
        #expect(e.tty == nil)
    }

    @Test func snapshotRoundTrips() throws {
        let url = try tempDir().appending(path: "state.json")
        var store = SessionStore()
        MonitorEngine.process(try Fixture.lines(), into: &store)
        let snap = EngineSnapshot(cursor: TailCursor(offset: 123, inode: 9), store: store)
        try snap.save(to: url)
        #expect(try EngineSnapshot.load(from: url) == snap)
    }

    @Test func engineTailsAppendsAndPersists() async throws {
        let dir = try tempDir()
        let paths = AppPaths(eventsFile: dir.appending(path: "events.jsonl"),
                             snapshotFile: dir.appending(path: "state.json"),
                             logFile: dir.appending(path: "app.log"))
        try append(line("SessionStart") + "\n" + "garbage\n", to: paths.eventsFile)

        let updates = AsyncStream<[Session]>.makeStream()
        let engine = MonitorEngine(paths: paths, log: AppLog(url: paths.logFile))
        engine.start { updates.continuation.yield($0.sessions) }
        defer { engine.stop() }
        var iterator = updates.stream.makeAsyncIterator()

        _ = await iterator.next() // initial publish (empty snapshot)
        #expect(await iterator.next()?.first?.state == .idle)

        try append(line("UserPromptSubmit", "s1", 1) + "\n", to: paths.eventsFile)
        #expect(await iterator.next()?.first?.state == .working)

        let saved = try #require(try EngineSnapshot.load(from: paths.snapshotFile))
        #expect(saved.store.sessions["s1"]?.state == .working)
        let log = try String(contentsOf: paths.logFile, encoding: .utf8)
        #expect(log.contains("skipped malformed line"))
    }
}
