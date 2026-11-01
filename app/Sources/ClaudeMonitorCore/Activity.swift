import Foundation

/// Background work and published artifacts, tracked per session from the hook events
/// (decisions.md D-017). Both live in the SessionStore so they replay with the file.

public enum BackgroundJobKind: String, Codable, Sendable {
    case shell, subagent
}

/// A background shell command or an async subagent started by a session.
public struct BackgroundJob: Codable, Equatable, Sendable, Identifiable {
    /// `<session id>:<Claude Code task id>`; task ids are only unique within a session.
    public var id: String
    public var taskId: String
    public var sessionId: String
    /// Repo of the session when the task started, for the row.
    public var repo: String?
    public var kind: BackgroundJobKind
    public var description: String?
    public var command: String?
    public var agentType: String?
    public var startedAt: Date
    /// Last event that confirmed the task was still running.
    public var lastSeenAt: Date
    public var finishedAt: Date?

    public var isRunning: Bool { finishedAt == nil }

    public var title: String {
        description ?? command ?? agentType ?? taskId
    }

    /// Second line of the row: what runs, when it differs from the title.
    public var detail: String? {
        switch kind {
        case .shell: description != nil ? command : nil
        case .subagent: agentType
        }
    }

    static func key(sessionId: String, taskId: String) -> String { "\(sessionId):\(taskId)" }
}

/// An artifact published through the Artifact tool, keyed by its URL.
public struct ArtifactRecord: Codable, Equatable, Sendable, Identifiable {
    public var id: String { url }
    public var url: String
    public var title: String?
    public var icon: String?
    public var sessionId: String
    public var repo: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var publishCount: Int

    public var displayTitle: String {
        if let title { return title }
        // "https://claude.ai/artifact/NSSNy2…" → "artifact/NSSNy2…"
        return url.split(separator: "/").suffix(2).joined(separator: "/")
    }
}

public enum ActivityPolicy {
    /// A finished task stays in the list this long, so a result is not missed.
    public static let finishedTaskVisibleFor: TimeInterval = 60 * 60
    /// Artifacts are durable links; keep the recent ones and drop the rest.
    public static let maxVisibleArtifacts = 20
    public static let artifactRetention: TimeInterval = 30 * 86400
}

extension SessionStore {
    /// Running tasks first (newest start first), then recently finished ones.
    public func visibleTasks(now: Date) -> [BackgroundJob] {
        tasks.values
            .filter { $0.isRunning || now.timeIntervalSince($0.finishedAt!) <= ActivityPolicy.finishedTaskVisibleFor }
            .sorted {
                if $0.isRunning != $1.isRunning { return $0.isRunning }
                if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
                return $0.id < $1.id
            }
    }

    public var runningTaskCount: Int { tasks.values.filter(\.isRunning).count }

    /// Most recently published first.
    public var visibleArtifacts: [ArtifactRecord] {
        Array(artifacts.values
            .sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.url < $1.url }
            .prefix(ActivityPolicy.maxVisibleArtifacts))
    }

    // MARK: - Rules (called from apply / sweep)

    /// Records tasks and artifacts revealed by `e`. `isLate` events (older than the
    /// session's last one) may still add work, but never finish it.
    mutating func absorbActivity(_ e: HookEvent, session s: Session, isLate: Bool) {
        switch e.kind {
        case .postToolUse:
            guard let tool = e.tool else { return }
            switch e.toolName {
            case "Bash":
                guard tool.runInBackground, let taskId = tool.backgroundTaskId else { return }
                startTask(taskId, session: s, kind: .shell, at: e.ts,
                          description: tool.description, command: tool.command, agentType: nil)
            case "Agent":
                guard tool.isAsync, let agentId = tool.agentId else { return }
                startTask(agentId, session: s, kind: .subagent, at: e.ts,
                          description: tool.description, command: nil, agentType: tool.subagentType)
            case "Artifact":
                absorbArtifact(tool, session: s, at: e.ts)
            default:
                return
            }
        case .stop, .stopFailure:
            guard !isLate, let snapshot = e.backgroundTasks else { return }
            reconcile(snapshot, session: s, at: e.ts)
        case .sessionEnd:
            guard !isLate else { return }
            finishTasks(of: s.id, at: e.ts)
        default:
            return
        }
    }

    private mutating func startTask(_ taskId: String, session s: Session, kind: BackgroundJobKind, at: Date,
                                    description: String?, command: String?, agentType: String?) {
        let key = BackgroundJob.key(sessionId: s.id, taskId: taskId)
        if var t = tasks[key] {
            // Seen in a Stop snapshot before the launch event (out-of-order async hooks).
            t.startedAt = min(t.startedAt, at)
            t.description = t.description ?? description
            t.command = t.command ?? command
            t.agentType = t.agentType ?? agentType
            tasks[key] = t
            return
        }
        tasks[key] = BackgroundJob(id: key, taskId: taskId, sessionId: s.id, repo: s.repo, kind: kind,
                                    description: description, command: command, agentType: agentType,
                                    startedAt: at, lastSeenAt: at, finishedAt: nil)
    }

    /// Stop's `background_tasks` is authoritative: what it lists is running (or carries
    /// its own status), everything else of this session has finished.
    private mutating func reconcile(_ snapshot: [BackgroundTaskSnapshot], session s: Session, at: Date) {
        var listed = Set<String>()
        for entry in snapshot {
            let key = BackgroundJob.key(sessionId: s.id, taskId: entry.id)
            listed.insert(key)
            let kind: BackgroundJobKind = entry.type == "subagent" ? .subagent : .shell
            var t = tasks[key] ?? BackgroundJob(id: key, taskId: entry.id, sessionId: s.id, repo: s.repo, kind: kind,
                                                 description: entry.description, command: entry.command,
                                                 agentType: entry.agentType, startedAt: at, lastSeenAt: at,
                                                 finishedAt: nil)
            t.description = t.description ?? entry.description
            t.command = t.command ?? entry.command
            t.agentType = t.agentType ?? entry.agentType
            let running = entry.status == nil || entry.status == "running"
            if running {
                t.lastSeenAt = max(t.lastSeenAt, at)
                if let finished = t.finishedAt, finished < at { t.finishedAt = nil } // finished early by mistake
            } else if t.finishedAt == nil {
                t.finishedAt = at
            }
            tasks[key] = t
        }
        for (key, var t) in tasks where t.sessionId == s.id && t.isRunning && !listed.contains(key) {
            // Started after this Stop (async hooks out of order): leave it.
            guard t.startedAt <= at else { continue }
            t.finishedAt = at
            tasks[key] = t
        }
    }

    mutating func finishTasks(of sessionId: String, at: Date) {
        for (key, var t) in tasks where t.sessionId == sessionId && t.isRunning {
            t.finishedAt = max(at, t.startedAt)
            tasks[key] = t
        }
    }

    private mutating func absorbArtifact(_ tool: ToolCall, session s: Session, at: Date) {
        guard let url = tool.url, url.hasPrefix("https://") else { return }
        switch tool.action {
        case nil, "publish":
            if var a = artifacts[url] {
                a.title = tool.title ?? a.title
                a.icon = tool.icon ?? a.icon
                a.updatedAt = max(a.updatedAt, at)
                a.publishCount += 1
                a.sessionId = s.id
                a.repo = s.repo ?? a.repo
                artifacts[url] = a
            } else {
                artifacts[url] = ArtifactRecord(url: url, title: tool.title, icon: tool.icon, sessionId: s.id,
                                                repo: s.repo, createdAt: at, updatedAt: at, publishCount: 1)
            }
        case "delete":
            artifacts[url] = nil
        default:
            return // read, list, open, pin…: not a publication
        }
    }

    /// Periodic: ends the tasks of dead sessions, drops old finished tasks and old
    /// artifacts. Returns whether anything changed.
    @discardableResult
    public mutating func sweepActivity(now: Date, settings: MonitorSettings) -> Bool {
        let before = (tasks, artifacts)
        for (key, var t) in tasks {
            if t.isRunning, let s = sessions[t.sessionId], s.state.isEnded {
                t.finishedAt = max(s.lastEventAt, t.startedAt)
                tasks[key] = t
            }
            if let finished = t.finishedAt, now.timeIntervalSince(finished) > settings.hideEndedAfter {
                tasks[key] = nil
            }
        }
        for (url, a) in artifacts where now.timeIntervalSince(a.updatedAt) > ActivityPolicy.artifactRetention {
            artifacts[url] = nil
        }
        return before != (tasks, artifacts)
    }
}
