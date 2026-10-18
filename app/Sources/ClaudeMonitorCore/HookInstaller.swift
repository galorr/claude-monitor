import Foundation

/// Installs the hook script and merges our entries into ~/.claude/settings.json
/// (spec Phase 4, decisions.md D-014). The merge never touches other hooks: it only
/// adds, updates or removes hook objects whose command runs claude-monitor-hook.sh.
public struct HookInstaller: Sendable {
    public struct Paths: Sendable {
        public var settingsFile: URL
        public var binDir: URL
        public var backupsDir: URL
        /// The script shipped in the .app (nil when run unbundled).
        public var bundledScript: URL?

        public init(settingsFile: URL, binDir: URL, backupsDir: URL, bundledScript: URL?) {
            self.settingsFile = settingsFile
            self.binDir = binDir
            self.backupsDir = backupsDir
            self.bundledScript = bundledScript
        }

        public static func standard(bundledScript: URL?) -> Paths {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let support = home.appending(path: "Library/Application Support/ClaudeMonitor", directoryHint: .isDirectory)
            return Paths(settingsFile: home.appending(path: ".claude/settings.json"),
                         binDir: support.appending(path: "bin", directoryHint: .isDirectory),
                         backupsDir: support.appending(path: "backups", directoryHint: .isDirectory),
                         bundledScript: bundledScript)
        }

        public var installedScript: URL { binDir.appending(path: HookInstaller.scriptName) }
    }

    public enum Status: Equatable, Sendable {
        case installed(version: Int?)
        /// Our entries or the script differ from this app version; Install updates them.
        case outdated(String)
        /// Entries added by hand (they run the repo copy of the script); Install takes them over.
        case manual
        case missing
        case error(String)

        public var label: String {
            switch self {
            case .installed(let v): "Hooks: installed" + (v.map { " (v\($0))" } ?? "")
            case .outdated(let why): "Hooks: outdated (\(why))"
            case .manual: "Hooks: added by hand, not managed"
            case .missing: "Hooks: not installed"
            case .error(let e): "Hooks: \(e)"
            }
        }

        public var isHealthy: Bool {
            if case .installed = self { return true }
            return false
        }
    }

    public enum InstallError: Error, Equatable, CustomStringConvertible {
        case noBundledScript
        case malformedSettings(String)
        case changedWhileWriting
        case validationFailed(String)

        public var description: String {
            switch self {
            case .noBundledScript: "the hook script is not in the app bundle (run the built .app)"
            case .malformedSettings(let why): "settings.json is not valid: \(why). Nothing was changed."
            case .changedWhileWriting: "settings.json changed while installing. Nothing was changed; try again."
            case .validationFailed(let why): "the written settings.json failed validation (\(why)); the backup was restored."
            }
        }
    }

    public enum Outcome: Equatable, Sendable {
        case unchanged
        /// `backup` is nil when there was no settings file before.
        case written(backup: URL?)
    }

    public static let scriptName = "claude-monitor-hook.sh"
    public static let marker = "# managed by Claude Monitor"
    public static let command =
        "bash \"$HOME/Library/Application Support/ClaudeMonitor/bin/\(scriptName)\" \(marker)"

    /// Every hook event we listen to (decisions.md D-003). SessionEnd is synchronous with
    /// a short timeout: Claude exits right after it, and an async hook could be dropped.
    public static let events: [(name: String, async: Bool, timeout: Int)] = [
        ("SessionStart", true, 5),
        ("UserPromptSubmit", true, 5),
        ("Notification", true, 5),
        ("PermissionRequest", true, 5),
        ("PostToolUse", true, 5),
        ("Stop", true, 5),
        ("StopFailure", true, 5),
        ("SessionEnd", false, 2),
    ]

    public let paths: Paths
    /// Test seam: runs right after the new settings.json is written, before validation.
    var afterWrite: (@Sendable (URL) throws -> Void)?

    public init(paths: Paths) {
        self.paths = paths
    }

    // MARK: - Status

    public func status() -> Status {
        let root: JSONValue
        do {
            root = try readSettings() ?? .object([])
        } catch {
            return .error("settings.json is not valid JSON")
        }
        switch Self.inspect(root) {
        case .none: return .missing
        case .manual: return .manual
        case .different(let why): return .outdated(why)
        case .current: break
        }
        guard let installed = try? Data(contentsOf: paths.installedScript) else { return .outdated("script missing") }
        if let bundled = paths.bundledScript.flatMap({ try? Data(contentsOf: $0) }), bundled != installed {
            return .outdated("newer script in the app")
        }
        return .installed(version: Self.scriptVersion(installed))
    }

    // MARK: - Install / uninstall

    @discardableResult
    public func install(now: Date = Date()) throws -> Outcome {
        guard let source = paths.bundledScript, let script = try? Data(contentsOf: source) else {
            throw InstallError.noBundledScript
        }
        try installScript(script)
        return try rewriteSettings(now: now, transform: Self.merge) { root in
            guard Self.inspect(root) == .current else { throw InstallError.validationFailed("our entries are not all present") }
        }
    }

    @discardableResult
    public func uninstall(now: Date = Date()) throws -> Outcome {
        let outcome = try rewriteSettings(now: now, transform: Self.unmerge) { root in
            guard Self.inspect(root) == .none else { throw InstallError.validationFailed("our entries are still there") }
        }
        try? FileManager.default.removeItem(at: paths.installedScript)
        return outcome
    }

    // MARK: - Pure merge logic

    enum Inspection: Equatable {
        case none, current, manual
        case different(String)
    }

    static func isOurs(_ hook: JSONValue) -> Bool {
        hook["command"]?.stringValue?.contains(scriptName) == true
    }

    static func desiredHook(async: Bool, timeout: Int) -> JSONValue {
        var members: [JSONValue.Member] = [.init("type", .string("command")), .init("command", .string(command))]
        if async { members.append(.init("async", .bool(true))) }
        members.append(.init("timeout", .number(String(timeout))))
        return .object(members)
    }

    static func inspect(_ root: JSONValue) -> Inspection {
        guard let hooks = root["hooks"]?.members else { return .none }
        var found = 0
        var manual = false
        var problems: [String] = []
        for member in hooks {
            let ours = (member.value.elements ?? []).flatMap { ($0["hooks"]?.elements ?? []).filter(isOurs) }
            found += ours.count
            if ours.contains(where: { $0["command"]?.stringValue?.contains(marker) != true }) { manual = true }
            guard let spec = events.first(where: { $0.name == member.key }) else {
                if !ours.isEmpty { problems.append("extra event \(member.key)") }
                continue
            }
            if ours.count > 1 { problems.append("\(member.key) installed twice") }
            if let hook = ours.first, hook != desiredHook(async: spec.async, timeout: spec.timeout) {
                problems.append("\(member.key) differs")
            }
        }
        if found == 0 { return .none }
        if manual { return .manual }
        let missing = events.filter { spec in
            !(hooks.first { $0.key == spec.name }?.value.elements ?? [])
                .contains { ($0["hooks"]?.elements ?? []).contains(where: isOurs) }
        }
        if !missing.isEmpty { problems.append("missing \(missing.map(\.name).joined(separator: ", "))") }
        return problems.isEmpty ? .current : .different(problems.joined(separator: "; "))
    }

    /// Adds or updates our entry for every event. An existing entry of ours (managed or
    /// added by hand) is replaced where it is; a new one is appended as its own group.
    static func merge(_ root: JSONValue) throws -> JSONValue {
        var root = root
        guard root.members != nil else { throw InstallError.malformedSettings("the top level is not an object") }
        var hooks = root["hooks"] ?? .object([])
        guard let existing = hooks.members else { throw InstallError.malformedSettings("\"hooks\" is not an object") }
        // Events an older version listened to but this one doesn't.
        for member in existing where !events.contains(where: { $0.name == member.key }) {
            guard let cleaned = try removingOurs(from: member.value, event: member.key) else { continue }
            if cleaned.elements?.isEmpty == true { hooks.remove(member.key) } else { hooks.set(member.key, cleaned) }
        }
        for spec in events {
            let desired = desiredHook(async: spec.async, timeout: spec.timeout)
            let current = hooks[spec.name] ?? .array([])
            guard var groups = current.elements else {
                throw InstallError.malformedSettings("\"hooks.\(spec.name)\" is not an array")
            }
            var placed = false
            var g = 0
            while g < groups.count {
                guard var inner = groups[g]["hooks"]?.elements, inner.contains(where: isOurs) else { g += 1; continue }
                var replaced: [JSONValue] = []
                for hook in inner {
                    if isOurs(hook) {
                        if !placed { replaced.append(desired); placed = true }
                    } else {
                        replaced.append(hook)
                    }
                }
                inner = replaced
                if inner.isEmpty {
                    groups.remove(at: g)  // only held duplicates of ours
                } else {
                    groups[g].set("hooks", .array(inner))
                    g += 1
                }
            }
            if !placed { groups.append(.object([.init("hooks", .array([desired]))])) }
            hooks.set(spec.name, .array(groups))
        }
        root.set("hooks", hooks)
        return root
    }

    /// Removes every entry of ours, and any group, event list or "hooks" object that
    /// became empty because of it. Everything else stays as it was.
    static func unmerge(_ root: JSONValue) throws -> JSONValue {
        var root = root
        guard root.members != nil else { throw InstallError.malformedSettings("the top level is not an object") }
        guard let hooksValue = root["hooks"] else { return root }
        guard let members = hooksValue.members else { throw InstallError.malformedSettings("\"hooks\" is not an object") }
        var hooks = hooksValue
        var removedAny = false
        for member in members {
            guard let cleaned = try removingOurs(from: member.value, event: member.key) else { continue }
            removedAny = true
            if cleaned.elements?.isEmpty == true { hooks.remove(member.key) } else { hooks.set(member.key, cleaned) }
        }
        guard removedAny else { return root }
        if hooks.members?.isEmpty == true { root.remove("hooks") } else { root.set("hooks", hooks) }
        return root
    }

    /// nil when the event list holds nothing of ours (left exactly as it was).
    private static func removingOurs(from list: JSONValue, event: String) throws -> JSONValue? {
        guard let groups = list.elements else { throw InstallError.malformedSettings("\"hooks.\(event)\" is not an array") }
        guard groups.contains(where: { ($0["hooks"]?.elements ?? []).contains(where: isOurs) }) else { return nil }
        var kept: [JSONValue] = []
        for var group in groups {
            guard let inner = group["hooks"]?.elements, inner.contains(where: isOurs) else {
                kept.append(group)
                continue
            }
            let rest = inner.filter { !isOurs($0) }
            if rest.isEmpty { continue }
            group.set("hooks", .array(rest))
            kept.append(group)
        }
        return .array(kept)
    }

    static func scriptVersion(_ script: Data) -> Int? {
        let text = String(decoding: script, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("HOOK_VERSION=") }) else { return nil }
        return Int(line.dropFirst("HOOK_VERSION=".count))
    }

    // MARK: - Files

    /// Follows a symlinked settings.json (dotfiles repos), so the link stays a link.
    private var settingsTarget: URL { paths.settingsFile.resolvingSymlinksInPath() }

    private func readSettings() throws -> JSONValue? {
        guard let data = try? Data(contentsOf: settingsTarget) else { return nil }
        return try JSONValue.parse(data)
    }

    private func installScript(_ script: Data) throws {
        let fm = FileManager.default
        let dest = paths.installedScript
        if (try? Data(contentsOf: dest)) == script { return }
        try fm.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        let tmp = paths.binDir.appending(path: ".\(Self.scriptName).tmp")
        try script.write(to: tmp)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        // rename(2) is atomic: a hook starting right now sees the old or the new script.
        guard rename(tmp.path, dest.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func rewriteSettings(now: Date, transform: (JSONValue) throws -> JSONValue,
                                 validate: (JSONValue) throws -> Void) throws -> Outcome {
        let fm = FileManager.default
        let target = settingsTarget
        let original = try? Data(contentsOf: target)
        let root: JSONValue
        do {
            root = try original.map(JSONValue.parse) ?? .object([])
        } catch {
            throw InstallError.malformedSettings("\(error)")
        }
        let output = Data((try transform(root).render() + "\n").utf8)
        if output == original { return .unchanged }

        let backup = try original.map { try writeBackup($0, now: now) }
        // Claude Code may have saved the file meanwhile: never overwrite a newer version.
        guard (try? Data(contentsOf: target)) == original else { throw InstallError.changedWhileWriting }

        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let permissions = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber
        let tmp = target.deletingLastPathComponent().appending(path: ".settings.json.claude-monitor.tmp")
        try output.write(to: tmp)
        if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: tmp.path) }
        guard rename(tmp.path, target.path) == 0 else {
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            try afterWrite?(target)
            let written = try Data(contentsOf: target)
            guard (try? JSONSerialization.jsonObject(with: written)) is [String: Any] else {
                throw InstallError.validationFailed("not a JSON object")
            }
            try validate(try JSONValue.parse(written))
        } catch {
            restore(original, to: target)
            if let e = error as? InstallError, case .validationFailed = e { throw e }
            throw InstallError.validationFailed("\(error)")
        }
        return .written(backup: backup)
    }

    private func restore(_ original: Data?, to target: URL) {
        if let original {
            try? original.write(to: target, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: target)
        }
    }

    private func writeBackup(_ data: Data, now: Date) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.backupsDir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        var url = paths.backupsDir.appending(path: "settings-\(stamp).json")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = paths.backupsDir.appending(path: "settings-\(stamp)-\(n).json")
            n += 1
        }
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }
}
