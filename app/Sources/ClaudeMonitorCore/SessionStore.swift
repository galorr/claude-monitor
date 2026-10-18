import Foundation

/// Pure state machine over hook events, keyed by session_id. See decisions.md D-008.
public struct SessionStore: Codable, Equatable, Sendable {
    public private(set) var sessions: [String: Session] = [:]

    static let maxMessageLength = 300

    public init() {}

    public mutating func apply(_ e: HookEvent) {
        let existing = sessions[e.sessionId]
        var s = existing ?? Session(id: e.sessionId, at: e.ts)
        // Async hooks can land out of order: an older event updates metadata only.
        let isLate = existing != nil && e.ts < s.lastEventAt

        absorbMetadata(e, into: &s, overwrite: !isLate)
        if !isLate {
            // The permission_prompt text is generic; keep PermissionRequest's "Permission: <tool>".
            let keepMessage = s.state == .needsPermission && e.notificationType == "permission_prompt"
            s.lastEventAt = e.ts
            if let next = Self.transition(from: s.state, on: e), next != s.state {
                s.state = next
                if next != .reviewed { s.acknowledgedAt = nil }
            }
            if !keepMessage, let msg = Self.message(for: e) {
                s.lastMessage = String(msg.prefix(Self.maxMessageLength))
            }
        }
        s.updatedAt = max(s.updatedAt, e.ts)
        sessions[e.sessionId] = s
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

    private func absorbMetadata(_ e: HookEvent, into s: inout Session, overwrite: Bool) {
        func set<T>(_ keyPath: WritableKeyPath<Session, T?>, _ value: T?) {
            guard let value else { return }
            if overwrite || s[keyPath: keyPath] == nil { s[keyPath: keyPath] = value }
        }
        set(\.cwd, e.cwd)
        set(\.tty, e.tty)
        set(\.claudePid, e.claudePid)
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
