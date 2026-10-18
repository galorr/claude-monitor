import Foundation

public enum SessionSource: String, Codable, Sendable {
    case terminal, desktop, unknown

    /// decisions.md D-007: desktop if the process ancestry contains Claude.app (or the
    /// desktop-bundled claude binary), terminal if there is a tty, else unknown.
    public static func detect(_ e: HookEvent) -> SessionSource {
        if let chain = e.procChain, chain.contains(where: { $0.contains("/Applications/Claude.app/") }) {
            return .desktop
        }
        if let path = e.claudePath, path.contains("/Application Support/Claude/claude-code/") {
            return .desktop
        }
        if let envNames = e.envNames, envNames.contains("CLAUDE_CODE_DESKTOP_APP_VERSION") {
            return .desktop
        }
        if e.tty != nil { return .terminal }
        return .unknown
    }
}

public enum SessionState: String, Codable, Sendable, CaseIterable {
    case idle
    case working
    case needsPermission = "needs_permission"
    case waitingInput = "waiting_input"
    case doneUnreviewed = "done_unreviewed"
    case stale
    case reviewed
    case presumedDead = "presumed_dead"
    case closed

    /// Lower = more urgent. Spec order: needs_permission > waiting_input >
    /// done_unreviewed > stale > working > idle > reviewed (then dead/closed).
    public var urgencyRank: Int {
        switch self {
        case .needsPermission: 0
        case .waitingInput: 1
        case .doneUnreviewed: 2
        case .stale: 3
        case .working: 4
        case .idle: 5
        case .reviewed: 6
        case .presumedDead: 7
        case .closed: 8
        }
    }

    /// States that count towards the menu-bar badge.
    public var needsAttention: Bool {
        self == .needsPermission || self == .waitingInput || self == .doneUnreviewed
    }

    public var canMarkReviewed: Bool { self == .doneUnreviewed || self == .waitingInput }

    /// A live claude process is expected: the sweeper checks its pid.
    /// (done/reviewed sessions are left to the time-based rule: the result still matters.)
    public var isActive: Bool {
        self == .idle || self == .working || self == .needsPermission || self == .waitingInput || self == .stale
    }

    public var isEnded: Bool { self == .closed || self == .presumedDead }

    public var displayName: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .needsPermission: "Needs permission"
        case .waitingInput: "Waiting for input"
        case .doneUnreviewed: "Done"
        case .stale: "Stale"
        case .reviewed: "Reviewed"
        case .presumedDead: "Presumed dead"
        case .closed: "Closed"
        }
    }
}

/// `epic/<KEY>/T<n>` is a fixed contract with the epic-planner plugin (spec).
public struct EpicRef: Equatable, Sendable {
    public var epicKey: String
    public var taskId: String

    public static func parse(branch: String?) -> EpicRef? {
        guard let branch else { return nil }
        let parts = branch.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "epic", !parts[1].isEmpty else { return nil }
        let task = parts[2]
        guard task.count > 1, task.first == "T", task.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return EpicRef(epicKey: String(parts[1]), taskId: String(task))
    }
}

public struct Session: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var cwd: String?
    public var repo: String?
    public var branch: String?
    public var epicKey: String?
    public var taskId: String?
    public var source: SessionSource
    public var tty: String?
    public var claudePid: Int?
    public var state: SessionState
    public var lastEventAt: Date
    public var lastMessage: String?
    public var acknowledgedAt: Date?
    public var updatedAt: Date

    public init(id: String, at: Date) {
        self.id = id
        source = .unknown
        state = .idle
        lastEventAt = at
        updatedAt = at
    }

    /// Short name for the row: git root folder, else cwd folder, else the id.
    public var displayRepo: String { repo ?? String(id.prefix(8)) }
}

public struct StateChange: Equatable, Sendable {
    public var sessionId: String
    /// nil when the event created the session.
    public var from: SessionState?
    public var to: SessionState
    public var at: Date

    public init(sessionId: String, from: SessionState?, to: SessionState, at: Date) {
        self.sessionId = sessionId
        self.from = from
        self.to = to
        self.at = at
    }
}

/// User-tunable thresholds (spec Phase 2). Stored by the app in UserDefaults.
public struct MonitorSettings: Codable, Equatable, Sendable {
    public var staleAfterMinutes = 10
    public var deadAfterHours = 6
    public var hideEndedAfterHours = 24
    public var notificationsEnabled = true
    /// Mongo TTL on events and transitions (spec Phase 3: 30 days, configurable).
    public var retentionDays = 30

    public init() {}

    // Settings saved before a field existed decode with that field's default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MonitorSettings()
        staleAfterMinutes = try c.decodeIfPresent(Int.self, forKey: .staleAfterMinutes) ?? d.staleAfterMinutes
        deadAfterHours = try c.decodeIfPresent(Int.self, forKey: .deadAfterHours) ?? d.deadAfterHours
        hideEndedAfterHours = try c.decodeIfPresent(Int.self, forKey: .hideEndedAfterHours) ?? d.hideEndedAfterHours
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
        retentionDays = try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays
    }

    public var staleAfter: TimeInterval { TimeInterval(staleAfterMinutes * 60) }
    public var deadAfter: TimeInterval { TimeInterval(deadAfterHours * 3600) }
    public var hideEndedAfter: TimeInterval { TimeInterval(hideEndedAfterHours * 3600) }
}

/// Which state changes produce a macOS notification, and its text.
public enum NotificationPolicy {
    public static let notifyingStates: Set<SessionState> = [.needsPermission, .waitingInput, .doneUnreviewed]

    /// Changes older than this (replay at launch, backlog after the app was off) stay silent.
    public static let maxAge: TimeInterval = 5 * 60

    /// One notification per transition INTO a notifying state, only for fresh events.
    public static func shouldNotify(_ change: StateChange, now: Date) -> Bool {
        notifyingStates.contains(change.to)
            && change.from != change.to
            && now.timeIntervalSince(change.at) <= maxAge
    }

    public static func content(for session: Session) -> (title: String, body: String) {
        var title = "\(session.displayRepo): \(session.state.displayName)"
        if let task = session.taskId { title += " (\(task))" }
        let body = session.lastMessage ?? session.branch ?? ""
        return (title, body)
    }
}
