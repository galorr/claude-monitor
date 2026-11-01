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
    /// PostToolUse: the parts of tool_input / tool_response the app tracks.
    public var tool: ToolCall?
    /// Stop: what Claude Code still has running for this session (nil when the line was truncated).
    public var backgroundTasks: [BackgroundTaskSnapshot]?

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
        func dict(_ key: String) -> [String: Any]? { obj[key] as? [String: Any] }

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
            error: str("error"),
            tool: ToolCall.decode(input: dict("tool_input"), response: dict("tool_response")),
            backgroundTasks: (obj["background_tasks"] as? [Any]).map {
                $0.compactMap { BackgroundTaskSnapshot.decode($0 as? [String: Any]) }
            }
        )
    }

    static func parseTimestamp(_ s: String) -> Date? {
        if let d = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s) { return d }
        return try? Date.ISO8601FormatStyle().parse(s)
    }
}

/// The fields of a PostToolUse payload that reveal background work and published
/// artifacts. Only Bash (run_in_background), Agent (async) and Artifact matter.
public struct ToolCall: Equatable, Sendable {
    /// Bash: tool_input.run_in_background.
    public var runInBackground = false
    /// Bash: tool_input.command (truncated by the hook).
    public var command: String?
    /// Bash / Agent: tool_input.description.
    public var description: String?
    /// Agent: tool_input.subagent_type.
    public var subagentType: String?
    /// Artifact: tool_input.action (nil = publish).
    public var action: String?
    /// Bash: tool_response.backgroundTaskId.
    public var backgroundTaskId: String?
    /// Agent: tool_response.agentId, and whether it was launched in the background.
    public var agentId: String?
    public var isAsync = false
    /// Artifact: tool_response.url / title / icon.
    public var url: String?
    public var title: String?
    public var icon: String?

    public init() {}

    static func decode(input: [String: Any]?, response: [String: Any]?) -> ToolCall? {
        guard input != nil || response != nil else { return nil }
        func str(_ d: [String: Any]?, _ key: String) -> String? {
            guard let s = d?[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        func bool(_ d: [String: Any]?, _ key: String) -> Bool {
            (d?[key] as? Bool) ?? ((d?[key] as? NSNumber)?.boolValue ?? false)
        }
        var t = ToolCall()
        t.runInBackground = bool(input, "run_in_background")
        t.command = str(input, "command")
        t.description = str(input, "description")
        t.subagentType = str(input, "subagent_type")
        t.action = str(input, "action")
        t.backgroundTaskId = str(response, "backgroundTaskId")
        t.agentId = str(response, "agentId")
        t.isAsync = bool(response, "isAsync") || str(response, "status") == "async_launched"
        t.url = str(response, "url")
        t.title = str(response, "title")
        t.icon = str(response, "icon") ?? str(input, "icon")
        return t
    }
}

/// One entry of Stop's `background_tasks`.
public struct BackgroundTaskSnapshot: Equatable, Sendable {
    public var id: String
    /// "shell" or "subagent" (anything else is kept as is).
    public var type: String
    public var status: String?
    public var description: String?
    public var command: String?
    public var agentType: String?

    public init(id: String, type: String, status: String? = nil, description: String? = nil,
                command: String? = nil, agentType: String? = nil) {
        self.id = id
        self.type = type
        self.status = status
        self.description = description
        self.command = command
        self.agentType = agentType
    }

    static func decode(_ d: [String: Any]?) -> BackgroundTaskSnapshot? {
        guard let d, let id = d["id"] as? String, !id.isEmpty else { return nil }
        func str(_ key: String) -> String? {
            guard let s = d[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        return BackgroundTaskSnapshot(id: id, type: str("type") ?? "shell", status: str("status"),
                                      description: str("description"), command: str("command"),
                                      agentType: str("agent_type"))
    }
}
