import CryptoKit
import Foundation

/// The query store (spec Phase 3). Mongo implements it in ClaudeMonitorMongo; UI and
/// state machine only see this protocol. Every write is idempotent, so the sync can
/// always retry or replay from 0.
public protocol PersistenceStore: Sendable {
    /// Creates indexes if missing; updates the TTL if `retentionDays` changed.
    func ensureIndexes(retentionDays: Int) async throws
    /// An event whose id is already stored is skipped, not an error.
    func insertEvents(_ events: [StoredEvent]) async throws
    /// A transition whose id is already stored is skipped, not an error.
    func insertTransitions(_ transitions: [StoredTransition]) async throws
    /// Returns false (and writes nothing) when the stored copy has a newer `updatedAt`.
    func upsertSession(_ session: Session) async throws -> Bool
    /// Newest first. Pass the previous page's `next` to continue.
    func history(sessionId: String, after cursor: HistoryCursor?, limit: Int) async throws -> HistoryPage
    func stats(since: Date) async throws -> SessionStats
    func close() async
}

/// One events.jsonl line on its way to the store.
public struct StoredEvent: Equatable, Sendable {
    public var eventId: String
    public var sessionId: String
    public var name: String
    public var ts: Date
    /// The original line; the store keeps all of its fields.
    public var json: Data

    /// nil for a line the state machine skips too (malformed). A line without
    /// event_id gets a content hash, so replays still deduplicate.
    public static func from(line: Data) -> StoredEvent? {
        guard let e = try? HookEvent.decode(line) else { return nil }
        let id = e.eventId ?? "sha256:" + SHA256.hash(data: line).map { String(format: "%02x", $0) }.joined()
        return StoredEvent(eventId: id, sessionId: e.sessionId, name: e.hookEventName, ts: e.ts, json: line)
    }
}

/// One state change, journaled to transitions.jsonl by the engine (decisions.md D-013).
/// The stats medians are computed from these.
public struct StoredTransition: Codable, Equatable, Sendable {
    /// Deterministic: replaying the events file re-journals the same ids.
    public var id: String
    public var sessionId: String
    public var from: SessionState?
    public var to: SessionState
    public var at: Date

    enum CodingKeys: String, CodingKey {
        case id, from, to, at
        case sessionId = "session_id"
    }

    public init(_ change: StateChange) {
        sessionId = change.sessionId
        from = change.from
        to = change.to
        // Whole milliseconds, like Mongo dates and the journal encoding.
        let ms = (change.at.timeIntervalSince1970 * 1000).rounded()
        at = Date(timeIntervalSince1970: ms / 1000)
        id = "\(change.sessionId)|\(change.to.rawValue)|\(Int64(ms))"
    }
}

public struct HistoryItem: Equatable, Sendable, Identifiable {
    public var eventId: String
    public var ts: Date
    public var name: String
    public var detail: String?
    public var id: String { eventId }

    public init(eventId: String, ts: Date, name: String, detail: String?) {
        self.eventId = eventId
        self.ts = ts
        self.name = name
        self.detail = detail
    }

    /// The most telling field of an event, for the timeline.
    public static func detail(toolName: String?, notificationType: String?, source: String?,
                              reason: String?, error: String?) -> String? {
        toolName ?? notificationType ?? error ?? source ?? reason
    }

    public init(_ e: HookEvent, eventId: String) {
        self.init(eventId: eventId, ts: e.ts, name: e.hookEventName,
                  detail: Self.detail(toolName: e.toolName, notificationType: e.notificationType,
                                      source: e.source, reason: e.reason, error: e.error))
    }
}

/// Position in a session's timeline: (ts, event_id), both descending, so events with
/// equal timestamps are never skipped between pages.
public struct HistoryCursor: Equatable, Sendable {
    public var ts: Date
    public var eventId: String

    public init(ts: Date, eventId: String) {
        self.ts = ts
        self.eventId = eventId
    }
}

public struct HistoryPage: Equatable, Sendable {
    public var items: [HistoryItem]
    /// nil on the last page.
    public var next: HistoryCursor?

    public init(items: [HistoryItem], next: HistoryCursor?) {
        self.items = items
        self.next = next
    }
}

public struct Bucket: Equatable, Sendable, Identifiable {
    public var key: String
    public var count: Int
    public var id: String { key }

    public init(key: String, count: Int) {
        self.key = key
        self.count = count
    }
}

public struct SessionStats: Equatable, Sendable {
    /// Sessions with any activity in the range.
    public var sessions: Int
    public var byState: [Bucket]
    public var bySource: [Bucket]
    public var byRepo: [Bucket]
    /// Median time from entering needs_permission to the next state.
    public var medianPermissionWait: TimeInterval?
    /// Median time from done_unreviewed to reviewed (only turns that were reviewed).
    public var medianReviewDelay: TimeInterval?

    public init(sessions: Int, byState: [Bucket], bySource: [Bucket], byRepo: [Bucket],
                medianPermissionWait: TimeInterval?, medianReviewDelay: TimeInterval?) {
        self.sessions = sessions
        self.byState = byState
        self.bySource = bySource
        self.byRepo = byRepo
        self.medianPermissionWait = medianPermissionWait
        self.medianReviewDelay = medianReviewDelay
    }
}

public enum StatsRange: String, CaseIterable, Sendable, Identifiable {
    case day = "1d", week = "7d", month = "30d"
    public var id: String { rawValue }

    public var duration: TimeInterval {
        switch self {
        case .day: 86400
        case .week: 7 * 86400
        case .month: 30 * 86400
        }
    }
}

/// Shared by every store, so Mongo and the in-memory reference agree exactly.
public enum StatsMath {
    public static let noRepo = "(none)"

    public static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 1 ? s[mid] : (s[mid - 1] + s[mid]) / 2
    }

    /// Most common first, then by key.
    public static func buckets(_ counts: [String: Int]) -> [Bucket] {
        counts.map { Bucket(key: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
    }

    /// Durations in seconds: each needs_permission / done_unreviewed→reviewed until
    /// the session's next transition. Transitions are ordered by (at, id) per session,
    /// only those at or after `since` count.
    public static func waits(_ transitions: [StoredTransition], since: Date)
        -> (permission: [Double], review: [Double]) {
        var permission: [Double] = []
        var review: [Double] = []
        let bySession = Dictionary(grouping: transitions.filter { $0.at >= since }, by: \.sessionId)
        for list in bySession.values {
            let ordered = list.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
            for (t, next) in zip(ordered, ordered.dropFirst()) {
                let d = (next.at.timeIntervalSince(t.at) * 1000).rounded() / 1000
                if t.to == .needsPermission { permission.append(d) }
                if t.to == .doneUnreviewed && next.to == .reviewed { review.append(d) }
            }
        }
        return (permission, review)
    }

    /// "45s", "3m 05s", "2h 10m".
    public static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%dm %02ds", s / 60, s % 60) }
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }
}

/// Reference implementation for tests (and a model of the Mongo semantics).
public actor InMemoryStore: PersistenceStore {
    public private(set) var events: [String: StoredEvent] = [:]
    public private(set) var transitions: [String: StoredTransition] = [:]
    public private(set) var sessions: [String: Session] = [:]
    /// Sizes of the insertEvents calls, to check batching.
    public private(set) var eventBatches: [Int] = []
    /// While true every call throws, like a server that went away.
    public var isDown = false
    /// insertEvents calls (1-based, counting failures) that throw, like a dropped connection.
    public var failingEventInserts: Set<Int> = []
    private var eventInsertCalls = 0

    public struct Unavailable: Error {}

    public init() {}

    public func setDown(_ down: Bool) { isDown = down }
    public func failEventInserts(calls: Set<Int>) { failingEventInserts = calls }

    public func ensureIndexes(retentionDays: Int) async throws { try check() }

    public func insertEvents(_ events: [StoredEvent]) async throws {
        try check()
        eventInsertCalls += 1
        if failingEventInserts.contains(eventInsertCalls) { throw Unavailable() }
        eventBatches.append(events.count)
        for e in events where self.events[e.eventId] == nil { self.events[e.eventId] = e }
    }

    public func insertTransitions(_ transitions: [StoredTransition]) async throws {
        try check()
        for t in transitions where self.transitions[t.id] == nil { self.transitions[t.id] = t }
    }

    public func upsertSession(_ session: Session) async throws -> Bool {
        try check()
        if let stored = sessions[session.id], stored.updatedAt > session.updatedAt { return false }
        sessions[session.id] = session
        return true
    }

    public func history(sessionId: String, after cursor: HistoryCursor?, limit: Int) async throws -> HistoryPage {
        try check()
        let all = events.values.filter { $0.sessionId == sessionId }
            .sorted { $0.ts != $1.ts ? $0.ts > $1.ts : $0.eventId > $1.eventId }
            .filter { e in
                guard let c = cursor else { return true }
                return e.ts < c.ts || (e.ts == c.ts && e.eventId < c.eventId)
            }
        let page = all.prefix(limit).compactMap { e in
            (try? HookEvent.decode(e.json)).map { HistoryItem($0, eventId: e.eventId) }
        }
        let next = all.count > limit ? page.last.map { HistoryCursor(ts: $0.ts, eventId: $0.eventId) } : nil
        return HistoryPage(items: page, next: next)
    }

    public func stats(since: Date) async throws -> SessionStats {
        try check()
        let active = sessions.values.filter { $0.updatedAt >= since }
        func count(_ key: (Session) -> String) -> [Bucket] {
            StatsMath.buckets(Dictionary(grouping: active, by: key).mapValues(\.count))
        }
        let waits = StatsMath.waits(Array(transitions.values), since: since)
        return SessionStats(sessions: active.count,
                            byState: count { $0.state.rawValue },
                            bySource: count { $0.source.rawValue },
                            byRepo: count { $0.repo ?? StatsMath.noRepo },
                            medianPermissionWait: StatsMath.median(waits.permission),
                            medianReviewDelay: StatsMath.median(waits.review))
    }

    public func close() async {}

    private func check() throws {
        if isDown { throw Unavailable() }
    }
}

public enum MongoURI {
    /// Names a sync target without storing the URI itself (it may hold a password).
    public static func targetId(_ uri: String) -> String {
        SHA256.hash(data: Data(uri.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// True when every host is this machine. The spec wants Mongo on 127.0.0.1 only.
    public static func isLoopback(_ uri: String) -> Bool {
        guard let scheme = uri.range(of: "://") else { return false }
        var rest = uri[scheme.upperBound...]
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) { rest = rest[..<end] }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        let hosts = rest.split(separator: ",").map { host -> Substring in
            if host.hasPrefix("[") { return host.prefix { $0 != "]" }.dropFirst() }
            return host.split(separator: ":").first ?? host
        }
        return !hosts.isEmpty && hosts.allSatisfy { ["127.0.0.1", "localhost", "::1"].contains(String($0)) }
    }
}
