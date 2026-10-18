import Foundation
@testable import ClaudeMonitorCore

enum Fixture {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static let captureURL = repoRoot.appending(path: "fixtures/capture-2026-10-18.jsonl")

    static func lines(_ url: URL = captureURL) throws -> [Data] {
        try Data(contentsOf: url).split(separator: 0x0A).map { Data($0) }
    }

    static func events() throws -> [HookEvent] {
        try lines().map(HookEvent.decode)
    }

    /// Full session ids from the capture (by 8-char prefix).
    static func sessionId(_ prefix: String) throws -> String {
        let ids = Set(try events().map(\.sessionId))
        guard let id = ids.first(where: { $0.hasPrefix(prefix) }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return id
    }
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Builds a synthetic event through the real decoder.
func event(_ name: String, session: String = "s1", at seconds: Double,
           _ extra: [String: Any] = [:]) -> HookEvent {
    var obj: [String: Any] = [
        "session_id": session,
        "hook_event_name": name,
        "ts": Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(t0.addingTimeInterval(seconds)),
    ]
    obj.merge(extra) { _, new in new }
    let data = try! JSONSerialization.data(withJSONObject: obj)
    return try! HookEvent.decode(data)
}

func store(_ events: [HookEvent]) -> SessionStore {
    var s = SessionStore()
    for e in events { s.apply(e) }
    return s
}

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "cm-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
