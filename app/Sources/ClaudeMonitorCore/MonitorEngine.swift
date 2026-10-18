import Foundation

/// Tails events.jsonl into a SessionStore. All mutable state is confined to `queue`.
/// File = source of truth: with no snapshot the cursor starts at 0 and the whole
/// file is replayed.
public final class MonitorEngine: @unchecked Sendable {
    public typealias Listener = @Sendable (_ sessions: [Session], _ attentionCount: Int) -> Void

    private let paths: AppPaths
    private let log: AppLog
    private let queue = DispatchQueue(label: "claude-monitor.engine")
    private var snapshot = EngineSnapshot()
    private var listener: Listener?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?

    /// Fallback poll: catches a file that did not exist yet, or was rotated.
    static let pollInterval: DispatchTimeInterval = .seconds(2)

    public init(paths: AppPaths, log: AppLog) {
        self.paths = paths
        self.log = log
    }

    public func start(listener: @escaping Listener) {
        queue.async { [self] in
            self.listener = listener
            loadSnapshot()
            publish()
            ingest()
            startWatching()
        }
    }

    public func stop() {
        queue.sync {
            fileSource?.cancel()
            fileSource = nil
            pollTimer?.cancel()
            pollTimer = nil
        }
    }

    public func markReviewed(_ id: String) {
        queue.async { [self] in
            guard snapshot.store.markReviewed(id, at: Date()) else { return }
            persist()
            publish()
        }
    }

    /// Decodes lines, skipping (and reporting) malformed ones, and applies them in
    /// `ts` order. Returns the number of malformed lines.
    @discardableResult
    public static func process(_ lines: [Data], into store: inout SessionStore,
                               onMalformed: (String) -> Void = { _ in }) -> Int {
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
        for (_, e) in ordered { store.apply(e) }
        return malformed
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
            Self.process(result.lines, into: &snapshot.store) { [log] in log.log($0) }
            snapshot.cursor = result.cursor
            changed = changed || moved
            if result.lines.isEmpty { break }
        }
        if changed {
            persist()
            publish()
        }
    }

    private func persist() {
        do { try snapshot.save(to: paths.snapshotFile) } catch { log.log("snapshot save failed: \(error)") }
    }

    private func publish() {
        listener?(snapshot.store.sorted, snapshot.store.attentionCount)
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
