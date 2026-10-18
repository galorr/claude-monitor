import Foundation

/// Append-only log of state changes (transitions.jsonl). Written by the engine, read by
/// the sync, so changes the app makes itself (sweeps, reviews) survive a Mongo outage
/// the same way hook events do (decisions.md D-013).
public struct TransitionJournal: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func append(_ changes: [StateChange]) throws {
        guard !changes.isEmpty else { return }
        var data = Data()
        for c in changes {
            data += try Self.encoder.encode(StoredTransition(c))
            data.append(0x0A)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public static func decode(_ line: Data) -> StoredTransition? {
        try? decoder.decode(StoredTransition.self, from: line)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()
}

/// How far each file has been written to the store. Separate from the tail cursor in
/// state.json: live state never waits for Mongo (spec architecture contract #3).
public struct SyncState: Codable, Equatable, Sendable {
    /// Identifies the store the cursors refer to; a new target starts again from 0.
    public var target: String?
    public var events = TailCursor()
    public var transitions = TailCursor()

    public init(target: String? = nil) { self.target = target }

    static func load(from url: URL) -> SyncState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SyncState.self, from: data)
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Copies events.jsonl and transitions.jsonl into the store and upserts sessions.
/// Progress is committed per batch, only after the store accepted it; on failure it
/// backs off exponentially and reconnects. Nothing here can block the live engine.
public actor SyncEngine {
    public enum Status: Equatable, Sendable {
        case notConfigured
        case connecting(backlog: Int)
        case connected(backlog: Int)
        case offline(backlog: Int)

        public var label: String {
            switch self {
            case .notConfigured: "Mongo: not configured"
            case .connecting: "Mongo: connecting…"
            case .connected(let n) where n > 0: "Mongo: backlog \(n)"
            case .connected: "Mongo: connected"
            case .offline(let n): n > 0 ? "Mongo: offline, backlog \(n)" : "Mongo: offline"
            }
        }
    }

    public struct Options: Sendable {
        public var batchSize = 200
        /// Pause between passes once caught up.
        public var pollInterval: Duration = .seconds(2)
        public var initialBackoff: Duration = .seconds(1)
        public var maxBackoff: Duration = .seconds(60)
        /// A store call that takes longer counts as a failure (reconnect), so a hung
        /// connection cannot stall the sync while it still says "connected".
        public var operationTimeout: Duration = .seconds(30)

        public init() {}
    }

    public enum SyncError: Error, Equatable {
        case notConnected
    }

    public typealias Connect = @Sendable () async throws -> any PersistenceStore

    private let paths: AppPaths
    private let log: AppLog
    private let options: Options
    private let onStatus: @Sendable (Status) -> Void
    private var connect: Connect?
    private var retentionDays = 30
    private var store: (any PersistenceStore)?
    private var state = SyncState()
    private var pendingSessions: [String: Session] = [:]
    private var loop: Task<Void, Never>?
    /// Bumped on every configure, so a loop that was replaced stops touching state.
    private var generation = 0
    private var status = Status.notConfigured

    public init(paths: AppPaths, log: AppLog, options: Options = Options(),
                onStatus: @escaping @Sendable (Status) -> Void = { _ in }) {
        self.paths = paths
        self.log = log
        self.options = options
        self.onStatus = onStatus
    }

    /// Starts (or restarts) syncing. `target` names the store (the URI); when it differs
    /// from the last one, everything is synced again from the start. nil = stop syncing.
    public func configure(connect: Connect?, target: String?, retentionDays: Int) async {
        loop?.cancel()
        loop = nil
        generation += 1
        await store?.close()
        store = nil
        self.connect = connect
        self.retentionDays = retentionDays

        state = SyncState.load(from: paths.syncStateFile) ?? SyncState()
        if state.target != target {
            if state.target != nil { log.log("mongo: new target, syncing everything again") }
            state = SyncState(target: target)
            persistState()
        }
        guard connect != nil else {
            setStatus(.notConfigured)
            return
        }
        setStatus(.connecting(backlog: backlog()))
        let gen = generation
        loop = Task { await self.run(generation: gen) }
    }

    /// Sessions to upsert. Keeps the newest copy per session until it is written.
    public func enqueue(_ sessions: [Session]) {
        for s in sessions {
            if let queued = pendingSessions[s.id], queued.updatedAt > s.updatedAt { continue }
            pendingSessions[s.id] = s
        }
    }

    public func history(sessionId: String, after cursor: HistoryCursor?, limit: Int = 50) async throws -> HistoryPage {
        guard let store else { throw SyncError.notConnected }
        return try await store.history(sessionId: sessionId, after: cursor, limit: limit)
    }

    public func stats(_ range: StatsRange, now: Date = Date()) async throws -> SessionStats {
        guard let store else { throw SyncError.notConnected }
        return try await store.stats(since: now.addingTimeInterval(-range.duration))
    }

    public var currentStatus: Status { status }

    public func stop() async {
        await configure(connect: nil, target: state.target, retentionDays: retentionDays)
    }

    // MARK: - Loop

    private func run(generation gen: Int) async {
        var backoff = options.initialBackoff
        var wasOnline = true
        while !Task.isCancelled, gen == generation, let connect {
            do {
                if store == nil {
                    let days = retentionDays
                    let s = try await withTimeout(options.operationTimeout) {
                        let s = try await connect()
                        try await s.ensureIndexes(retentionDays: days)
                        return s
                    }
                    guard gen == generation else {
                        await s.close()
                        return
                    }
                    store = s
                    log.log("mongo: connected")
                }
                while try await syncOnce(), gen == generation, !Task.isCancelled {
                    setStatus(.connected(backlog: backlog()))
                }
                guard gen == generation else { return }
                backoff = options.initialBackoff
                wasOnline = true
                setStatus(.connected(backlog: backlog()))
                try? await Task.sleep(for: options.pollInterval)
            } catch {
                guard gen == generation, !Task.isCancelled else { return }
                if wasOnline { log.log("mongo: offline (\(error)); retrying with backoff") }
                wasOnline = false
                await store?.close()
                store = nil
                setStatus(.offline(backlog: backlog()))
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, options.maxBackoff)
            }
        }
    }

    /// One pass. Returns true if a file cursor moved (call again: there may be more).
    @discardableResult
    func syncOnce() async throws -> Bool {
        guard let store else { throw SyncError.notConnected }
        let gen = generation
        let movedEvents = try await syncFile(paths.eventsFile, cursor: \.events, label: "events") { lines in
            let events = lines.compactMap(StoredEvent.from)
            if !events.isEmpty { try await self.timed { try await store.insertEvents(events) } }
        }
        let movedTransitions = try await syncFile(paths.transitionsFile, cursor: \.transitions,
                                                  label: "transitions") { lines in
            let transitions = lines.compactMap(TransitionJournal.decode)
            if !transitions.isEmpty { try await self.timed { try await store.insertTransitions(transitions) } }
        }
        for (id, session) in pendingSessions.sorted(by: { $0.key < $1.key }) {
            _ = try await timed { try await store.upsertSession(session) }
            guard gen == generation else { return false }
            // Only drop it if no newer copy arrived while writing.
            if pendingSessions[id] == session { pendingSessions[id] = nil }
        }
        return movedEvents || movedTransitions
    }

    private func timed<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withTimeout(options.operationTimeout, operation)
    }

    private func syncFile(_ url: URL, cursor keyPath: WritableKeyPath<SyncState, TailCursor>, label: String,
                          write: ([Data]) async throws -> Void) async throws -> Bool {
        let start = state[keyPath: keyPath]
        let gen = generation
        let read = try EventFileReader.readNewLines(path: url.path, cursor: start)
        if read.rotated { log.log("mongo sync: \(label) file replaced or truncated; syncing it from 0") }
        var index = 0
        while index < read.lines.count {
            let end = min(index + options.batchSize, read.lines.count)
            try await write(Array(read.lines[index..<end]))
            guard gen == generation else { return false }
            state[keyPath: keyPath] = TailCursor(offset: read.lineEnds[end - 1], inode: read.cursor.inode)
            persistState()
            index = end
        }
        // Covers blank lines and a rotation with nothing new to write.
        if state[keyPath: keyPath] != read.cursor {
            state[keyPath: keyPath] = read.cursor
            persistState()
        }
        return read.cursor != start
    }

    /// Events not yet written to the store.
    private func backlog() -> Int {
        EventFileReader.countLines(path: paths.eventsFile.path, after: state.events)
    }

    private func persistState() {
        do { try state.save(to: paths.syncStateFile) } catch { log.log("sync state save failed: \(error)") }
    }

    private func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        onStatus(new)
    }
}
