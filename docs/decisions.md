# Decisions & deviations log

Newest last. Each entry: what, why, spec impact.

## D-001 — Claude Code hooks reference (summary, 2026-10-17, CLI 2.1.292 / desktop-bundled 2.1.295)
Source: https://code.claude.com/docs/en/hooks. Field names below come from the docs;
the Phase 0 capture (fixtures/) is the source of truth where they disagree.

**Where:** user-level hooks go in `~/.claude/settings.json` under `"hooks"`:
`{ "<Event>": [ { "matcher": "...", "hooks": [ { "type": "command", "command": "...", "timeout": N, "async": bool } ] } ] }`.
Matcher omitted / `""` / `"*"` = all. All matching hooks for an event run **in parallel**.

**Common stdin fields (all events):** `session_id`, `transcript_path`, `cwd`,
`permission_mode`, `hook_event_name`; optional `prompt_id`, `effort.level`,
`agent_id` / `agent_type` (subagents).

| Event | Extra fields | Matcher values |
|---|---|---|
| SessionStart | `source` (startup/resume/clear/compact/fork), `model`?, `session_title`? | source |
| UserPromptSubmit | prompt text (docs summary says `prompt_text`; historically `prompt` — verify in capture), `turn_number` | — |
| Notification | `notification_type` (permission_prompt, idle_prompt, auth_success, elicitation_dialog, agent_needs_input, agent_completed, …), `message` | notification_type |
| PermissionRequest | `tool_name`, `tool_input`, `tool_use_id` | tool name |
| Stop | `stop_hook_active`, `last_assistant_message`, `stop_reason`, `turn_number` | — |
| StopFailure | turn ended by API error | — |
| SessionEnd | `reason` (clear/resume/logout/prompt_input_exit/other) | reason |

**Timeouts:** command hooks default 600s; UserPromptSubmit 30s; **SessionEnd has a 1.5s
shared budget** for all its hooks. `"async": true` runs the hook in the background so it
can never delay Claude.
**Exit codes:** 0 = ok (stdout on SessionStart/UserPromptSubmit is injected as context →
our hook must print nothing); 2 = block (must never use); other = non-blocking error.
**Env in hook:** `CLAUDE_PROJECT_DIR`, `CLAUDE_EFFORT`, `CLAUDE_CODE_REMOTE`, plus
the inherited environment.

## D-002 — Mongo database: `agent_memory`, not `claude_monitor`
User instruction (2026-10-17): URI `mongodb://127.0.0.1:27017/agent_memory?directConnection=true`,
store in the existing `agent_memory` db in **new collections**. To avoid clashing with
memory-agent's collections they will be prefixed: `claude_monitor_events`,
`claude_monitor_sessions`. Spec's "dedicated user with readWrite on claude_monitor only"
is not applicable as given (URI has no credentials) — revisit in Phase 3.
Observed: 27017 is a **native mongod** bound to 127.0.0.1/::1 (not Docker); the Docker
`memory-agent-mongodb` container is on 127.0.0.1:27018. Both loopback-only. Confirm in Phase 3.
The URI still goes in the Keychain, never in the repo.

## D-003 — Extra hook events in the spike
Beyond the five spec events we also capture `PermissionRequest`, `PostToolUse` and
`StopFailure`. Reason: after a permission prompt is approved, no spec event fires until
`Stop`, so the session would sit in `needs_permission` for the whole turn.
`PostToolUse` (async, so no added latency) is the signal for "back to working";
`PermissionRequest` may be a faster/more precise permission signal than the
Notification; `StopFailure` avoids a turn that died on an API error looking `working`.
Final event set decided after analysing the capture.

## D-004 — Hook implementation choices
- `async: true` on every event except SessionEnd (async may be dropped at process exit;
  hook takes ~0.1s, inside the 1.5s budget). Consequence: lines can land slightly out
  of order → the app orders per session by `ts`, not by file position.
- Git branch read from `.git/HEAD` in pure bash (handles worktrees' `.git` file),
  no `git` fork → no timeout needed, can't hang on a locked repo.
- One `ps` call; we walk the ancestry to find the `claude` process and record
  `claude_pid`, `tty`, `claude_path`, `proc_chain`. `claude_pid` will let the sweeper
  detect dead sessions with `kill -0` (faster than the 6h timeout).
- Additive fields: `ts`, `event_id`, `hostname`, `hook_version`, `git_root`,
  `git_branch`, `claude_pid`, `tty`, `claude_path`, `proc_chain`, `env_names` (SessionStart).
- Truncation: every string ≤ 400 chars; if the line is still ≥ 3900 bytes, strings ≤ 120
  and drop arrays; final fallback keeps only key fields + `truncated: true`.
- Prints nothing to stdout (stdout would be injected into Claude's context).
- `CLAUDE_MONITOR_EVENTS_FILE` env overrides the output path (tests).

## D-005 — Early `source` signal (pre-capture observation)
`ps` on this Mac shows desktop-spawned sessions as
`~/Library/Application Support/Claude/claude-code/<ver>/<hash>/claude.app/Contents/MacOS/claude`
with parent `/Applications/Claude.app/Contents/Helpers/disclaimer` and no TTY, while
terminal sessions are plain `claude` with a `ttysNNN`. To be confirmed from the capture.

## D-006 — Bug fix: hook wrote nothing when any added field was empty
`select(. != "")` inside a jq object literal yields *no object* if the value is empty, so
the hook silently wrote nothing whenever there was no claude ancestor, no tty or no git
repo. Desktop sessions (no tty) would have looked like "desktop produces no events".
Now all fields are built and empty ones are removed afterwards. Regression tests are in
`hooks/test-hook.sh`.

## D-007 — Capture results (2026-10-18, fixtures/capture-2026-10-18.jsonl)
80 events: 3 terminal sessions in Terminal.app, 2 in the VS Code integrated terminal,
1 full desktop (Code tab, Local) session, and 2 desktop sessions closed by an app quit.
**Desktop sessions DO fire hooks** (all events seen: SessionStart, UserPromptSubmit,
PostToolUse, PermissionRequest, Notification, Stop, SessionEnd), so the design holds.

Observed payloads (they replace the D-001 guesses):
- The prompt field is `prompt` (not `prompt_text`). No `turn_number`, `stop_reason` or `session_title` fields.
- Stop: `stop_hook_active`, `last_assistant_message`, `background_tasks`, `session_crons`.
- PermissionRequest: `tool_name`, `tool_input`, `mcp_server`. It has **no** `tool_use_id`.
- Notification: `notification_type` + `message`. Seen: `permission_prompt`
  ("Claude needs your permission to use …") and `idle_prompt` ("Claude is waiting for your input").
  It carries no `permission_mode`.
- SessionEnd `reason`: `prompt_input_exit` (/exit) and `other` (app quit, VS Code terminal closed).
- Desktop `permission_mode` was `auto`; terminal sessions here were `bypassPermissions`.
- Timing: PermissionRequest fired 6s **before** the `permission_prompt` Notification, and
  `idle_prompt` fires ~60s after Stop when the user does not reply.
- No out-of-order lines in this capture (async hooks). The app still orders by `ts`.
- Largest line: 2.3KB (< 4KB limit).

**`source` rule** (evaluated on every event, first match wins):
1. `desktop` if any `proc_chain` entry contains `/Applications/Claude.app/` or
   `claude_path` contains `/Application Support/Claude/claude-code/`.
2. `terminal` if `tty` is non-empty (Terminal.app, iTerm2, VS Code terminal all have one).
3. otherwise `unknown`.
Backup signal on SessionStart only: `env_names` contains `CLAUDE_CODE_DESKTOP_APP_VERSION` (desktop only).

**Gaps** (the user chose to move on, so these are accepted): no StopFailure, no `idle_prompt`/user-initiated
SessionEnd from a desktop session. Sessions can appear with **no SessionStart** (started
before hooks were installed) or SessionEnd-only (VS Code terminals). The app must create
a session from any first event.
Added during Phase 1 testing: `fixtures/terminal-permission-2026-10-18.jsonl`, a terminal session
in `default` mode with two prompts. The first had PermissionRequest followed 6s later by the Notification,
as on desktop. The second was approved within 6s, so **no Notification fired at all**: PermissionRequest
is required, not just faster.

## D-008 — Event → state mapping (refines the spec's Phase 1 state machine)
| Event | Transition |
|---|---|
| SessionStart (startup/resume/clear) | → idle |
| SessionStart (compact) | no change (mid-turn compaction must not reset `working`); a closed or new session → idle |
| UserPromptSubmit | → working |
| PermissionRequest | → needs_permission (primary signal, 6s earlier than the Notification) |
| Notification `permission_prompt` | → needs_permission (fallback) |
| Notification `elicitation_dialog`, `agent_needs_input` | → waiting_input |
| Notification `idle_prompt` | → waiting_input **only if** the session was idle/working/needs_permission. After Stop (done_unreviewed/reviewed) it is just the 60s reminder and does not change state, otherwise every finished turn would flip to waiting_input |
| PostToolUse | needs_permission / waiting_input / idle → working (the permission was answered) |
| Stop | → done_unreviewed |
| StopFailure | → done_unreviewed (last_message = the error) |
| SessionEnd | → closed |
| "Mark reviewed" | done_unreviewed / waiting_input → reviewed |
| any event on a closed session | reopens it (resume) |
Events with `ts` older than the session's `last_event_at` update the metadata only, not the state.

## D-009 — No Xcode: SwiftPM-only build (deviation from "SwiftPM + Xcode project")
This Mac has the Command Line Tools only (Swift 6.4, macOS 27 SDK), and no Xcode.
- `app/` is a plain Swift package: `ClaudeMonitorCore` (all logic, no UI imports),
  `ClaudeMonitor` (SwiftUI shell), `ClaudeMonitorCoreTests` (Swift Testing).
- `app/scripts/build-app.sh` wraps the release binary into `app/build/ClaudeMonitor.app`
  (Info.plist with `LSUIElement`, ad-hoc `codesign`). This also gives the bundle identity
  that UNUserNotificationCenter needs in Phase 2.
- The CLT have no SwiftUI macro plugins, so `@State` and `@Observable` fail to compile.
  The UI therefore uses `ObservableObject` + `@Published` + `@ObservedObject` (property wrappers, not macros).
- `swift test` intermittently fails with "plugin for module 'TestingMacros' not found":
  SwiftPM sometimes omits `-plugin-path` for the test module. `app/scripts/test.sh`
  passes it explicitly, and it passed 5 out of 5 runs. Always use the script.
- If Xcode is installed later, an Xcode project can be added; nothing here depends on its absence.

## D-010 — Persistence of live state across relaunches
The spec persists `read_offset`, but sessions live in memory, and `acknowledged_at`
(Mark reviewed) exists nowhere in the events file. So the app saves one snapshot,
`~/Library/Application Support/ClaudeMonitor/state.json` = {cursor (offset + inode), sessions},
written atomically after each ingest. On launch it loads the snapshot and continues from the cursor.
If the snapshot is missing, unreadable or from another version, it replays events.jsonl from 0
(the file is the source of truth). Rotation is detected when the inode changes or the size drops below
the offset: reading restarts at 0 and a line is logged.
File watching: a DispatchSource on the file (write/extend/delete/rename) for instant updates,
plus a 2s poll that catches a file that doesn't exist yet or was replaced.
"Mark reviewed" is in the Phase 1 UI (the spec puts it in Phase 2) because without it the
badge can only grow. "Review all done" stays in Phase 2.
