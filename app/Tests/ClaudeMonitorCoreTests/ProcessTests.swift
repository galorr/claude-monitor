import Foundation
import Testing
@testable import ClaudeMonitorCore

/// Process CPU attribution (decisions.md D-018) against fixtures/processes.
@Suite struct ProcessTests {
    struct TreeFixture: Decodable {
        var firstAt: Date
        var secondAt: Date
        var first: [ProcSample]
        var second: [ProcSample]
    }

    static func tree() throws -> TreeFixture {
        let url = Fixture.repoRoot.appending(path: "fixtures/processes/tree-2026-11-05.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(TreeFixture.self, from: Data(contentsOf: url))
    }

    static let base = Date(timeIntervalSince1970: 1_793_880_000)

    static func session(_ id: String, pid: Int?, repo: String, lastEvent: Double,
                        state: SessionState = .working) -> Session {
        var s = Session(id: id, at: base.addingTimeInterval(lastEvent))
        s.claudePid = pid
        s.repo = repo
        s.state = state
        return s
    }

    /// A = claude 100, B = claude 200, C = claude 141 (started by a shell in A).
    static let ttys: [String: Int32] = ["ttys001": 1001, "ttys009": 1009]

    static func sessions(bState: SessionState = .working) -> [Session] {
        var a = session("sA", pid: 100, repo: "apps", lastEvent: 6205)
        a.tty = "ttys001"
        a.hostApp = "/Applications/iTerm.app"
        return [a,
         session("sB", pid: 200, repo: "site", lastEvent: 6100, state: bState),
         // An older session of the same claude (before /clear): the newest one wins.
         session("sB-before-clear", pid: 200, repo: "site", lastEvent: 3000, state: .reviewed),
         session("sC", pid: 141, repo: "apps", lastEvent: 6100),
         // Its pid now belongs to a claude that started after its last event: reused, ignored.
         session("sOld", pid: 200, repo: "old", lastEvent: 500, state: .presumedDead)]
    }

    /// Runs both samples through the rate tracker and returns the second tick's groups.
    static func groups(sessions: [Session] = sessions()) throws -> (groups: [ProcessGroup], owners: [String: String]) {
        let t = try tree()
        var rates = CpuRateTracker()
        var owners: [String: String] = [:]
        _ = ProcessTree.groups(t.first, sessions: sessions, rates: rates.rates(t.first, at: t.firstAt),
                               ttys: ttys, owners: &owners)
        let g = ProcessTree.groups(t.second, sessions: sessions, rates: rates.rates(t.second, at: t.secondAt),
                                   ttys: ttys, owners: &owners)
        return (g, owners)
    }

    static func group(_ pid: Int32, in groups: [ProcessGroup]) -> ProcessGroup? {
        groups.first { $0.pid == pid }
    }

    // MARK: - Shell command lines

    @Test func recognisesClaudeShellsAndExtractsTheCommand() throws {
        let t = try Self.tree()
        let eslintShell = t.first.first { $0.pid == 110 }!
        #expect(ClaudeShell.isClaudeShell(eslintShell.args))
        #expect(ClaudeShell.command(eslintShell.args)
                == "npx nx run-many -t typecheck lint test 2>&1 | grep -E 'error|Failed' | head -10")
        #expect(ClaudeShell.snapshotPath(eslintShell.args)
                == "/Users/u/.claude/shell-snapshots/snapshot-zsh-1793881-abc1.sh")
        // A login shell and a claude daemon are not Claude shells.
        #expect(!ClaudeShell.isClaudeShell(["/bin/zsh", "-l"]))
        #expect(!ClaudeShell.isClaudeShell(["claude", "bg-pty-host", "--bg-pty-host", "x"]))
        #expect(ClaudeShell.command(nil) == nil)
    }

    @Test func commandSurvivesQuotesAndAMissingTail() {
        let script = "source /h/.claude/shell-snapshots/snapshot-zsh-1-x.sh && eval 'echo '\\''hi there'\\'' && ls' < /dev/null"
        #expect(ClaudeShell.command(["/bin/zsh", "-c", script]) == "echo 'hi there' && ls")
        // Background shells end right after the quote.
        let bg = "source /h/.claude/shell-snapshots/snapshot-zsh-1-x.sh && eval 'sleep 240'"
        #expect(ClaudeShell.command(["/bin/zsh", "-c", bg]) == "sleep 240")
    }

    @Test func shortLabelsDropInterpretersAndPaths() {
        let eslint = ProcSample(pid: 1, ppid: 0, startedAt: Self.base, cpuSeconds: 0, name: "node",
                                args: ["node", "/Users/u/git/apps/node_modules/.bin/eslint", "."])
        #expect(ProcessLabel.short(eslint) == "eslint .")
        let py = ProcSample(pid: 1, ppid: 0, startedAt: Self.base, cpuSeconds: 0, name: "Python",
                            args: ["/opt/homebrew/bin/python3.14", "-m", "pytest"])
        #expect(ProcessLabel.short(py) == "python3.14 -m pytest")  // a flag after it: keep the interpreter
        let noArgs = ProcSample(pid: 1, ppid: 0, startedAt: Self.base, cpuSeconds: 0, name: "caffeinate")
        #expect(ProcessLabel.short(noArgs) == "caffeinate")
        let long = ProcSample(pid: 1, ppid: 0, startedAt: Self.base, cpuSeconds: 0, name: "x",
                              args: ["x", String(repeating: "a", count: 300)])
        #expect(ProcessLabel.short(long).count == 120)
    }

    @Test func procArgsBufferIsParsed() {
        var buf: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { buf += $0 }
        buf += Array("/bin/zsh".utf8) + [0, 0, 0, 0]
        for arg in ["/bin/zsh", "-c", "echo hi"] { buf += Array(arg.utf8) + [0] }
        buf += Array("PATH=/usr/bin".utf8) + [0]  // the environment follows; not an argument
        #expect(LibprocProcessTable.parseProcArgs(buf, size: buf.count) == ["/bin/zsh", "-c", "echo hi"])
        #expect(LibprocProcessTable.parseProcArgs([1, 0], size: 2) == nil)
    }

    // MARK: - Attribution

    @Test func groupsEachSessionsChildrenByKind() throws {
        let (groups, _) = try Self.groups()
        let shell = try #require(Self.group(110, in: groups))
        #expect(shell.sessionId == "sA" && shell.repo == "apps" && shell.kind == .shell)
        #expect(shell.processCount == 5)  // zsh, npm, nx, eslint, grep
        #expect(Self.group(101, in: groups)?.kind == .mcp)
        #expect(Self.group(103, in: groups)?.kind == .mcp)
        #expect(Self.group(103, in: groups)?.command == "server.py")
        #expect(Self.group(120, in: groups)?.kind == .other)
        // claude's own CPU is not a group, and nothing outside Claude is listed.
        let pids = Set(groups.map(\.pid))
        #expect(pids.isDisjoint(with: [100, 200, 141, 50, 500, 600, 601, 700, 701]))
    }

    @Test func cpuIsTheSubtreeRateAndNamesTheBusiestProcess() throws {
        let (groups, _) = try Self.groups()
        let shell = try #require(Self.group(110, in: groups))
        #expect(abs(shell.cpuPercent - 170) < 0.01)   // eslint: 8.5 s of CPU in 5 s
        #expect(shell.hottest == "eslint .")
        #expect(shell.command.hasPrefix("npx nx run-many"))
        #expect(abs(shell.cpuSeconds - 35.11) < 0.01)
        // The idle bats shell has no busiest process to name.
        #expect(Self.group(130, in: groups)?.hottest == nil)
    }

    @Test func aNestedClaudeBelongsToItsOwnSession() throws {
        let (groups, _) = try Self.groups()
        let outer = try #require(Self.group(140, in: groups))
        #expect(outer.sessionId == "sA" && outer.processCount == 1 && outer.cpuPercent == 0)
        let inner = try #require(Self.group(142, in: groups))
        #expect(inner.sessionId == "sC" && abs(inner.cpuPercent - 80) < 0.01)
    }

    @Test func newestSessionOwnsAClaudeAndReusedPidsAreIgnored() throws {
        let (groups, _) = try Self.groups()
        let bg = try #require(Self.group(210, in: groups))
        #expect(bg.sessionId == "sB")
        #expect(!groups.contains { $0.sessionId == "sOld" || $0.sessionId == "sB-before-clear" })
    }

    @Test func orphanedShellsAreNamedThroughTheirSnapshot() throws {
        let (groups, owners) = try Self.groups()
        let orphan = try #require(Self.group(300, in: groups))
        #expect(orphan.orphaned && orphan.isLeftover)
        #expect(orphan.sessionId == "sB")  // learned from B's live shell 210
        #expect(abs(orphan.cpuPercent - 4) < 0.01)
        #expect(owners["/Users/u/.claude/shell-snapshots/snapshot-zsh-1793882-abc2.sh"] == "sB")
        let unknown = try #require(Self.group(400, in: groups))
        #expect(unknown.orphaned && unknown.sessionId == nil && unknown.command == "tail -f build.log")
    }

    @Test func shellsOfAnEndedSessionAreLeftovers() throws {
        let (groups, _) = try Self.groups(sessions: Self.sessions(bState: .closed))
        #expect(Self.group(210, in: groups)?.sessionEnded == true)
        #expect(Self.group(110, in: groups)?.isLeftover == false)
        // B's claude is still alive: its MCP-like children are residents, not leftovers.
        let ended = Self.sessions(bState: .presumedDead).map { s -> Session in
            var s = s
            if s.id == "sA" { s.state = .presumedDead }
            return s
        }
        let (all, _) = try Self.groups(sessions: ended)
        let mcp = try #require(Self.group(101, in: all))
        #expect(mcp.sessionEnded && !mcp.isLeftover)
        #expect(Self.group(110, in: all)?.isLeftover == true)
    }

    @Test func cpuBySessionSkipsOrphans() throws {
        let (groups, _) = try Self.groups()
        let by = ProcessTree.cpuBySession(groups)
        #expect(abs(by["sA"]! - 220) < 0.01)  // eslint 170 + the user's vite 50
        #expect(abs(by["sC"]! - 80) < 0.01)
        #expect(by["sB"] == 0)  // the orphan's 4% is not B's live load
    }

    @Test func needsArgsCoversRootsSubtreesAndLaunchdShells() throws {
        let t = try Self.tree()
        let wanted = ProcessTree.needsArgs(t.first, roots: [100, 200])  // no tab devices
        #expect(wanted.isSuperset(of: [101, 102, 110, 113, 141, 143, 210, 300, 301, 400, 401, 500, 50]))
        // Roots themselves, and claude daemons, are never read; the login shell 50 (a launchd
        // child) does not drag claude 100's tree in a second time.
        #expect(wanted.isDisjoint(with: [100, 200, 600, 601]))
    }

    @Test func visibleListsBusyLeftoverAndOlderShellsBusiestFirst() throws {
        let (groups, _) = try Self.groups()
        let now = Self.base.addingTimeInterval(6210)
        let visible = ProcessPolicy.visible(groups, now: now)
        #expect(visible.map(\.pid) == [110, 142, 150, 300, 400, 130, 140])
        // Hidden: idle MCP servers, caffeinate, and the 10 s old `sleep 240` shell.
    }

    // MARK: - Terminal tabs

    @Test func theUsersOwnProcessesInTheTabCount() throws {
        let (groups, _) = try Self.groups()
        let dev = try #require(Self.group(150, in: groups))
        #expect(dev.kind == .terminal && dev.sessionId == "sA" && dev.processCount == 2)
        #expect(abs(dev.cpuPercent - 50) < 0.01 && dev.hottest == "vite")
        #expect(Self.group(160, in: groups)?.kind == .terminal)
        // MCP servers share the tab's tty but stay Claude's; the login shell above claude and
        // another tab without a session are not counted.
        #expect(Self.group(101, in: groups)?.kind == .mcp)
        #expect(!groups.contains { [50, 151, 700, 701].contains($0.pid) })
    }

    @Test func noTerminalGroupsWithoutAKnownDevice() throws {
        let t = try Self.tree()
        var owners: [String: String] = [:]
        let groups = ProcessTree.groups(t.second, sessions: Self.sessions(), rates: [:], owners: &owners)
        #expect(!groups.contains { $0.kind == .terminal })
    }

    @Test func tabsGroupByTerminalBusiestFirst() throws {
        let (groups, _) = try Self.groups()
        let tabs = ProcessTab.tabs(groups, sessions: Self.sessions(), now: Self.base.addingTimeInterval(6210))
        #expect(tabs.map(\.id) == ["tty:ttys001", "session:sC", "session:sB", "unknown"])
        let a = tabs[0]
        #expect(a.title == "apps" && a.hostApp == "iTerm" && a.tty == "ttys001" && a.sessionId == "sA")
        #expect(abs(a.cpuPercent - 220) < 0.01)
        #expect(a.groups.map(\.pid) == [110, 150, 130, 140])  // idle MCP servers and `tail` not listed
        #expect(tabs[2].groups.map(\.pid) == [300])          // B: its orphan; the 10 s old shell is hidden
        #expect(tabs[3].title == "Unknown session" && tabs[3].sessionId == nil)
    }

    @Test func liveSessionsGetABadgeEvenAtZero() throws {
        let (groups, _) = try Self.groups()
        let by = ProcessTree.cpuBySession(groups.filter { $0.sessionId != "sC" }, live: ["sA", "sC"])
        #expect(by["sC"] == 0)
        #expect(abs(by["sA"]! - 220) < 0.01)
    }

    @Test func needsArgsReadsTheTabsOwnProcesses() throws {
        let t = try Self.tree()
        let wanted = ProcessTree.needsArgs(t.first, roots: [100], ttys: [1001])
        #expect(wanted.isSuperset(of: [150, 151, 160, 101]))
        #expect(!wanted.contains(100))
        // 701 is read anyway (under a launchd login shell, scanned for orphans) but never counted.
    }

    @Test func terminalDeviceNames() {
        #expect(TerminalDevice.device(named: "null") != nil)  // /dev/null is a character device
        #expect(TerminalDevice.device(named: "no-such-tty") == nil)
        #expect(TerminalDevice.device(named: "../etc/passwd") == nil)
        #expect(TerminalDevice.device(named: "") == nil)
    }

    // MARK: - Rates

    @Test func ratesNeedTwoSamplesExceptForNewProcesses() {
        let start = Self.base
        var tracker = CpuRateTracker()
        let old = ProcSample(pid: 1, ppid: 0, startedAt: start, cpuSeconds: 10, name: "a")
        #expect(tracker.rates([old], at: start.addingTimeInterval(100)).isEmpty)
        var later = old
        later.cpuSeconds = 12
        let fresh = ProcSample(pid: 2, ppid: 0, startedAt: start.addingTimeInterval(102), cpuSeconds: 3, name: "b")
        let r = tracker.rates([later, fresh], at: start.addingTimeInterval(104))
        #expect(r[old.key] == 50)          // 2 s over 4 s
        #expect(r[fresh.key] == 150)       // 3 s over its 2 s of life
        // Same pid, new start time: a different process, no bogus delta.
        let reused = ProcSample(pid: 1, ppid: 0, startedAt: start.addingTimeInterval(50), cpuSeconds: 0.5, name: "c")
        #expect(tracker.rates([reused], at: start.addingTimeInterval(108))[reused.key] == nil)
    }

    // MARK: - Alerts

    static func group(cpu: Double, age: TimeInterval = 600, kind: ProcessKind = .shell, orphaned: Bool = false,
                      now: Date) -> ProcessGroup {
        ProcessGroup(id: "g", pid: 7, sessionId: "s", repo: "apps", kind: kind, command: "npm test", hottest: "jest",
                     cpuPercent: cpu, cpuSeconds: 90, processCount: 3, startedAt: now.addingTimeInterval(-age),
                     orphaned: orphaned, sessionEnded: false)
    }

    @Test func hotAlertNeedsTheFullDurationAndFiresOnce() {
        var tracker = ProcessAlertTracker()
        let s = MonitorSettings()  // 150% for 2 min
        let t = Self.base
        #expect(tracker.evaluate([Self.group(cpu: 200, now: t)], now: t, settings: s).isEmpty)
        // A dip to 100% (above half the threshold) does not restart the clock…
        #expect(tracker.evaluate([Self.group(cpu: 100, now: t)], now: t.addingTimeInterval(60), settings: s).isEmpty)
        let fired = tracker.evaluate([Self.group(cpu: 180, now: t)], now: t.addingTimeInterval(120), settings: s)
        #expect(fired.map(\.kind) == [.hot])
        #expect(fired.first?.id == "proc.hot.g")
        // …and it fires once per group.
        #expect(tracker.evaluate([Self.group(cpu: 180, now: t)], now: t.addingTimeInterval(500), settings: s).isEmpty)
    }

    @Test func coolingDownRestartsTheHotClock() {
        var tracker = ProcessAlertTracker()
        let s = MonitorSettings()
        let t = Self.base
        _ = tracker.evaluate([Self.group(cpu: 200, now: t)], now: t, settings: s)
        _ = tracker.evaluate([Self.group(cpu: 10, now: t)], now: t.addingTimeInterval(60), settings: s)
        _ = tracker.evaluate([Self.group(cpu: 200, now: t)], now: t.addingTimeInterval(90), settings: s)
        #expect(tracker.evaluate([Self.group(cpu: 200, now: t)], now: t.addingTimeInterval(150), settings: s).isEmpty)
        #expect(tracker.evaluate([Self.group(cpu: 200, now: t)], now: t.addingTimeInterval(210), settings: s).count == 1)
    }

    @Test func leftoverWaitsForTheGraceAndLongRunningUsesHours() {
        var tracker = ProcessAlertTracker()
        var s = MonitorSettings()
        s.longShellHours = 1
        let t = Self.base
        let orphan = Self.group(cpu: 0, orphaned: true, now: t)
        #expect(tracker.evaluate([orphan], now: t, settings: s).isEmpty)
        #expect(tracker.evaluate([orphan], now: t.addingTimeInterval(60), settings: s).map(\.kind) == [.leftover])
        let old = Self.group(cpu: 0, age: 3600, now: t)
        #expect(tracker.evaluate([old], now: t, settings: s).map(\.kind) == [.longRunning])
        // MCP servers live as long as claude: never leftover or long-running alerts.
        var fresh = ProcessAlertTracker()
        let mcp = Self.group(cpu: 0, age: 90000, kind: .mcp, orphaned: true, now: t)
        #expect(fresh.evaluate([mcp], now: t, settings: s).isEmpty)
        #expect(fresh.evaluate([mcp], now: t.addingTimeInterval(120), settings: s).isEmpty)
    }

    @Test func alertTextSaysWhatAndWhere() {
        let t = Self.base
        let alert = ProcessAlert(kind: .hot, group: Self.group(cpu: 170, now: t))
        let c = alert.content(now: t)
        #expect(c.title == "apps: shell at 170% CPU")
        #expect(c.subtitle == "npm test")
        #expect(c.body == "Busiest: jest\npid 7 · 3 processes · 1m CPU time")
        let left = ProcessAlert(kind: .leftover, group: Self.group(cpu: 0, orphaned: true, now: t)).content(now: t)
        #expect(left.title == "apps: shell left running")
        #expect(left.body.contains("Its claude process has exited."))
        let mine = ProcessAlert(kind: .hot, group: { var g = Self.group(cpu: 300, now: t); g.kind = .terminal; return g }())
        #expect(mine.content(now: t).title == "apps: process in its terminal at 300% CPU")
    }

    @Test func multiLineCommandsAreSummarisedOnOneLine() {
        var g = Self.group(cpu: 0, now: Self.base)
        g.command = "python3 - <<'EOF'\nprint(1)\nEOF"
        #expect(g.commandSummary == "python3 - <<'EOF' …")
        g.command = "  ls -la  "
        #expect(g.commandSummary == "ls -la")
    }

    @Test func formats() {
        #expect(ProcessPolicy.format(percent: 169.6) == "170%")
        #expect(ProcessPolicy.format(percent: 4.24) == "4.2%")
        #expect(ProcessPolicy.format(percent: 0.01) == "0%")
        #expect(ProcessPolicy.format(duration: 45) == "45s")
        #expect(ProcessPolicy.format(duration: 5 * 3600 + 32 * 60) == "5h 32m")
        #expect(ProcessPolicy.format(duration: 3 * 86400 + 4 * 3600) == "3d 4h")
    }

    @Test func settingsSavedBeforeTheFieldsExistGetTheDefaults() throws {
        let old = #"{"staleAfterMinutes": 12, "deadAfterHours": 6, "hideEndedAfterHours": 24}"#
        let s = try JSONDecoder().decode(MonitorSettings.self, from: Data(old.utf8))
        #expect(s.staleAfterMinutes == 12)
        #expect(s.processAlertsEnabled && s.cpuAlertPercent == 150 && s.cpuAlertMinutes == 2 && s.longShellHours == 3)
    }

    // MARK: - Monitor + live table

    final class FixtureReader: ProcessTableReading, @unchecked Sendable {
        var samples: [[ProcSample]]
        init(_ samples: [[ProcSample]]) { self.samples = samples }
        func read(roots: Set<Int32>, ttys: Set<Int32>) -> [ProcSample] { samples.isEmpty ? [] : samples.removeFirst() }
    }

    final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    @Test func monitorPublishesVisibleGroupsAndSessionCpu() throws {
        let t = try Self.tree()
        let reader = FixtureReader([t.first, t.second])
        let clock = Box([t.firstAt, t.secondAt])
        let monitor = ProcessMonitor(reader: { reader }, now: { clock.value.removeFirst() },
                                     ttyDevice: { Self.ttys[$0] })
        let updates = Box<[ProcessMonitor.Update]>([])
        monitor.startForTesting(settings: MonitorSettings()) { updates.value.append($0) }
        monitor.syncUpdateSessions(Self.sessions())
        monitor.syncTick()
        monitor.syncTick()
        let last = try #require(updates.value.last)
        #expect(last.tabs.first?.groups.first?.pid == 110)
        #expect(abs((last.cpuBySession["sA"] ?? 0) - 220) < 0.01)
        #expect(last.alerts.isEmpty)  // nothing has been hot for 2 min yet
    }

    @Test func timerDrivenMonitorPublishesAndStops() async throws {
        let t = try Self.tree()
        let reader = FixtureReader([t.first, t.second, t.second, t.second])
        let clock = Box(t.firstAt)
        let monitor = ProcessMonitor(reader: { reader }, now: {
            defer { clock.value = clock.value.addingTimeInterval(5) }
            return clock.value
        }, ttyDevice: { Self.ttys[$0] })
        monitor.updateSessions(Self.sessions())
        let updates = Box<[ProcessMonitor.Update]>([])
        var settings = MonitorSettings()
        settings.processAlertsEnabled = false
        monitor.start(settings: settings) { updates.value.append($0) }
        monitor.updateSettings(settings)
        try await Task.sleep(for: .milliseconds(1600))  // first tick now, second after 1 s
        monitor.stop()
        let count = updates.value.count
        #expect(count >= 2)
        #expect(updates.value.last?.tabs.first?.groups.first?.pid == 110)
        try await Task.sleep(for: .milliseconds(300))
        #expect(updates.value.count == count)
    }

    @Test func liveTableSeesThisProcessWithItsArguments() {
        let table = LibprocProcessTable()
        let me = getpid()
        let samples = table.read(roots: [getppid()], ttys: [])
        let mine = samples.first { $0.pid == me }
        #expect(mine != nil)
        #expect(mine?.args?.isEmpty == false)
        #expect((mine?.cpuSeconds ?? 0) > 0)
        #expect(samples.contains { $0.pid == 1 } == false)  // launchd is root's, not ours
    }
}
