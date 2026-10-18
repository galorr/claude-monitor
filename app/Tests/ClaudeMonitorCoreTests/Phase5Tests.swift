import Foundation
import Testing
@testable import ClaudeMonitorCore

/// Jump to a session, epic grouping, hotkey (spec Phase 5, decisions.md D-015).
@Suite struct JumpTests {
    // Process chains as recorded by the hook (anonymised).
    static let terminalChain = ["claude", "-zsh", "login", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"]
    static let vscodeChain = ["claude", "/bin/zsh",
        "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper",
        "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"]
    static let desktopChain = ["/Users/user/Library/Application Support/Claude/claude-code/2.1.0/x/claude.app/Contents/MacOS/claude",
        "/Applications/Claude.app/Contents/Helpers/disclaimer", "/Applications/Claude.app/Contents/MacOS/Claude"]
    static let itermChain = ["claude", "-zsh", "login", "/Applications/iTerm.app/Contents/MacOS/iTerm2"]

    func session(_ extra: [String: Any], _ name: String = "UserPromptSubmit") -> Session {
        store([event(name, at: 0, extra)]).sessions["s1"]!
    }

    @Test func hostAppIsTheOutermostApp() {
        #expect(SessionStore.hostApp(Self.terminalChain) == "/System/Applications/Utilities/Terminal.app")
        #expect(SessionStore.hostApp(Self.vscodeChain) == "/Applications/Visual Studio Code.app")
        #expect(SessionStore.hostApp(Self.desktopChain) == "/Applications/Claude.app")
        #expect(SessionStore.hostApp(["claude", "script"]) == nil)
    }

    @Test func terminalSessionFocusesItsTab() {
        let s = session(["tty": "ttys005", "proc_chain": Self.terminalChain])
        #expect(JumpPlan.plan(for: s) == .focusTab(tty: "/dev/ttys005", apps: [.terminal]))
    }

    @Test func itermSessionFocusesItsTab() {
        let s = session(["tty": "ttys003", "proc_chain": Self.itermChain])
        #expect(JumpPlan.plan(for: s) == .focusTab(tty: "/dev/ttys003", apps: [.iterm]))
    }

    @Test func otherHostIsOnlyActivated() {
        let s = session(["tty": "ttys012", "proc_chain": Self.vscodeChain])
        #expect(JumpPlan.plan(for: s) == .activate(appPath: "/Applications/Visual Studio Code.app"))
    }

    @Test func desktopSessionActivatesClaude() {
        let s = session(["proc_chain": Self.desktopChain])
        #expect(s.source == .desktop)
        #expect(JumpPlan.plan(for: s) == .activate(appPath: "/Applications/Claude.app"))
    }

    @Test func ttyWithoutHostSearchesKnownTerminals() {
        let s = session(["tty": "ttys001", "proc_chain": ["claude", "script"]])
        #expect(JumpPlan.plan(for: s) == .focusTab(tty: "/dev/ttys001", apps: [.terminal, .iterm]))
    }

    @Test func endedOrUnknownSessionsCannotJump() {
        let closed = store([event("SessionStart", at: 0, ["tty": "ttys001"]), event("SessionEnd", at: 1)]).sessions["s1"]!
        guard case .unavailable = JumpPlan.plan(for: closed) else { Issue.record("closed"); return }
        guard case .unavailable = JumpPlan.plan(for: session([:])) else { Issue.record("no tty"); return }
    }

    @Test(arguments: [
        ("ttys005", "/dev/ttys005"), ("/dev/ttys012", "/dev/ttys012"),
        ("ttys0\" & do shell script \"x", nil), ("../etc", nil), ("tty", "/dev/tty"), ("console", nil),
    ] as [(String, String?)])
    func ttyIsValidatedBeforeItReachesAppleScript(raw: String, expected: String?) {
        #expect(JumpPlan.devicePath(raw) == expected)
    }

    @Test func scriptsTargetTheTty() {
        for app in TerminalApp.allCases {
            let script = app.script(tty: "/dev/ttys005")
            #expect(script.contains("\"/dev/ttys005\""))
            #expect(script.contains(app.bundleId))
        }
    }

    @Test func hostIsKeptWhenLaterEventsHaveNoChain() {
        let s = store([
            event("SessionStart", at: 0, ["tty": "ttys005", "proc_chain": Self.terminalChain]),
            event("Stop", at: 1),
        ]).sessions["s1"]!
        #expect(s.hostApp == "/System/Applications/Utilities/Terminal.app")
    }
}

@Suite struct EpicGroupingTests {
    @Test func epicsSitWhereTheirMostUrgentSessionIs() {
        let s = store([
            event("UserPromptSubmit", session: "loose-working", at: 0),
            event("UserPromptSubmit", session: "a-working", at: 1, ["git_branch": "epic/PROJ-1/T2"]),
            event("PermissionRequest", session: "b-perm", at: 2, ["git_branch": "epic/PROJ-1/T1"]),
            event("Stop", session: "loose-done", at: 3),
            event("Stop", session: "c-done", at: 4, ["git_branch": "epic/PROJ-2/T1"]),
        ])
        let items = ListItem.items(s.sorted)
        #expect(items.map(\.id) == ["epic:PROJ-1", "epic:PROJ-2", "loose-done", "loose-working"])
        guard case .epic(let first) = items[0] else { Issue.record("expected an epic"); return }
        #expect(first.sessions.map(\.id) == ["b-perm", "a-working"])
        #expect(first.sessions.map(\.taskId) == ["T1", "T2"])
        #expect(first.attentionCount == 1)
    }

    @Test func noEpicsMeansAFlatList() {
        let s = store([event("Stop", session: "a", at: 0), event("Stop", session: "b", at: 1)])
        #expect(ListItem.items(s.sorted).map(\.id) == ["b", "a"])
    }
}

@Suite struct HotkeyTests {
    @Test func displayFollowsAppleOrder() {
        #expect(Hotkey.default.display == "⌃⌥M")
        let all = Hotkey(keyCode: 1, modifiers: Hotkey.command | Hotkey.shift | Hotkey.option | Hotkey.control, key: "S")
        #expect(all.display == "⌃⌥⇧⌘S")
    }

    @Test func needsARealModifier() {
        #expect(Hotkey.default.isValid)
        #expect(!Hotkey(keyCode: 1, modifiers: Hotkey.shift, key: "S").isValid)
        #expect(!Hotkey(keyCode: 1, modifiers: 0, key: "S").isValid)
    }

    @Test func settingsRoundTripAndOldSettingsGetTheDefault() throws {
        var s = MonitorSettings()
        s.hotkey = Hotkey(keyCode: 49, modifiers: Hotkey.option, key: "Space")
        s.hotkeyEnabled = false
        #expect(try JSONDecoder().decode(MonitorSettings.self, from: JSONEncoder().encode(s)) == s)
        let old = try JSONDecoder().decode(MonitorSettings.self, from: Data(#"{"staleAfterMinutes":5}"#.utf8))
        #expect(old.hotkey == .default)
        #expect(old.hotkeyEnabled)
    }
}
