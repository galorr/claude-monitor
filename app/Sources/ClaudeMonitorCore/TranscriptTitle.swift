import Foundation

/// The session's name, as Claude Code keeps it in the transcript (D-019): `custom-title`
/// lines from `/rename`, `ai-title` lines from its auto titling. Both are re-appended
/// during the session, so the end of the file holds the current one.
public enum TranscriptTitle {
    /// How much of the file's end is read. Lines can be large (API request blobs).
    static let tailBytes = 512 * 1024

    /// The newest `custom-title`, else the newest `ai-title`, in the file's tail.
    /// nil when the file is unreadable or the tail has neither.
    public static func read(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: 0x0A)
        if start > 0, !lines.isEmpty { lines.removeFirst() } // cut mid-line
        return parse(lines.map { Data($0) })
    }

    /// Where Claude Code puts the transcript when the hook did not say (sessions saved
    /// before D-019): `~/.claude/projects/<cwd, every non-alphanumeric → "-">/<id>.jsonl`.
    public static func defaultPath(sessionId: String, cwd: String,
                                   home: String = NSHomeDirectory()) -> String {
        let folder = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return "\(home)/.claude/projects/\(folder)/\(sessionId).jsonl"
    }

    static func parse(_ lines: [Data]) -> String? {
        var aiTitle: String?
        for line in lines.reversed() {
            // Cheap filter before decoding: most lines are neither.
            guard line.range(of: Data("-title\"".utf8)) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            switch obj["type"] as? String {
            case "custom-title":
                if let t = clean(obj["customTitle"]) { return t }
            case "ai-title":
                if aiTitle == nil { aiTitle = clean(obj["aiTitle"]) }
            default:
                break
            }
        }
        return aiTitle
    }

    private static func clean(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
