import Foundation

/// Tails events.jsonl into a SessionStore. All mutable state is confined to `queue`.
/// File = source of truth: with no snapshot the cursor starts at 0 and the whole
/// file is replayed.
public final class MonitorEngine: @unchecked Sendable {
    public struct Update: Sendable {
        /// Visible sessions, sorted by urgency.
        public var sessions: [Session]
        public var attentionCount: Int
        /// Sessions that just entered a notifying state (see NotificationPolicy).
        public var notify: [Session]
        /// Sessions touched since the last update (all of them on the first), for the Mongo sync.
        public var changed: [Session]
    }

    public typealias Listener = @Sendable (Update) -> Void

    private let paths: AppPaths
    private let log: AppLog
    private let queue = DispatchQueue(label: "claude-monitor.engine")
    private let isAlive: @Sendable (Int) -> Bool
    private let now: @Sendable () -> Date
    private let journal: TransitionJournal
    private var snapshot = EngineSnapshot()
    private var settings = MonitorSettings()
    private var listener: Listener?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var sweepTimer: DispatchSourceTimer?

    /// Fallback poll: catches a file that did not exist yet, or was rotated.
    static let pollInterval: DispatchTimeInterval = .seconds(2)
    static let sweepInterval: DispatchTimeInterval = .seconds(60)

    public init(paths: AppPaths, log: AppLog,
                isAlive: @escaping @Sendable (Int) -> Bool = MonitorEngine.processIsAlive,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.paths = paths
        self.log = log
        self.isAlive = isAlive
        self.now = now
        journal = TransitionJournal(url: paths.transitionsFile)
    }

    public func start(settings: MonitorSettings = MonitorSettings(), listener: @escaping Listener) {
        queue.async { [self] in
            self.settings = settings
            self.listener = listener
            loadSnapshot()
            backfillJournalIfMissing()
            publish(changed: Array(snapshot.store.sessions.keys))
            ingest()
            sweep()
            startWatching()
        }
    }

    public func updateSettings(_ settings: MonitorSettings) {
        queue.async { [self] in
            self.settings = settings
            sweep()
            publish()
        }
    }

    public func markAllDoneReviewed() {
        queue.async { [self] in
            let at = now()
            let ids = snapshot.store.sessions.values.filter { $0.state == .doneUnreviewed }.map(\.id)
            guard snapshot.store.markAllDoneReviewed(at: at) > 0 else { return }
            record(ids.map { StateChange(sessionId: $0, from: .doneUnreviewed, to: .reviewed, at: at) })
            persist()
            publish(changed: ids)
        }
    }

    /// Runs one sweep now (the timer does this every 60s).
    public func sweepNow() {
        queue.async { [self] in sweep() }
    }

    /// `kill(pid, 0)`: 0 = exists; EPERM = exists but not ours. Anything else = gone.
    public static let processIsAlive: @Sendable (Int) -> Bool = { pid in
        guard pid > 0 else { return true }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }

    public func stop() {
        queue.sync {
            fileSource?.cancel()
            fileSource = nil
            pollTimer?.cancel()
            pollTimer = nil
            sweepTimer?.cancel()
            sweepTimer = nil
        }
    }

    public func markReviewed(_ id: String) {
        queue.async { [self] in
            let at = now()
            let from = snapshot.store.sessions[id]?.state
            guard snapshot.store.markReviewed(id, at: at) else { return }
            record([StateChange(sessionId: id, from: from, to: .reviewed, at: at)])
            persist()
            publish(changed: [id])
        }
    }

    /// Decodes lines, skipping (and reporting) malformed ones, and applies them in
    /// `ts` order. Returns the number of malformed lines, the state changes and the
    /// ids of all sessions the lines touched.
    @discardableResult
    public static func process(_ lines: [Data], into store: inout SessionStore,
                               onMalformed: (String) -> Void = { _ in })
        -> (malformed: Int, changes: [StateChange], touched: Set<String>) {
        var events: [HookEvent] = []
        var malformed = 0
        for line in lines {
            do {
                events.append(try HookEvent.decode(line))
            } catch {
                malformed += 1
                let preview = String(decoding: line.prefix(120), as: UTF8.self)
                onMalformed("skipped malformed line (\(error)): \(preview)")
            }
        }
        // Stable sort: equal timestamps keep file order.
        let ordered = events.enumerated().sorted {
            $0.element.ts != $1.element.ts ? $0.element.ts < $1.element.ts : $0.offset < $1.offset
        }
        let changes = ordered.compactMap { store.apply($0.element) }
        return (malformed, changes, Set(events.map(\.sessionId)))
    }

    /// Sessions to notify about: fresh transitions into a notifying state that still
    /// hold after the batch (a prompt approved within the same batch stays silent).
    public static func sessionsToNotify(_ changes: [StateChange], store: SessionStore, now: Date) -> [Session] {
        var seen = Set<String>()
        var result: [Session] = []
        for change in changes.reversed() where NotificationPolicy.shouldNotify(change, now: now) {
            guard !seen.contains(change.sessionId),
                  let s = store.sessions[change.sessionId], s.state == change.to else { continue }
            seen.insert(change.sessionId)
            result.append(s)
        }
        return result.reversed()
    }

    // MARK: - Queue-confined

    private func loadSnapshot() {
        do {
            if let loaded = try EngineSnapshot.load(from: paths.snapshotFile) { snapshot = loaded }
        } catch {
            log.log("snapshot unreadable, replaying events file from 0: \(error)")
            snapshot = EngineSnapshot()
        }
    }

    private func ingest() {
        var changed = false
        var changes: [StateChange] = []
        var touched = Set<String>()
        for _ in 0..<64 { // bounded: at most 64 × 4MB per wake-up
            let result: EventFileReader.Result
            do {
                result = try EventFileReader.readNewLines(path: paths.eventsFile.path, cursor: snapshot.cursor)
            } catch {
                log.log("read failed: \(error)")
                break
            }
            if result.rotated { log.log("events file rotated or truncated; reading from 0") }
            let moved = result.cursor != snapshot.cursor
            let processed = Self.process(result.lines, into: &snapshot.store) { [log] in log.log($0) }
            changes += processed.changes
            touched.formUnion(processed.touched)
            snapshot.cursor = result.cursor
            changed = changed || moved
            if result.lines.isEmpty { break }
        }
        if changed {
            record(changes)
            persist()
            let notify = settings.notificationsEnabled
                ? Self.sessionsToNotify(changes, store: snapshot.store, now: now()) : []
            publish(notify: notify, changed: Array(touched))
        }
    }

    private func sweep() {
        let changes = snapshot.store.sweep(now: now(), settings: settings, isAlive: isAlive)
        guard !changes.isEmpty else { return }
        for c in changes { log.log("sweep: \(c.sessionId) \(c.from?.rawValue ?? "-") → \(c.to.rawValue)") }
        record(changes)
        persist()
        publish(changed: changes.map(\.sessionId))
    }

    private func persist() {
        do { try snapshot.save(to: paths.snapshotFile) } catch { log.log("snapshot save failed: \(error)") }
    }

    /// First run with the journal (or after it was deleted): rebuild the hook-driven
    /// transitions for the part of the events file the snapshot already consumed, by
    /// replaying it into a scratch store. Without a snapshot, live replay journals
    /// everything anyway. Ids are deterministic, so any overlap is deduplicated.
    private func backfillJournalIfMissing() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: paths.transitionsFile.path) else { return }
        defer {
            // Exists from now on, even when there was nothing to write.
            if !fm.fileExists(atPath: paths.transitionsFile.path) {
                fm.createFile(atPath: paths.transitionsFile.path, contents: nil)
            }
        }
        let consumed = snapshot.cursor.offset
        guard consumed > 0 else { return }
        var scratch = SessionStore()
        var cursor = TailCursor()
        var changes: [StateChange] = []
        while cursor.offset < consumed {
            guard let result = try? EventFileReader.readNewLines(path: paths.eventsFile.path, cursor: cursor),
                  !result.lines.isEmpty else { break }
            if let inode = snapshot.cursor.inode, result.cursor.inode != inode { return } // replaced: live replays it
            let lines = zip(result.lines, result.lineEnds).filter { $0.1 <= consumed }.map(\.0)
            changes += Self.process(lines, into: &scratch).changes
            cursor = result.cursor
        }
        do {
            try journal.append(changes)
            log.log("transition journal: backfilled \(changes.count) transitions from the events file")
        } catch {
            log.log("transition journal backfill failed: \(error)")
        }
    }

    /// Journals state changes for the Mongo sync. A failure here never affects live state.
    private func record(_ changes: [StateChange]) {
        do { try journal.append(changes) } catch { log.log("transition journal write failed: \(error)") }
    }

    private func publish(notify: [Session] = [], changed: [String] = []) {
        listener?(Update(sessions: snapshot.store.visible(now: now(), settings: settings),
                         attentionCount: snapshot.store.attentionCount,
                         notify: notify,
                         changed: changed.compactMap { snapshot.store.sessions[$0] }))
    }

    private func startWatching() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if fileSource == nil { armFileSource() }
            ingest()
        }
        timer.resume()
        pollTimer = timer

        let sweeper = DispatchSource.makeTimerSource(queue: queue)
        sweeper.schedule(deadline: .now() + Self.sweepInterval, repeating: Self.sweepInterval)
        sweeper.setEventHandler { [weak self] in self?.sweep() }
        sweeper.resume()
        sweepTimer = sweeper

        armFileSource()
    }

    /// Instant wake-ups on append. Re-armed by the poll timer after delete/rename.
    private func armFileSource() {
        let fd = open(paths.eventsFile.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: queue)
        source.setEventHandler { [weak self, unowned source] in
            guard let self else { return }
            if !source.data.isDisjoint(with: [.delete, .rename]) {
                source.cancel()
                fileSource = nil
            }
            ingest()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }
}
