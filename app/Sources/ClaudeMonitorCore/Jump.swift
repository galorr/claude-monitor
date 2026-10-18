import Foundation

/// Terminal apps whose tabs can be found by tty over AppleScript.
public enum TerminalApp: String, CaseIterable, Sendable {
    case terminal = "com.apple.Terminal"
    case iterm = "com.googlecode.iterm2"

    public var bundleId: String { rawValue }

    public var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm2"
        }
    }

    static func forHost(_ path: String) -> TerminalApp? {
        switch URL(fileURLWithPath: path).lastPathComponent {
        case "Terminal.app": .terminal
        case "iTerm.app", "iTerm2.app": .iterm
        default: nil
        }
    }

    /// Selects the tab (and window) whose tty matches, then activates the app.
    /// Returns "found" or "missing". `tty` must come from `JumpPlan` (validated).
    public func script(tty: String) -> String {
        switch self {
        case .terminal:
            """
            tell application id "\(bundleId)"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set miniaturized of w to false
                    set selected tab of w to t
                    set index of w to 1
                    activate
                    return "found"
                  end if
                end repeat
              end repeat
            end tell
            return "missing"
            """
        case .iterm:
            """
            tell application id "\(bundleId)"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      tell t to select
                      tell s to select
                      activate
                      return "found"
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return "missing"
            """
        }
    }
}

/// What clicking a session does (spec Phase 5). Pure: the app executes it.
public enum JumpPlan: Equatable, Sendable {
    /// Find the tab with this tty in the first of these apps that is running.
    case focusTab(tty: String, apps: [TerminalApp])
    /// Bring an app forward (desktop sessions, or a host like VS Code whose tabs can't be targeted).
    case activate(appPath: String)
    case unavailable(String)

    public static let desktopApp = "/Applications/Claude.app"

    public static func plan(for session: Session) -> JumpPlan {
        if session.state.isEnded { return .unavailable("This session has ended.") }
        if session.source == .desktop { return .activate(appPath: session.hostApp ?? desktopApp) }
        let tty = session.tty.flatMap(devicePath)
        if let host = session.hostApp {
            if let tty, let app = TerminalApp.forHost(host) { return .focusTab(tty: tty, apps: [app]) }
            return .activate(appPath: host)
        }
        if let tty { return .focusTab(tty: tty, apps: TerminalApp.allCases) }
        return .unavailable("No terminal was recorded for this session.")
    }

    /// "ttys005" or "/dev/ttys005" → "/dev/ttys005". Anything else is rejected: the value
    /// ends up inside an AppleScript string.
    static func devicePath(_ tty: String) -> String? {
        let name = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        guard name.hasPrefix("tty"), name.count <= 12,
              name.dropFirst(3).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "/dev/" + name
    }
}

/// A global shortcut. `modifiers` uses Carbon's flags (cmdKey, optionKey, …), which is
/// what RegisterEventHotKey takes; `key` is how the key was labelled when recorded.
public struct Hotkey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var key: String

    public static let command: UInt32 = 0x100
    public static let shift: UInt32 = 0x200
    public static let option: UInt32 = 0x800
    public static let control: UInt32 = 0x1000

    /// ⌃⌥M
    public static let `default` = Hotkey(keyCode: 0x2E, modifiers: control | option, key: "M")

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// A global shortcut needs ⌘, ⌃ or ⌥; shift alone would steal normal typing.
    public var isValid: Bool { modifiers & (Self.command | Self.control | Self.option) != 0 }

    /// Apple's order: ⌃⌥⇧⌘.
    public var display: String {
        var s = ""
        if modifiers & Self.control != 0 { s += "⌃" }
        if modifiers & Self.option != 0 { s += "⌥" }
        if modifiers & Self.shift != 0 { s += "⇧" }
        if modifiers & Self.command != 0 { s += "⌘" }
        return s + key
    }
}

/// The menu list: sessions of the same epic are grouped (spec Phase 5).
public enum ListItem: Equatable, Sendable, Identifiable {
    case session(Session)
    case epic(EpicGroup)

    public var id: String {
        switch self {
        case .session(let s): s.id
        case .epic(let g): "epic:" + g.epicKey
        }
    }

    /// Input sorted by urgency; each epic appears where its most urgent session would be,
    /// with its sessions in the same order. Sessions without an epic stay loose.
    public static func items(_ sorted: [Session]) -> [ListItem] {
        let byEpic = Dictionary(grouping: sorted.filter { $0.epicKey != nil }, by: { $0.epicKey! })
        var placed = Set<String>()
        var items: [ListItem] = []
        for s in sorted {
            guard let key = s.epicKey else {
                items.append(.session(s))
                continue
            }
            if placed.insert(key).inserted { items.append(.epic(EpicGroup(epicKey: key, sessions: byEpic[key]!))) }
        }
        return items
    }
}

public struct EpicGroup: Equatable, Sendable {
    public var epicKey: String
    public var sessions: [Session]

    public var attentionCount: Int { sessions.filter(\.state.needsAttention).count }
}
