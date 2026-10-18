import Foundation

/// One line of events.jsonl, as written by hooks/claude-monitor-hook.sh.
/// Only the fields the app uses are decoded; everything optional except the three
/// keys every line has. A field with an unexpected type decodes as nil instead of
/// failing the whole line.
public struct HookEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case notification = "Notification"
        case permissionRequest = "PermissionRequest"
        case postToolUse = "PostToolUse"
        case stop = "Stop"
        case stopFailure = "StopFailure"
        case sessionEnd = "SessionEnd"
        case other
    }

    public var sessionId: String
    public var hookEventName: String
    public var ts: Date
    public var eventId: String?
    public var cwd: String?
    public var gitRoot: String?
    public var gitBranch: String?
    public var tty: String?
    public var claudePid: Int?
    public var claudePath: String?
    public var procChain: [String]?
    public var envNames: [String]?
    public var notificationType: String?
    public var message: String?
    public var prompt: String?
    public var lastAssistantMessage: String?
    public var toolName: String?
    /// SessionStart: startup / resume / clear / compact.
    public var source: String?
    /// SessionEnd: prompt_input_exit / other / …
    public var reason: String?
    public var permissionMode: String?
    public var error: String?

    public var kind: Kind { Kind(rawValue: hookEventName) ?? .other }

    public enum DecodeError: Error, Equatable {
        case notJSONObject
        case missingField(String)
        case badTimestamp(String)
    }

    /// Decodes one JSON line (without the trailing newline).
    public static func decode(_ line: Data) throws -> HookEvent {
        guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw DecodeError.notJSONObject
        }
        func str(_ key: String) -> String? {
            guard let s = obj[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        func strings(_ key: String) -> [String]? { obj[key] as? [String] }

        guard let sessionId = str("session_id") else { throw DecodeError.missingField("session_id") }
        guard let name = str("hook_event_name") else { throw DecodeError.missingField("hook_event_name") }
        guard let tsString = str("ts") else { throw DecodeError.missingField("ts") }
        guard let ts = Self.parseTimestamp(tsString) else { throw DecodeError.badTimestamp(tsString) }

        return HookEvent(
            sessionId: sessionId,
            hookEventName: name,
            ts: ts,
            eventId: str("event_id"),
            cwd: str("cwd"),
            gitRoot: str("git_root"),
            gitBranch: str("git_branch"),
            tty: str("tty"),
            claudePid: (obj["claude_pid"] as? NSNumber)?.intValue,
            claudePath: str("claude_path"),
            procChain: strings("proc_chain"),
            envNames: strings("env_names"),
            notificationType: str("notification_type"),
            message: str("message"),
            prompt: str("prompt"),
            lastAssistantMessage: str("last_assistant_message"),
            toolName: str("tool_name"),
            source: str("source"),
            reason: str("reason"),
            permissionMode: str("permission_mode"),
            error: str("error")
        )
    }

    static func parseTimestamp(_ s: String) -> Date? {
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        return try? Date.ISO8601FormatStyle().parse(s)
    }
}
