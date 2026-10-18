import Foundation

public struct AppPaths: Sendable {
    public var eventsFile: URL
    public var snapshotFile: URL
    public var logFile: URL

    /// Defaults per spec; CLAUDE_MONITOR_EVENTS_FILE overrides the events file (same as the hook).
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appending(path: "Library/Application Support/ClaudeMonitor", directoryHint: .isDirectory)
        let events = environment["CLAUDE_MONITOR_EVENTS_FILE"].map { URL(fileURLWithPath: $0) }
            ?? support.appending(path: "events.jsonl")
        return AppPaths(
            eventsFile: events,
            snapshotFile: support.appending(path: "state.json"),
            logFile: home.appending(path: "Library/Logs/ClaudeMonitor/app.log")
        )
    }
}

/// Append-only error log at ~/Library/Logs/ClaudeMonitor/app.log.
public final class AppLog: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) { self.url = url }

    public func log(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }
}

/// What survives a relaunch: the read position plus session state (including
/// acknowledged_at, which exists nowhere else). Saved together so they never disagree.
public struct EngineSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = EngineSnapshot.currentVersion
    public var cursor: TailCursor
    public var store: SessionStore

    public init(cursor: TailCursor = TailCursor(), store: SessionStore = SessionStore()) {
        self.cursor = cursor
        self.store = store
    }

    public static func load(from url: URL) throws -> EngineSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try decoder.decode(EngineSnapshot.self, from: Data(contentsOf: url))
        return snapshot.version == currentVersion ? snapshot : nil
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()
}
