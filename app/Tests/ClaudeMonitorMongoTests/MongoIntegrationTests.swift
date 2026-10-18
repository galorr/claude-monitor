import ClaudeMonitorCore
import Foundation
import Testing
@testable import ClaudeMonitorMongo

/// Spec Phase 3 integration test: stop Mongo → run sessions → start Mongo → the backlog
/// drains, counts match, no duplicates. Each test starts its own throwaway mongod on a
/// free port with a temp data dir, so the real server is never touched. Skipped when
/// mongod is not installed.
@Suite(.serialized, .enabled(if: TestMongod.binary != nil, "mongod not installed"))
struct MongoIntegrationTests {
    static let captureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "fixtures/capture-2026-10-18.jsonl")

    static func captureLines() throws -> [Data] {
        try Data(contentsOf: captureURL).split(separator: 0x0A).map { Data($0) }
    }

    @Test func backlogDrainsAfterMongoComesBackWithoutDuplicates() async throws {
        let mongod = try TestMongod()
        defer { mongod.stop() }
        let paths = try Self.paths()
        try FileManager.default.copyItem(at: Self.captureURL, to: paths.eventsFile)

        // What the live engine would have produced from the same events.
        var live = SessionStore()
        let changes = MonitorEngine.process(try Self.captureLines(), into: &live).changes
        try TransitionJournal(url: paths.transitionsFile).append(changes)
        let uniqueEvents = Set(try Self.captureLines().compactMap { StoredEvent.from(line: $0)?.eventId }).count
        let uniqueTransitions = Set(changes.map { StoredTransition($0).id }).count

        // 1. Mongo is down: the sync reports the backlog and keeps retrying.
        let recorder = Recorder()
        let sync = Self.makeSync(paths, uri: mongod.uri, recorder)
        await sync.enqueue(Array(live.sessions.values))
        await sync.configure(connect: Self.connect(mongod.uri), target: mongod.uri, retentionDays: 30)
        #expect(await recorder.wait { $0 == .offline(backlog: 80) })
        try Self.append(Self.synthetic(5, from: 0), to: paths.eventsFile)  // sessions keep running
        #expect(await recorder.wait { $0 == .offline(backlog: 85) })

        // 2. Mongo starts: everything drains.
        try await mongod.start()
        #expect(await recorder.wait(timeout: .seconds(30)) { $0 == .connected(backlog: 0) })
        let check = try await MongoStore.connect(uri: mongod.uri)
        defer { Task { await check.close() } }
        try await Self.eventually { try await check.count(MongoStore.Collection.sessions) == live.sessions.count }
        #expect(try await check.count(MongoStore.Collection.events) == uniqueEvents + 5)
        #expect(try await check.count(MongoStore.Collection.transitions) == uniqueTransitions)
        #expect(try await check.count(MongoStore.Collection.sessions) == live.sessions.count)

        // 3. Mongo dies mid-run and comes back.
        mongod.stop()
        try Self.append(Self.synthetic(5, from: 5), to: paths.eventsFile)
        #expect(await recorder.wait(timeout: .seconds(30)) { $0 == .offline(backlog: 5) })
        try await mongod.start()
        #expect(await recorder.wait(timeout: .seconds(30)) { $0 == .connected(backlog: 0) })
        let again = try await MongoStore.connect(uri: mongod.uri)
        #expect(try await again.count(MongoStore.Collection.events) == uniqueEvents + 10)

        // 4. Sync state lost: replaying from 0 adds no duplicates.
        await sync.stop()
        try FileManager.default.removeItem(at: paths.syncStateFile)
        let replay = Self.makeSync(paths, uri: mongod.uri, Recorder())
        await replay.configure(connect: Self.connect(mongod.uri), target: mongod.uri, retentionDays: 30)
        try await Task.sleep(for: .seconds(1))
        #expect(try await again.count(MongoStore.Collection.events) == uniqueEvents + 10)
        #expect(try await again.count(MongoStore.Collection.transitions) == uniqueTransitions)
        await replay.stop()
        await again.close()
    }

    @Test func indexesAreIdempotentAndTTLIsUpdatable() async throws {
        let mongod = try TestMongod()
        defer { mongod.stop() }
        try await mongod.start()
        let store = try await MongoStore.connect(uri: mongod.uri)
        try await store.ensureIndexes(retentionDays: 30)
        try await store.ensureIndexes(retentionDays: 30)
        try await store.ensureIndexes(retentionDays: 7)
        let reply = try await store.command(["listIndexes": MongoStore.Collection.events])
        let indexes = try MongoStore.firstBatch(reply)
        let ttl = indexes.first { $0["name"] as? String == "ts_ttl" }
        #expect(MongoStore.int(ttl?["expireAfterSeconds"]) == 7 * 86400)
        #expect(Set(indexes.compactMap { $0["name"] as? String })
                == ["_id_", "event_id_unique", "session_ts", "ts_ttl"])
        let unique = indexes.first { $0["name"] as? String == "event_id_unique" }
        #expect(unique?["unique"] as? Bool == true)
        await store.close()
    }

    /// Mongo's aggregations must agree with the in-memory reference implementation.
    @Test func statsAndHistoryMatchTheReference() async throws {
        let mongod = try TestMongod()
        defer { mongod.stop() }
        try await mongod.start()
        let mongo = try await MongoStore.connect(uri: mongod.uri)
        try await mongo.ensureIndexes(retentionDays: 30)
        let mem = InMemoryStore()

        var live = SessionStore()
        var changes = MonitorEngine.process(try Self.captureLines(), into: &live).changes
        // Review every finished session a little later, so the review median has data.
        let doneIds = live.sessions.values.filter { $0.state == .doneUnreviewed }.map(\.id).sorted()
        for (i, id) in doneIds.enumerated() {
            let at = live.sessions[id]!.lastEventAt.addingTimeInterval(Double(30 * (i + 1)) + 0.25)
            live.markReviewed(id, at: at)
            changes.append(StateChange(sessionId: id, from: .doneUnreviewed, to: .reviewed, at: at))
        }
        let events = try Self.captureLines().compactMap(StoredEvent.from)
        let transitions = changes.map(StoredTransition.init)
        for store in [mongo, mem] as [any PersistenceStore] {
            try await store.insertEvents(events)
            try await store.insertEvents(events)  // duplicates are ignored
            try await store.insertTransitions(transitions)
            for s in live.sessions.values { _ = try await store.upsertSession(s) }
        }

        let since = events.map(\.ts).min()!.addingTimeInterval(-60)
        let expected = try await mem.stats(since: since)
        let actual = try await mongo.stats(since: since)
        #expect(actual == expected)
        #expect(expected.sessions == live.sessions.count)
        #expect(expected.medianPermissionWait != nil)
        #expect(expected.medianReviewDelay != nil)
        // Nothing in a range after the data.
        #expect(try await mongo.stats(since: Date.distantFuture).sessions == 0)

        let busiest = Dictionary(grouping: events, by: \.sessionId).max { $0.value.count < $1.value.count }!.key
        let memHistory = try await Self.allHistory(mem, busiest)
        let mongoHistory = try await Self.allHistory(mongo, busiest)
        #expect(mongoHistory.count == Set(events.filter { $0.sessionId == busiest }.map(\.eventId)).count)
        #expect(mongoHistory.map(\.eventId) == memHistory.map(\.eventId))
        #expect(mongoHistory.map(\.name) == memHistory.map(\.name))
        #expect(mongoHistory.map(\.detail) == memHistory.map(\.detail))
        #expect(zip(mongoHistory, memHistory).allSatisfy { abs($0.ts.timeIntervalSince($1.ts)) < 0.0005 })

        // An older copy of a session never overwrites a newer one.
        var stale = live.sessions[doneIds[0]]!
        stale.updatedAt = stale.updatedAt.addingTimeInterval(-3600)
        stale.state = .working
        #expect(try await !mongo.upsertSession(stale))
        await mongo.close()
    }

    // MARK: - Helpers

    static func connect(_ uri: String) -> SyncEngine.Connect {
        { try await MongoStore.connect(uri: uri, timeout: .seconds(2)) }
    }

    static func makeSync(_ paths: AppPaths, uri: String, _ recorder: Recorder) -> SyncEngine {
        var options = SyncEngine.Options()
        options.pollInterval = .milliseconds(100)
        options.initialBackoff = .milliseconds(100)
        options.maxBackoff = .milliseconds(400)
        return SyncEngine(paths: paths, log: AppLog(url: paths.logFile), options: options) { recorder.record($0) }
    }

    static func allHistory(_ store: any PersistenceStore, _ session: String) async throws -> [HistoryItem] {
        var items: [HistoryItem] = []
        var cursor: HistoryCursor?
        repeat {
            let page = try await store.history(sessionId: session, after: cursor, limit: 3)
            items += page.items
            cursor = page.next
        } while cursor != nil
        return items
    }

    static func paths() throws -> AppPaths {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cm-mongo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AppPaths(eventsFile: dir.appending(path: "events.jsonl"),
                        snapshotFile: dir.appending(path: "state.json"),
                        logFile: dir.appending(path: "app.log"))
    }

    static func synthetic(_ n: Int, from start: Int) -> String {
        (start..<start + n).map { i in
            #"{"session_id":"synthetic","hook_event_name":"PostToolUse","ts":"2027-01-15T08:00:\#(String(format: "%02d", i)).000Z","event_id":"synthetic-\#(i)"}"#
        }.joined(separator: "\n") + "\n"
    }

    static func append(_ text: String, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(text.utf8))
    }

    static func eventually(timeout: Duration = .seconds(5), _ check: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await check() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var last: SyncEngine.Status?

    func record(_ s: SyncEngine.Status) { lock.withLock { last = s } }

    func wait(timeout: Duration = .seconds(15), until match: (SyncEngine.Status) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let s = lock.withLock({ last }), match(s) { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}

/// A private mongod: loopback only, free port, temp data dir, stopped on deinit.
final class TestMongod: @unchecked Sendable {
    static let binary: String? = ["/opt/homebrew/bin/mongod", "/usr/local/bin/mongod"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    let port: Int
    let dataDir: URL
    private var process: Process?

    var uri: String { "mongodb://127.0.0.1:\(port)/claude_monitor_test?directConnection=true" }

    init() throws {
        port = try Self.freePort()
        dataDir = FileManager.default.temporaryDirectory.appending(path: "cm-mongod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    }

    deinit {
        stop()
        try? FileManager.default.removeItem(at: dataDir)
    }

    func start() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.binary!)
        p.arguments = ["--port", "\(port)", "--bind_ip", "127.0.0.1", "--dbpath", dataDir.path,
                       "--logpath", dataDir.appending(path: "mongod.log").path, "--nounixsocket"]
        try p.run()
        process = p
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if let store = try? await MongoStore.connect(uri: uri, timeout: .seconds(1)) {
                await store.close()
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw MongoStore.StoreError.timeout
    }

    func stop() {
        guard let p = process else { return }
        process = nil
        p.terminate()
        p.waitUntilExit()
    }

    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard bound else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
