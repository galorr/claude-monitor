import Foundation
import Testing
@testable import ClaudeMonitorCore

/// Hook installer (spec Phase 4, decisions.md D-014), on fixtures/settings/*.json.
enum SettingsFixture {
    static let dir = Fixture.repoRoot.appending(path: "fixtures/settings")

    static func data(_ name: String) throws -> Data { try Data(contentsOf: dir.appending(path: name)) }
    static func json(_ name: String) throws -> JSONValue { try JSONValue.parse(data(name)) }
}

/// Our hook objects per event, and everything else with ours stripped.
func ours(_ root: JSONValue) -> [String: Int] {
    var counts: [String: Int] = [:]
    for m in root["hooks"]?.members ?? [] {
        let n = (m.value.elements ?? []).flatMap { $0["hooks"]?.elements ?? [] }.filter(HookInstaller.isOurs).count
        if n > 0 { counts[m.key] = n }
    }
    return counts
}

@Suite struct OrderedJSONTests {
    @Test(arguments: ["empty.json", "existing-hooks.json", "installed.json", "manual.json", "hooks-not-object.json"])
    func roundTripIsByteIdentical(name: String) throws {
        let original = try SettingsFixture.data(name)
        #expect(Data((try JSONValue.parse(original).render() + "\n").utf8) == original)
    }

    @Test func realWorldEscapesAndNumbers() throws {
        let text = #"{"a":"q\"b\\s\/té\n\u0001","n":[-1.5e3,0,12],"o":{},"e":[],"t":true,"f":false,"z":null}"#
        let v = try JSONValue.parse(Data(text.utf8))
        #expect(v["a"]?.stringValue == "q\"b\\s/té\n\u{01}")
        #expect(v.render() == """
        {
          "a": "q\\"b\\\\s/té\\n\\u0001",
          "n": [
            -1.5e3,
            0,
            12
          ],
          "o": {},
          "e": [],
          "t": true,
          "f": false,
          "z": null
        }
        """)
        // Agrees with Foundation on what the values are.
        let ns = try JSONSerialization.jsonObject(with: Data(v.render().utf8)) as? [String: Any]
        #expect(ns?["a"] as? String == "q\"b\\s/té\n\u{01}")
    }

    @Test(arguments: ["", "{", #"{"a":}"#, #"{"a":1,}"#, "[1 2]", #"{"a":tru}"#, "{} x", #""\x""#, "01a"])
    func malformedInputThrows(text: String) {
        #expect(throws: JSONValue.ParseError.self) { try JSONValue.parse(Data(text.utf8)) }
    }

    @Test func surrogatePairs() throws {
        #expect(try JSONValue.parse(Data(#""😀""#.utf8)).stringValue == "😀")
    }
}

@Suite struct HookMergeTests {
    let all = Dictionary(uniqueKeysWithValues: HookInstaller.events.map { ($0.name, 1) })

    @Test func emptySettingsGetEveryEventAndUninstallRestoresThem() throws {
        let merged = try HookInstaller.merge(try SettingsFixture.json("empty.json"))
        #expect(ours(merged) == all)
        #expect(HookInstaller.inspect(merged) == .current)
        #expect(try HookInstaller.unmerge(merged).render() + "\n" == String(decoding: try SettingsFixture.data("empty.json"), as: UTF8.self))
    }

    @Test func existingHooksAreKeptInPlaceAndUninstallIsByteExact() throws {
        let original = try SettingsFixture.json("existing-hooks.json")
        let merged = try HookInstaller.merge(original)
        #expect(ours(merged) == all)
        // Other hooks: same groups, same order, same content; ours appended after them.
        for m in original["hooks"]!.members! {
            let before = m.value.elements!
            let after = merged["hooks"]![m.key]!.elements!
            #expect(Array(after.prefix(before.count)) == before)
        }
        // Top-level keys keep their order; "hooks" stays where it was.
        #expect(merged.members!.map(\.key) == original.members!.map(\.key))
        let back = try HookInstaller.unmerge(merged)
        #expect(Data((back.render() + "\n").utf8) == (try SettingsFixture.data("existing-hooks.json")))
    }

    @Test func alreadyInstalledIsANoOp() throws {
        let installed = try SettingsFixture.json("installed.json")
        #expect(HookInstaller.inspect(installed) == .current)
        #expect(try HookInstaller.merge(installed) == installed)
        #expect(try HookInstaller.unmerge(installed) == (try SettingsFixture.json("existing-hooks.json")))
    }

    @Test func manualEntriesAreTakenOverInPlace() throws {
        let manual = try SettingsFixture.json("manual.json")
        #expect(HookInstaller.inspect(manual) == .manual)
        let merged = try HookInstaller.merge(manual)
        #expect(merged == (try SettingsFixture.json("installed.json")))
    }

    @Test func outdatedEntriesAreUpdatedAndDuplicatesRemoved() throws {
        var root = try SettingsFixture.json("installed.json")
        var hooks = root["hooks"]!
        // Stop: our hook with an old timeout, plus a second copy; SessionEnd: missing.
        let old: JSONValue = .object([.init("type", .string("command")),
                                      .init("command", .string(HookInstaller.command)),
                                      .init("timeout", .number("9"))])
        var stop = hooks["Stop"]!.elements!
        stop[stop.count - 1] = .object([.init("hooks", .array([old]))])
        stop.append(.object([.init("hooks", .array([old]))]))
        hooks.set("Stop", .array(stop))
        hooks.set("SessionEnd", .array([]))
        hooks.set("PreCompact", .array([.object([.init("hooks", .array([old]))])]))  // event we no longer use
        root.set("hooks", hooks)
        guard case .different(let why) = HookInstaller.inspect(root) else {
            Issue.record("expected outdated")
            return
        }
        #expect(why.contains("Stop"))
        let merged = try HookInstaller.merge(root)
        #expect(HookInstaller.inspect(merged) == .current)
        #expect(ours(merged) == all)
        #expect(merged["hooks"]?["PreCompact"] == nil)
    }

    @Test func ourHookSharingAGroupOnlyRemovesOurs() throws {
        let shared: JSONValue = .object([.init("hooks", .array([
            .object([.init("type", .string("command")), .init("command", .string("echo mine"))]),
            HookInstaller.desiredHook(async: true, timeout: 5),
        ]))])
        let root: JSONValue = .object([.init("hooks", .object([.init("Stop", .array([shared]))]))])
        let back = try HookInstaller.unmerge(root)
        #expect(back["hooks"]?["Stop"]?.elements?.first?["hooks"]?.elements?.count == 1)
        let merged = try HookInstaller.merge(root)
        #expect(merged["hooks"]?["Stop"]?.elements?.count == 1)  // reused in place, no new group
    }

    @Test(arguments: ["hooks-not-object.json"])
    func wrongShapesAreRefused(name: String) throws {
        let root = try SettingsFixture.json(name)
        #expect(throws: HookInstaller.InstallError.self) { try HookInstaller.merge(root) }
        #expect(throws: HookInstaller.InstallError.self) { try HookInstaller.unmerge(root) }
        #expect(throws: HookInstaller.InstallError.self) { try HookInstaller.merge(.array([])) }
    }

    @Test func snippetMatchesWhatTheInstallerWrites() throws {
        let snippet = try JSONValue.parse(Data(contentsOf: Fixture.repoRoot.appending(path: "hooks/settings-snippet.json")))
        let merged = try HookInstaller.merge(.object([]))
        #expect(snippet == merged)
    }

    @Test func scriptVersionIsRead() throws {
        let script = try Data(contentsOf: Fixture.repoRoot.appending(path: "hooks/claude-monitor-hook.sh"))
        #expect(HookInstaller.scriptVersion(script) != nil)
    }
}

@Suite struct HookInstallerFileTests {
    struct Env {
        let dir: URL
        let installer: HookInstaller
        var settings: URL { installer.paths.settingsFile }
    }

    func env(settings fixture: String?) throws -> Env {
        let dir = try tempDir()
        let script = dir.appending(path: "bundle/claude-monitor-hook.sh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Fixture.repoRoot.appending(path: "hooks/claude-monitor-hook.sh"), to: script)
        let paths = HookInstaller.Paths(settingsFile: dir.appending(path: "claude/settings.json"),
                                        binDir: dir.appending(path: "support/bin"),
                                        backupsDir: dir.appending(path: "support/backups"),
                                        bundledScript: script)
        if let fixture {
            try FileManager.default.createDirectory(at: paths.settingsFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try SettingsFixture.data(fixture).write(to: paths.settingsFile)
        }
        return Env(dir: dir, installer: HookInstaller(paths: paths))
    }

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func installBacksUpWritesAndUninstallRestores() throws {
        let e = try env(settings: "existing-hooks.json")
        let original = try Data(contentsOf: e.settings)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: e.settings.path)
        #expect(e.installer.status() == .missing)

        guard case .written(let backup?) = try e.installer.install(now: now) else {
            Issue.record("expected a write with a backup")
            return
        }
        #expect(try Data(contentsOf: backup) == original)
        #expect(backup.lastPathComponent.hasPrefix("settings-") && backup.pathExtension == "json")
        #expect(e.installer.status() == .installed(version: 1))
        let attrs = try FileManager.default.attributesOfItem(atPath: e.settings.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let scriptAttrs = try FileManager.default.attributesOfItem(atPath: e.installer.paths.installedScript.path)
        #expect((scriptAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o755)

        #expect(try e.installer.install(now: now) == .unchanged)

        try e.installer.uninstall(now: now.addingTimeInterval(1))
        #expect(try Data(contentsOf: e.settings) == original)
        #expect(e.installer.status() == .missing)
        #expect(!FileManager.default.fileExists(atPath: e.installer.paths.installedScript.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: e.installer.paths.backupsDir.path).count == 2)
    }

    @Test func missingSettingsFileIsCreatedAndRemovedCleanly() throws {
        let e = try env(settings: nil)
        #expect(e.installer.status() == .missing)
        #expect(try e.installer.install(now: now) == .written(backup: nil))
        #expect(e.installer.status() == .installed(version: 1))
        try e.installer.uninstall(now: now)
        #expect(String(decoding: try Data(contentsOf: e.settings), as: UTF8.self) == "{}\n")
    }

    @Test func malformedSettingsAreNeverTouched() throws {
        let e = try env(settings: "malformed.json")
        let original = try Data(contentsOf: e.settings)
        guard case .error = e.installer.status() else {
            Issue.record("expected an error status")
            return
        }
        #expect(throws: HookInstaller.InstallError.self) { try e.installer.install(now: now) }
        #expect(throws: HookInstaller.InstallError.self) { try e.installer.uninstall(now: now) }
        #expect(try Data(contentsOf: e.settings) == original)
        #expect(!FileManager.default.fileExists(atPath: e.installer.paths.backupsDir.path))
    }

    @Test func failedValidationRestoresTheBackup() throws {
        var e = try env(settings: "existing-hooks.json")
        let original = try Data(contentsOf: e.settings)
        var installer = e.installer
        installer.afterWrite = { url in try Data("{ broken".utf8).write(to: url) }
        e = Env(dir: e.dir, installer: installer)
        #expect(throws: HookInstaller.InstallError.self) { try e.installer.install(now: now) }
        #expect(try Data(contentsOf: e.settings) == original)
    }

    @Test func symlinkedSettingsStayALink() throws {
        let e = try env(settings: nil)
        let real = e.dir.appending(path: "dotfiles/settings.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SettingsFixture.data("existing-hooks.json").write(to: real)
        try FileManager.default.createDirectory(at: e.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: e.settings, withDestinationURL: real)

        try e.installer.install(now: now)
        let type = try FileManager.default.attributesOfItem(atPath: e.settings.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
        #expect(HookInstaller.inspect(try JSONValue.parse(Data(contentsOf: real))) == .current)
    }

    @Test func manualInstallIsReportedThenTakenOver() throws {
        let e = try env(settings: "manual.json")
        #expect(e.installer.status() == .manual)
        try e.installer.install(now: now)
        #expect(try Data(contentsOf: e.settings) == (try SettingsFixture.data("installed.json")))
        #expect(e.installer.status() == .installed(version: 1))
    }

    @Test func changedScriptMakesItOutdated() throws {
        let e = try env(settings: "existing-hooks.json")
        try e.installer.install(now: now)
        try Data("#!/bin/bash\nHOOK_VERSION=0\n".utf8).write(to: e.installer.paths.installedScript)
        #expect(e.installer.status() == .outdated("newer script in the app"))
        try e.installer.install(now: now)
        #expect(e.installer.status() == .installed(version: 1))
    }

    @Test func noBundledScriptRefusesToInstall() throws {
        let e = try env(settings: "existing-hooks.json")
        var paths = e.installer.paths
        paths.bundledScript = nil
        #expect(throws: HookInstaller.InstallError.noBundledScript) { try HookInstaller(paths: paths).install(now: now) }
    }
}
