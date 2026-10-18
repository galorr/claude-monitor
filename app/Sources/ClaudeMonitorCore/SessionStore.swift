import Foundation

/// Pure state machine over hook events, keyed by session_id. See decisions.md D-008.
public struct SessionStore: Codable, Equatable, Sendable {
    public private(set) var sessions: [String: Session] = [:]

    static let maxMessageLength = 300

    public init() {}

    /// Applies one event. Returns the state change it caused, if any (nil also for
    /// late events, which only fill in metadata).
    @discardableResult
    public mutating func apply(_ e: HookEvent) -> StateChange? {
        let existing = sessions[e.sessionId]
        var s = existing ?? Session(id: e.sessionId, at: e.ts)
        // Async hooks can land out of order: an older event updates metadata only.
        let isLate = existing != nil && e.ts < s.lastEventAt
        var change: StateChange?

        absorbMetadata(e, into: &s, overwrite: !isLate)
        if !isLate {
            // The permission_prompt text is generic; keep PermissionRequest's "Permission: <tool>".
            let keepMessage = s.state == .needsPermission && e.notificationType == "permission_prompt"
            s.lastEventAt = e.ts
            let previous = existing?.state
            if let next = Self.transition(from: s.state, on: e), next != s.state {
                s.state = next
                if next != .reviewed { s.acknowledgedAt = nil }
            }
            if s.state != previous {
                change = StateChange(sessionId: s.id, from: previous, to: s.state, at: e.ts)
            }
            if !keepMessage, let msg = Self.message(for: e) {
                s.lastMessage = String(msg.prefix(Self.maxMessageLength))
            }
        }
        s.updatedAt = max(s.updatedAt, e.ts)
        sessions[e.sessionId] = s
        return change
    }

    /// User action. Returns false if the session is not in a reviewable state.
    @discardableResult
    public mutating func markReviewed(_ id: String, at: Date) -> Bool {
        guard var s = sessions[id], s.state.canMarkReviewed else { return false }
        s.state = .reviewed
        s.acknowledgedAt = at
        s.updatedAt = max(s.updatedAt, at)
        sessions[id] = s
        return true
    }

    /// "Review all done": every done_unreviewed session becomes reviewed.
    /// waiting_input is left alone, since it still needs an answer. Returns how many changed.
    @discardableResult
    public mutating func markAllDoneReviewed(at: Date) -> Int {
        let ids = sessions.values.filter { $0.state == .doneUnreviewed }.map(\.id)
        for id in ids { markReviewed(id, at: at) }
        return ids.count
    }

    /// Periodic sweep (decisions.md D-011). Order of rules:
    /// 1. no event for `deadAfter` → presumed_dead (any open state)
    /// 2. an active session whose claude process is gone → presumed_dead
    /// 3. working with no event for `staleAfter` → stale
    public mutating func sweep(now: Date, settings: MonitorSettings,
                               isAlive: (Int) -> Bool) -> [StateChange] {
        var changes: [StateChange] = []
        for id in sessions.keys.sorted() {
            guard var s = sessions[id], s.state != .closed, s.state != .presumedDead else { continue }
            let quiet = now.timeIntervalSince(s.lastEventAt)
            let next: SessionState?
            if quiet > settings.deadAfter {
                next = .presumedDead
            } else if s.state.isActive, let pid = s.claudePid, !isAlive(pid) {
                next = .presumedDead
            } else if s.state == .working, quiet > settings.staleAfter {
                next = .stale
            } else {
                next = nil
            }
            guard let next else { continue }
            changes.append(StateChange(sessionId: id, from: s.state, to: next, at: now))
            s.state = next
            s.updatedAt = max(s.updatedAt, now)
            sessions[id] = s
        }
        return changes
    }

    /// The list as shown: closed / presumed_dead sessions disappear once their last
    /// event is older than `hideEndedAfter`.
    public func visible(now: Date, settings: MonitorSettings) -> [Session] {
        sorted.filter {
            !($0.state.isEnded && now.timeIntervalSince($0.lastEventAt) > settings.hideEndedAfter)
        }
    }

    /// Sorted by urgency, then most recent event first.
    public var sorted: [Session] {
        sessions.values.sorted {
            if $0.state.urgencyRank != $1.state.urgencyRank {
                return $0.state.urgencyRank < $1.state.urgencyRank
            }
            if $0.lastEventAt != $1.lastEventAt { return $0.lastEventAt > $1.lastEventAt }
            return $0.id < $1.id
        }
    }

    public var attentionCount: Int { sessions.values.filter(\.state.needsAttention).count }

    // MARK: - Rules

    static func transition(from state: SessionState, on e: HookEvent) -> SessionState? {
        switch e.kind {
        case .sessionStart:
            // Compaction mid-turn must not reset a working session.
            if e.source == "compact" && state != .closed { return nil }
            return .idle
        case .userPromptSubmit:
            return .working
        case .permissionRequest:
            return .needsPermission
        case .notification:
            switch e.notificationType {
            case "permission_prompt":
                return .needsPermission
            case "elicitation_dialog", "agent_needs_input":
                return .waitingInput
            case "idle_prompt":
                // After Stop this is only the 60s reminder; the turn is already done.
                return state == .doneUnreviewed || state == .reviewed ? nil : .waitingInput
            default:
                return nil
            }
        case .postToolUse:
            // A tool ran: any pending permission/input was answered.
            switch state {
            case .needsPermission, .waitingInput, .idle, .stale, .presumedDead, .closed: return .working
            default: return nil
            }
        case .stop, .stopFailure:
            return .doneUnreviewed
        case .sessionEnd:
            return .closed
        case .other:
            return nil
        }
    }

    static func message(for e: HookEvent) -> String? {
        switch e.kind {
        case .userPromptSubmit: e.prompt
        case .notification: e.message
        case .permissionRequest: e.toolName.map { "Permission: \($0)" }
        case .stop: e.lastAssistantMessage
        case .stopFailure: e.error ?? e.message ?? "Turn ended with an error"
        default: nil
        }
    }

    /// "/Applications/Visual Studio Code.app/Contents/Frameworks/…/Helper" → "/Applications/Visual Studio Code.app".
    /// The outermost app wins: a desktop chain also contains a bundled `claude.app` binary.
    static func hostApp(_ chain: [String]) -> String? {
        guard let outer = chain.last(where: { $0.contains(".app/") }),
              let end = outer.range(of: ".app/") else { return nil }
        return String(outer[..<end.lowerBound]) + ".app"
    }

    private func absorbMetadata(_ e: HookEvent, into s: inout Session, overwrite: Bool) {
        func set<T>(_ keyPath: WritableKeyPath<Session, T?>, _ value: T?) {
            guard let value else { return }
            if overwrite || s[keyPath: keyPath] == nil { s[keyPath: keyPath] = value }
        }
        set(\.cwd, e.cwd)
        set(\.tty, e.tty)
        set(\.claudePid, e.claudePid)
        set(\.hostApp, e.procChain.flatMap(Self.hostApp))
        let repoPath = e.gitRoot ?? e.cwd
        set(\.repo, repoPath.map { URL(fileURLWithPath: $0).lastPathComponent })
        set(\.branch, e.gitBranch)
        if let epic = EpicRef.parse(branch: e.gitBranch) {
            set(\.epicKey, epic.epicKey)
            set(\.taskId, epic.taskId)
        } else if overwrite, e.gitBranch != nil {
            s.epicKey = nil
            s.taskId = nil
        }
        // Same session resumed from another source: the newest detectable source wins.
        let source = SessionSource.detect(e)
        if source != .unknown && (overwrite || s.source == .unknown) { s.source = source }
    }
}
