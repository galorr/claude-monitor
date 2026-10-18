import ClaudeMonitorCore
import Foundation
import MongoKitten

/// PersistenceStore on MongoDB via MongoKitten (spec Phase 3, decisions.md D-002/D-013).
/// Uses raw commands so the write semantics are explicit: unordered inserts where a
/// duplicate key means "already synced", and a guarded upsert for sessions.
public struct MongoStore: PersistenceStore {
    public enum Collection {
        public static let events = "claude_monitor_events"
        public static let sessions = "claude_monitor_sessions"
        public static let transitions = "claude_monitor_transitions"
    }

    public enum StoreError: Error, CustomStringConvertible {
        case timeout
        case command(code: Int?, message: String)
        case badReply(String)

        public var description: String {
            switch self {
            case .timeout: "timed out"
            case .command(let code, let message): "Mongo error \(code.map(String.init) ?? "?"): \(message)"
            case .badReply(let what): "unexpected reply: \(what)"
            }
        }
    }

    static let duplicateKey = 11000
    static let indexOptionsConflict = 85

    let db: MongoDatabase

    /// Connects and pings. The URI must name the database.
    public static func connect(uri: String, timeout: Duration = .seconds(5)) async throws -> MongoStore {
        let db = try await withTimeout(timeout) { try await MongoDatabase.connect(to: uri) }
        let store = MongoStore(db: db)
        do {
            _ = try await withTimeout(timeout) { try await store.command(["ping": 1]) }
        } catch {
            await store.close()
            throw error
        }
        return store
    }

    /// For the Settings "Test" button.
    public func serverVersion() async throws -> String {
        let info = try await command(["buildInfo": 1])
        return info["version"] as? String ?? "unknown"
    }

    public var databaseName: String { db.name }

    // MARK: - PersistenceStore

    public func ensureIndexes(retentionDays: Int) async throws {
        let ttl = retentionDays * 86400
        try await createIndexes(Collection.events, [
            ["key": ["event_id": 1] as Document, "name": "event_id_unique", "unique": true],
            ["key": ["session_id": 1, "ts": -1] as Document, "name": "session_ts"],
        ])
        try await ensureTTL(Collection.events, field: "ts", seconds: ttl)
        try await createIndexes(Collection.transitions, [
            ["key": ["session_id": 1, "at": 1] as Document, "name": "session_at"],
        ])
        try await ensureTTL(Collection.transitions, field: "at", seconds: ttl)
        try await createIndexes(Collection.sessions, [
            ["key": ["state": 1] as Document, "name": "state"],
            ["key": ["repo": 1] as Document, "name": "repo"],
            ["key": ["epic_key": 1] as Document, "name": "epic_key"],
            ["key": ["updated_at": 1] as Document, "name": "updated_at"],
        ])
    }

    public func insertEvents(_ events: [StoredEvent]) async throws {
        try await insertIgnoringDuplicates(Collection.events, try events.map(Self.eventDocument))
    }

    public func insertTransitions(_ transitions: [StoredTransition]) async throws {
        try await insertIgnoringDuplicates(Collection.transitions, transitions.map(Self.transitionDocument))
    }

    public func upsertSession(_ session: Session) async throws -> Bool {
        // Matches only if the stored copy is not newer. If it is newer, the upsert tries
        // to insert a second document with the same _id and fails with 11000: skipped.
        let query: Document = ["_id": session.id, "updated_at": ["$lte": bsonDate(session.updatedAt)] as Document]
        let update: Document = ["q": query, "u": Self.sessionDocument(session), "upsert": true]
        let reply = try await command(["update": Collection.sessions, "updates": [update] as Document])
        let errors = Self.writeErrorCodes(reply)
        if errors.isEmpty { return true }
        if errors.allSatisfy({ $0 == Self.duplicateKey }) { return false }
        throw StoreError.command(code: errors.first, message: "session upsert failed: \(reply)")
    }

    public func history(sessionId: String, after cursor: HistoryCursor?, limit: Int) async throws -> HistoryPage {
        var filter: Document = ["session_id": sessionId]
        if let c = cursor {
            filter["$or"] = [
                ["ts": ["$lt": bsonDate(c.ts)] as Document] as Document,
                ["ts": bsonDate(c.ts), "event_id": ["$lt": c.eventId] as Document] as Document,
            ] as Document
        }
        let projection: Document = [
            "event_id": 1, "ts": 1, "hook_event_name": 1, "tool_name": 1,
            "notification_type": 1, "source": 1, "reason": 1, "error": 1,
        ]
        let reply = try await command([
            "find": Collection.events,
            "filter": filter,
            "sort": ["ts": -1, "event_id": -1] as Document,
            "projection": projection,
            "limit": limit + 1,
            "batchSize": limit + 1,
            "singleBatch": true,
        ])
        let docs = try Self.firstBatch(reply)
        let items = docs.prefix(limit).compactMap { d -> HistoryItem? in
            guard let id = d["event_id"] as? String, let ts = d["ts"] as? Date,
                  let name = d["hook_event_name"] as? String else { return nil }
            return HistoryItem(eventId: id, ts: ts, name: name, detail: HistoryItem.detail(
                toolName: d["tool_name"] as? String, notificationType: d["notification_type"] as? String,
                source: d["source"] as? String, reason: d["reason"] as? String, error: d["error"] as? String))
        }
        let next = docs.count > limit ? items.last.map { HistoryCursor(ts: $0.ts, eventId: $0.eventId) } : nil
        return HistoryPage(items: items, next: next)
    }

    public func stats(since: Date) async throws -> SessionStats {
        func group(_ field: Primitive) -> Document {
            [["$group": ["_id": field, "n": ["$sum": 1] as Document] as Document] as Document]
        }
        let sessionsReply = try await command([
            "aggregate": Collection.sessions,
            "pipeline": [
                ["$match": ["updated_at": ["$gte": bsonDate(since)] as Document] as Document] as Document,
                ["$facet": [
                    "state": group("$state"),
                    "source": group("$source"),
                    "repo": group(["$ifNull": ["$repo", StatsMath.noRepo] as Document] as Document),
                ] as Document] as Document,
            ] as Document,
            "cursor": [:] as Document,
        ])
        let facets = try Self.firstBatch(sessionsReply).first ?? [:]
        func buckets(_ name: String) -> [Bucket] {
            var counts: [String: Int] = [:]
            for case let d as Document in (facets[name] as? Document)?.values ?? [] {
                if let key = d["_id"] as? String { counts[key] = Self.int(d["n"]) ?? 0 }
            }
            return StatsMath.buckets(counts)
        }
        let byState = buckets("state")

        // Time from each transition to the session's next one, ordered like StatsMath.waits.
        func durations(_ match: Document) -> Document {
            [
                ["$match": match] as Document,
                ["$group": ["_id": Null(), "d": ["$push": "$d"] as Document] as Document] as Document,
            ]
        }
        let waitsReply = try await command([
            "aggregate": Collection.transitions,
            "pipeline": [
                ["$match": ["at": ["$gte": bsonDate(since)] as Document] as Document] as Document,
                ["$setWindowFields": [
                    "partitionBy": "$session_id",
                    "sortBy": ["at": 1, "_id": 1] as Document,
                    "output": [
                        "next_at": ["$shift": ["output": "$at", "by": 1] as Document] as Document,
                        "next_to": ["$shift": ["output": "$to", "by": 1] as Document] as Document,
                    ] as Document,
                ] as Document] as Document,
                ["$match": ["next_at": ["$ne": Null()] as Document] as Document] as Document,
                ["$project": [
                    "to": 1, "next_to": 1,
                    "d": ["$subtract": ["$next_at", "$at"] as Document] as Document,
                ] as Document] as Document,
                ["$facet": [
                    "permission": durations(["to": SessionState.needsPermission.rawValue]),
                    "review": durations(["to": SessionState.doneUnreviewed.rawValue,
                                         "next_to": SessionState.reviewed.rawValue]),
                ] as Document] as Document,
            ] as Document,
            "cursor": [:] as Document,
        ])
        let waits = try Self.firstBatch(waitsReply).first ?? [:]
        func seconds(_ name: String) -> [Double] {
            guard let first = (waits[name] as? Document)?.values.first as? Document,
                  let list = first["d"] as? Document else { return [] }
            return list.values.compactMap { Self.int($0).map { Double($0) / 1000 } }
        }

        return SessionStats(sessions: byState.reduce(0) { $0 + $1.count },
                            byState: byState,
                            bySource: buckets("source"),
                            byRepo: buckets("repo"),
                            medianPermissionWait: StatsMath.median(seconds("permission")),
                            medianReviewDelay: StatsMath.median(seconds("review")))
    }

    public func close() async {
        await (db.pool as? MongoCluster)?.disconnect()
    }

    // MARK: - Test support

    public func count(_ collection: String, _ filter: Document = [:]) async throws -> Int {
        let reply = try await command(["count": collection, "query": filter])
        return Self.int(reply["n"]) ?? 0
    }

    public func dropDatabase() async throws {
        _ = try await command(["dropDatabase": 1])
    }

    // MARK: - Commands

    func command(_ cmd: Document) async throws -> Document {
        let connection = try await db.pool.next(for: .writable)
        let reply = try await connection.execute(cmd, namespace: db.commandNamespace,
                                                 sessionId: connection.implicitSessionId)
        let doc = try reply.getDocument()
        guard try reply.isOK() else {
            throw StoreError.command(code: Self.int(doc["code"]), message: doc["errmsg"] as? String ?? "\(doc)")
        }
        return doc
    }

    private func createIndexes(_ collection: String, _ indexes: [Document]) async throws {
        _ = try await command(["createIndexes": collection, "indexes": Document(array: indexes)])
    }

    /// TTL index; if it exists with another expiry, change it in place (collMod).
    private func ensureTTL(_ collection: String, field: String, seconds: Int) async throws {
        let name = "\(field)_ttl"
        do {
            try await createIndexes(collection, [
                ["key": [field: 1] as Document, "name": name, "expireAfterSeconds": seconds],
            ])
        } catch StoreError.command(let code, _) where code == Self.indexOptionsConflict {
            _ = try await command([
                "collMod": collection,
                "index": ["name": name, "expireAfterSeconds": seconds] as Document,
            ])
        }
    }

    private func insertIgnoringDuplicates(_ collection: String, _ docs: [Document]) async throws {
        guard !docs.isEmpty else { return }
        let reply = try await command(["insert": collection, "documents": Document(array: docs), "ordered": false])
        let failures = Self.writeErrorCodes(reply).filter { $0 != Self.duplicateKey }
        if !failures.isEmpty {
            throw StoreError.command(code: failures.first, message: "\(failures.count) inserts failed in \(collection)")
        }
    }

    // MARK: - Documents

    static func eventDocument(_ e: StoredEvent) throws -> Document {
        guard let object = try JSONSerialization.jsonObject(with: e.json) as? [String: Any] else {
            throw StoreError.badReply("event line is not an object")
        }
        var doc = try bson(object)
        doc["ts"] = bsonDate(e.ts)  // a real date, for sorting and the TTL index
        doc["event_id"] = e.eventId
        return doc
    }

    static func transitionDocument(_ t: StoredTransition) -> Document {
        var doc: Document = ["_id": t.id, "session_id": t.sessionId, "to": t.to.rawValue, "at": bsonDate(t.at)]
        doc["from"] = t.from?.rawValue
        return doc
    }

    static func sessionDocument(_ s: Session) -> Document {
        var doc: Document = [
            "_id": s.id,
            "state": s.state.rawValue,
            "source": s.source.rawValue,
            "last_event_at": bsonDate(s.lastEventAt),
            "updated_at": bsonDate(s.updatedAt),
        ]
        doc["repo"] = s.repo
        doc["cwd"] = s.cwd
        doc["branch"] = s.branch
        doc["epic_key"] = s.epicKey
        doc["task_id"] = s.taskId
        doc["tty"] = s.tty
        doc["claude_pid"] = s.claudePid
        doc["last_message"] = s.lastMessage
        doc["acknowledged_at"] = s.acknowledgedAt.map(bsonDate)
        return doc
    }

    static func bson(_ object: [String: Any]) throws -> Document {
        var doc = Document()
        for key in object.keys.sorted() { doc[key] = try bsonValue(object[key]!) }
        return doc
    }

    static func bsonValue(_ value: Any) throws -> Primitive {
        switch value {
        case let s as String: return s
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            return CFNumberIsFloatType(n) ? n.doubleValue : n.intValue
        case let a as [Any]: return try Document(array: a.map { try bsonValue($0) })
        case let o as [String: Any]: return try bson(o)
        default: return Null()
        }
    }

    // MARK: - Replies

    static func firstBatch(_ reply: Document) throws -> [Document] {
        guard let cursor = reply["cursor"] as? Document, let batch = cursor["firstBatch"] as? Document else {
            throw StoreError.badReply("no cursor.firstBatch")
        }
        return batch.values.compactMap { $0 as? Document }
    }

    static func writeErrorCodes(_ reply: Document) -> [Int] {
        guard let errors = reply["writeErrors"] as? Document else { return [] }
        return errors.values.map { (($0 as? Document)?["code"]).flatMap(int) ?? -1 }
    }

    static func int(_ value: Primitive?) -> Int? {
        switch value {
        case let i as Int: i
        case let i as Int32: Int(i)
        case let d as Double: Int(d)
        default: nil
        }
    }
}

/// BSON stores whole milliseconds, and the encoder truncates `seconds * 1000`: a parsed
/// ".811" held as .81099999… would be stored as .810. Every date written or queried goes
/// through here so it lands on the nearest millisecond instead.
func bsonDate(_ date: Date) -> Date {
    let ms = (date.timeIntervalSince1970 * 1000).rounded()
    return Date(timeIntervalSince1970: (ms + 0.5) / 1000)
}

/// Fails with `.timeout` if `operation` has not finished in time. Unlike a task group,
/// it does not wait for an operation that ignores cancellation.
func withTimeout<T: Sendable>(_ timeout: Duration,
                              _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
        gate.set(continuation)
        let work = Task {
            do { gate.resume(with: .success(try await operation())) } catch { gate.resume(with: .failure(error)) }
        }
        Task {
            try? await Task.sleep(for: timeout)
            gate.resume(with: .failure(MongoStore.StoreError.timeout))
            work.cancel()
        }
    }
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ c: CheckedContinuation<T, Error>) {
        lock.withLock { continuation = c }
    }

    func resume(with result: Result<T, Error>) {
        let c: CheckedContinuation<T, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(with: result)
    }
}
