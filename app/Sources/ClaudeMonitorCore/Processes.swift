import Foundation

/// CPU used by the processes Claude sessions started (decisions.md D-018).
/// Everything here is pure: the live process table comes in as `[ProcSample]`.

/// A process at one moment. `startedAt` together with `pid` identifies it (pids are reused).
public struct ProcSample: Codable, Equatable, Sendable {
    public var pid: Int32
    public var ppid: Int32
    public var startedAt: Date
    /// User + system CPU time used so far.
    public var cpuSeconds: Double
    public var name: String
    /// Only read for processes the attribution needs (see `ProcessTree.needsArgs`).
    public var args: [String]?

    public init(pid: Int32, ppid: Int32, startedAt: Date, cpuSeconds: Double, name: String, args: [String]? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.startedAt = startedAt
        self.cpuSeconds = cpuSeconds
        self.name = name
        self.args = args
    }

    public var key: ProcKey { ProcKey(pid: pid, startedAt: startedAt) }
}

public struct ProcKey: Hashable, Sendable {
    public var pid: Int32
    public var startedAt: Date

    /// Stable text form, used as the id of a group and in notification identifiers.
    public var id: String { "\(pid)@\(Int((startedAt.timeIntervalSince1970 * 1000).rounded()))" }
}

public enum ProcessKind: String, Codable, Sendable {
    /// A shell Claude Code started for the Bash tool (foreground or background).
    case shell
    /// A child started together with claude: MCP servers.
    case mcp
    /// Anything else claude started directly (caffeinate, …).
    case other
}

/// One direct child of a claude process (or an orphaned Claude shell) with everything below it.
public struct ProcessGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var pid: Int32
    public var sessionId: String?
    public var repo: String?
    public var kind: ProcessKind
    /// The Bash tool command for a shell; a short command line otherwise.
    public var command: String
    /// The busiest process below the root, when it is not the root itself.
    public var hottest: String?
    /// Current CPU of the whole subtree, per core like `top` (200 = two cores).
    public var cpuPercent: Double
    /// CPU time used so far by the processes alive now.
    public var cpuSeconds: Double
    public var processCount: Int
    public var startedAt: Date
    /// The claude process that started it is gone (the shell was reparented to launchd).
    public var orphaned: Bool
    /// Its session has ended (closed / presumed dead) but it still runs.
    public var sessionEnded: Bool

    /// A shell still running although nothing in Claude is waiting for it. MCP servers of a
    /// claude that outlived its session (an idle `bg-spare`) are expected residents, not leftovers.
    public var isLeftover: Bool { kind == .shell && (orphaned || sessionEnded) }

    public func age(now: Date) -> TimeInterval { now.timeIntervalSince(startedAt) }

    /// The command's first non-empty line (heredocs and scripts span several), for one-line rows.
    public var commandSummary: String {
        let lines = command.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return command }
        return lines.count > 1 ? first + " …" : first
    }
}

public enum ProcessPolicy {
    /// The sampling period.
    public static let interval: TimeInterval = 5
    /// Groups below this are not listed unless they are leftovers or long-running shells.
    public static let listMinPercent: Double = 10
    /// A shell older than this is listed even when idle.
    public static let listMinShellAge: TimeInterval = 60
    /// A session row shows its CPU from this much on.
    public static let badgeMinPercent: Double = 25
    /// A non-shell child started this close to claude itself counts as an MCP server.
    public static let mcpStartWindow: TimeInterval = 30
    /// A leftover must stay one this long before it is reported (claude may be exiting).
    public static let leftoverGrace: TimeInterval = 60
    /// Leeway for comparing process start times (kernel clock) with hook timestamps.
    public static let clockSlack: TimeInterval = 5

    /// What the Processes section lists: busiest first.
    public static func visible(_ groups: [ProcessGroup], now: Date, longShellHours: Int) -> [ProcessGroup] {
        groups.filter { g in
            g.cpuPercent >= listMinPercent || g.isLeftover
                || (g.kind == .shell && g.age(now: now) >= listMinShellAge)
        }
        .sorted {
            if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
            if $0.isLeftover != $1.isLeftover { return $0.isLeftover }
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            return $0.id < $1.id
        }
    }

    /// "170%", "4.2%", "0%".
    public static func format(percent: Double) -> String {
        if percent >= 10 { return "\(Int(percent.rounded()))%" }
        if percent >= 0.1 { return String(format: "%.1f%%", percent) }
        return "0%"
    }

    /// "45s", "12m", "5h 32m", "3d 4h".
    public static func format(duration: TimeInterval) -> String {
        let s = max(0, Int(duration))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400)d \(s % 86400 / 3600)h"
    }
}

/// Reading the command lines Claude Code gives its shells.
public enum ClaudeShell {
    static let snapshotMarker = "/shell-snapshots/snapshot-"

    /// `zsh -c "source …/shell-snapshots/snapshot-zsh-….sh … && eval '<cmd>' < /dev/null && pwd -P >| …"`.
    public static func isClaudeShell(_ args: [String]?) -> Bool {
        guard let args, args.count >= 3, args[1].hasPrefix("-") , args[1].contains("c") else { return false }
        return args[2].contains(snapshotMarker)
    }

    /// The snapshot file the shell sources: one per claude process, so it names the owner.
    public static func snapshotPath(_ args: [String]?) -> String? {
        guard isClaudeShell(args), let script = args?[2],
              let source = script.range(of: "source ") else { return nil }
        let rest = script[source.upperBound...]
        let path = rest.prefix { !$0.isWhitespace }
        return path.contains(snapshotMarker) ? String(path) : nil
    }

    /// The Bash tool command: the single-quoted word after `eval `, with `'\''` unescaped.
    public static func command(_ args: [String]?) -> String? {
        guard isClaudeShell(args), let script = args?[2],
              let eval = script.range(of: "eval '") else { return nil }
        var out = ""
        var i = eval.upperBound
        let end = script.endIndex
        // Inside quotes until the closing `'`; then `\'` adds a quote and `'` reopens.
        while i < end {
            let c = script[i]
            if c != "'" {
                out.append(c)
                i = script.index(after: i)
                continue
            }
            let next = script.index(after: i)
            guard next < end, script[next...].hasPrefix("\\''") else { return out }
            out.append("'")
            i = script.index(next, offsetBy: 3)
        }
        return out
    }
}

/// Short, readable command lines: `node …/bin/eslint .` → `eslint .`.
public enum ProcessLabel {
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "Python", "ruby", "perl",
                                            "bash", "sh", "zsh", "java"]

    public static func short(_ sample: ProcSample, maxLength: Int = 120) -> String {
        guard var args = sample.args, !args.isEmpty else { return sample.name }
        var head = URL(fileURLWithPath: args[0]).lastPathComponent
        if isInterpreter(head), args.count > 1, !args[1].hasPrefix("-") {
            args.removeFirst()
            head = URL(fileURLWithPath: args[0]).lastPathComponent
        }
        let text = ([head] + args.dropFirst()).joined(separator: " ")
        return text.count > maxLength ? String(text.prefix(maxLength - 1)) + "…" : text
    }

    static func isInterpreter(_ name: String) -> Bool {
        interpreters.contains(name) || name.hasPrefix("python3.")
    }
}

/// Splits the process table into groups and assigns them to sessions.
public struct ProcessTree {
    /// Which claude process belongs to which session. Several sessions can share one
    /// process (`/clear` starts a new session id in the same claude): the newest wins.
    public static func roots(_ sessions: [Session], table: [Int32: ProcSample]) -> [Int32: Session] {
        var roots: [Int32: Session] = [:]
        for s in sessions {
            guard let pid = s.claudePid.map(Int32.init), let p = table[pid],
                  // A process started after the session's last event is a reused pid.
                  p.startedAt <= s.lastEventAt.addingTimeInterval(ProcessPolicy.clockSlack) else { continue }
            if let other = roots[pid], other.lastEventAt >= s.lastEventAt { continue }
            roots[pid] = s
        }
        return roots
    }

    /// The pids whose command line the attribution needs: everything below a claude root
    /// and every launchd child that could be an orphaned Claude shell (plus its subtree).
    public static func needsArgs(_ samples: [ProcSample], roots: Set<Int32>) -> Set<Int32> {
        let children = Dictionary(grouping: samples, by: \.ppid)
        let launchdShells = samples.filter { $0.ppid == 1 && ["zsh", "bash", "sh"].contains($0.name) }.map(\.pid)
        var result = Set(launchdShells)
        var stack = Array(roots) + launchdShells
        while let pid = stack.popLast() {
            // A root's own walk covers its subtree; launchd shells stop at it.
            for c in children[pid] ?? [] where !result.contains(c.pid) && !roots.contains(c.pid) {
                result.insert(c.pid)
                stack.append(c.pid)
            }
        }
        return result
    }

    /// Groups for every claude root's children, plus orphaned Claude shells.
    /// `owners` (snapshot path → session id) is learned here while claude is alive,
    /// and used to name the session of a shell that outlived it.
    public static func groups(_ samples: [ProcSample], sessions: [Session], rates: [ProcKey: Double],
                              owners: inout [String: String]) -> [ProcessGroup] {
        let table = Dictionary(samples.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let children = Dictionary(grouping: samples, by: \.ppid)
        let roots = roots(sessions, table: table)
        let byId = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var groups: [ProcessGroup] = []

        func group(_ head: ProcSample, session: Session?, kind: ProcessKind, orphaned: Bool) -> ProcessGroup {
            // The whole subtree, stopping at another session's claude.
            var members = [head]
            var stack = [head.pid]
            while let pid = stack.popLast() {
                for c in children[pid] ?? [] where roots[c.pid] == nil {
                    members.append(c)
                    stack.append(c.pid)
                }
            }
            let rate = { (p: ProcSample) in rates[p.key] ?? 0 }
            let busiest = members.max { rate($0) < rate($1) }
            let hottest = busiest.flatMap { b in b.pid != head.pid && rate(b) >= 1 ? ProcessLabel.short(b) : nil }
            let command = kind == .shell ? (ClaudeShell.command(head.args) ?? ProcessLabel.short(head))
                                         : ProcessLabel.short(head)
            return ProcessGroup(id: head.key.id, pid: head.pid, sessionId: session?.id, repo: session?.repo, kind: kind,
                                command: command, hottest: hottest,
                                cpuPercent: members.reduce(0) { $0 + rate($1) },
                                cpuSeconds: members.reduce(0) { $0 + $1.cpuSeconds },
                                processCount: members.count, startedAt: head.startedAt,
                                orphaned: orphaned, sessionEnded: session?.state.isEnded ?? false)
        }

        for (pid, session) in roots {
            let root = table[pid]!
            for child in children[pid] ?? [] where roots[child.pid] == nil {
                let kind: ProcessKind
                if ClaudeShell.isClaudeShell(child.args) {
                    kind = .shell
                    if let path = ClaudeShell.snapshotPath(child.args) { owners[path] = session.id }
                } else if child.startedAt.timeIntervalSince(root.startedAt) <= ProcessPolicy.mcpStartWindow {
                    kind = .mcp
                } else {
                    kind = .other
                }
                groups.append(group(child, session: session, kind: kind, orphaned: false))
            }
        }
        for p in samples where p.ppid == 1 && ClaudeShell.isClaudeShell(p.args) {
            let session = ClaudeShell.snapshotPath(p.args).flatMap { owners[$0] }.flatMap { byId[$0] }
            groups.append(group(p, session: session, kind: .shell, orphaned: true))
        }
        return groups
    }

    /// Current CPU per session (all its groups), for the row badge.
    public static func cpuBySession(_ groups: [ProcessGroup]) -> [String: Double] {
        var result: [String: Double] = [:]
        for g in groups where !g.orphaned {
            guard let id = g.sessionId else { continue }
            result[id, default: 0] += g.cpuPercent
        }
        return result
    }
}

/// CPU % from the difference between two samples of the same process.
public struct CpuRateTracker: Sendable {
    private var last: [ProcKey: Double] = [:]
    private var lastAt: Date?

    public init() {}

    public mutating func rates(_ samples: [ProcSample], at now: Date) -> [ProcKey: Double] {
        var rates: [ProcKey: Double] = [:]
        var next: [ProcKey: Double] = [:]
        for s in samples {
            next[s.key] = s.cpuSeconds
            if let lastAt, let before = last[s.key], now > lastAt {
                rates[s.key] = max(0, (s.cpuSeconds - before) / now.timeIntervalSince(lastAt) * 100)
            } else if let lastAt, s.startedAt >= lastAt {
                // Started since the last sample: average over its own life so far.
                rates[s.key] = max(0, s.cpuSeconds / max(now.timeIntervalSince(s.startedAt), 1) * 100)
            }
        }
        last = next
        lastAt = now
        return rates
    }
}

public struct ProcessAlert: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Over the CPU threshold for the configured minutes.
        case hot
        /// Still running after claude or its session went away.
        case leftover
        /// A Claude shell running for longer than the configured hours.
        case longRunning = "long_running"
    }

    public var kind: Kind
    public var group: ProcessGroup

    public var id: String { "proc.\(kind.rawValue).\(group.id)" }

    public func content(now: Date) -> (title: String, subtitle: String, body: String) {
        let repo = group.repo ?? "Claude"
        let what = group.kind == .shell ? "shell" : group.kind == .mcp ? "MCP server" : "process"
        let title: String
        switch kind {
        case .hot: title = "\(repo): \(what) at \(ProcessPolicy.format(percent: group.cpuPercent)) CPU"
        case .leftover: title = "\(repo): \(what) left running"
        case .longRunning: title = "\(repo): \(what) running for \(ProcessPolicy.format(duration: group.age(now: now)))"
        }
        var body: [String] = []
        if let hottest = group.hottest { body.append("Busiest: \(hottest)") }
        if kind == .leftover {
            body.append(group.orphaned ? "Its claude process has exited." : "Its session has ended.")
        }
        body.append("pid \(group.pid) · \(group.processCount) process\(group.processCount == 1 ? "" : "es") · "
                    + "\(ProcessPolicy.format(duration: group.cpuSeconds)) CPU time")
        return (title, group.commandSummary, body.joined(separator: "\n"))
    }
}

/// Decides when a group is worth one notification. Each kind fires at most once per group.
public struct ProcessAlertTracker: Sendable {
    private var hotSince: [String: Date] = [:]
    private var leftoverSince: [String: Date] = [:]
    /// Group id → kinds already notified.
    private var alerted: [String: Set<ProcessAlert.Kind>] = [:]

    public init() {}

    public mutating func evaluate(_ groups: [ProcessGroup], now: Date, settings: MonitorSettings) -> [ProcessAlert] {
        let threshold = Double(settings.cpuAlertPercent)
        var alerts: [ProcessAlert] = []
        let alive = Set(groups.map(\.id))
        hotSince = hotSince.filter { alive.contains($0.key) }
        leftoverSince = leftoverSince.filter { alive.contains($0.key) }
        alerted = alerted.filter { alive.contains($0.key) }

        func fire(_ kind: ProcessAlert.Kind, _ g: ProcessGroup) {
            guard alerted[g.id, default: []].insert(kind).inserted else { return }
            alerts.append(ProcessAlert(kind: kind, group: g))
        }

        for g in groups {
            // Hysteresis: one dip in a busy build does not restart the clock.
            if g.cpuPercent >= threshold {
                let since = hotSince[g.id] ?? now
                hotSince[g.id] = since
                if now.timeIntervalSince(since) >= TimeInterval(settings.cpuAlertMinutes * 60) { fire(.hot, g) }
            } else if g.cpuPercent < threshold / 2 {
                hotSince[g.id] = nil
            }
            guard g.kind == .shell else { continue }
            if g.isLeftover {
                let since = leftoverSince[g.id] ?? now
                leftoverSince[g.id] = since
                if now.timeIntervalSince(since) >= ProcessPolicy.leftoverGrace { fire(.leftover, g) }
            } else {
                leftoverSince[g.id] = nil
            }
            if g.age(now: now) >= TimeInterval(settings.longShellHours * 3600) { fire(.longRunning, g) }
        }
        return alerts
    }
}
