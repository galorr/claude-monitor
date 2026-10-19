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
**Confirmed in Phase 3 (2026-10-18):** native mongod 8.3.4 on 127.0.0.1:27017 (Homebrew,
loopback only), database `agent_memory`, prefixed collections. **No auth / no dedicated user**
(the user's choice; the server is loopback-only). Settings warns if a URI is not loopback.

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

## D-011 — Sweeper and notification rules (Phase 2)
**Sweeper** runs at launch, then every 60s, and whenever settings change. For each session not closed/presumed_dead, the first matching rule wins:
1. no event for `deadAfter` (default 6h) → presumed_dead, in any open state (spec rule);
2. **an active session (idle/working/needs_permission/waiting_input/stale) whose `claude_pid`
   no longer exists** (`kill(pid,0)` fails with anything other than EPERM) → presumed_dead. This is an addition to the spec: without it a killed
   terminal would show `working` → `stale` for 6h, failing the spec's own Phase 2 test.
   done_unreviewed/reviewed are exempt because the result still needs reviewing after the process exits.
   A session without a pid (old hook lines) is judged only by time. PID reuse could keep a dead session "alive"
   until the 6h rule; this is accepted.
3. working with no event for `staleAfter` (default 10 min) → stale.
Any later event revives the session through the normal transitions. closed/presumed_dead sessions are hidden from
the list once their last event is older than `hideEndedAfter` (24h); they stay in state.json.
Thresholds and a notifications on/off switch are in an inline Settings panel, saved in UserDefaults.

**Notifications** go out on a transition INTO needs_permission / waiting_input / done_unreviewed, with these extra rules:
- at most one per session per ingest batch, and only if the session is *still* in that state at the end of the batch
  (a prompt approved in the same batch stays silent);
- not for changes older than 5 min. Replaying the file at launch and the backlog after the app was off stay silent;
- the `idle_prompt` reminder after Stop changes no state, so it can't send a second notification;
- the identifier is `<session>.<state>`, so a repeat replaces the banner instead of stacking. Banners are removed when the
  session leaves an attention state or is marked reviewed.
"Review all done" reviews done_unreviewed only. waiting_input still needs an answer.

## D-012 — Notification click opens a session window
SwiftUI has no API to open a MenuBarExtra window programmatically. The first attempt clicked the
status item's button (found by walking `NSStatusBarWindow`'s views). The log proved the click arrived and
the button was pressed, but the MenuBarExtra ignored the synthetic click and nothing opened (2026-10-18).
Now a notification click opens a small floating `NSWindow` (`SessionWindow`) at the top right of the
screen, hosting the same `SessionListView` with the clicked session highlighted and scrolled into view.
It uses public API only. The menu-bar dropdown is unchanged. Notifications need the .app bundle; when run unbundled (`swift run`) they are
disabled with a log line.
Authorization is requested on `NSApplication.didFinishLaunchingNotification`, not in `App.init`.
Requesting from `App.init` failed immediately with UNErrorDomain Code=1 "Notifications are not allowed
for this application", and no prompt was shown (seen in testing on 2026-10-18).

Testing note: closing a terminal window is NOT a kill. claude gets SIGHUP, fires SessionEnd
(`reason: other`) and the session is `closed`. Only an abrupt death (`kill -9`, crash, power loss)
leaves no SessionEnd, so that is the case where the pid check turns it `presumed_dead`.
Headless `claude -p` (seen in Phase 2 testing): the process exits right after the turn, so the
async `Stop` hook is sometimes dropped and only SessionStart/UserPromptSubmit/SessionEnd arrive.
Interactive sessions are unaffected. Headless runs are not a target of this app.

## D-013 — Phase 3: Mongo sync design
- **MongoKitten 7.16.3** (released 2026-05-20, maintained). Checked before writing code: it builds with the
  CLT-only Swift 6.4 toolchain and talks to mongod 8.3.4 (insert/count/drop spike).
- **Targets:** `ClaudeMonitorCore` defines `PersistenceStore`, `InMemoryStore` (reference
  implementation for tests) and `SyncEngine`. `ClaudeMonitorMongo` is the only target that
  imports MongoKitten (`MongoStore`). The app shell wires them together.
- **Raw commands** instead of MongoKitten's helpers: `insertMany` cannot set `ordered:false`,
  and the duplicate-key handling must be explicit (11000 = already synced).
- **Collections** (in `agent_memory`, D-002): `claude_monitor_events` (the full hook line plus `ts` as
  a BSON date; unique `event_id`, `{session_id:1, ts:-1}`, TTL on `ts`), `claude_monitor_sessions`
  (`_id` = session id; state, repo, epic_key, updated_at), and **`claude_monitor_transitions`
  (an addition to the spec)**.
- **Why a transitions collection:** the medians need the time of each state change, and some
  changes (reviewed, stale, presumed_dead) are made by the app, not by a hook. The engine
  appends every change to a local `transitions.jsonl`, which the sync tails exactly like
  events.jsonl. So app-made changes survive a Mongo outage too. Ids are
  `<session>|<state>|<ms>`, so a replay deduplicates. On first launch with no journal, it is
  backfilled from the part of events.jsonl the snapshot has already consumed. TTL on `at`, same retention as events.
- **Sync progress:** `sync.json` holds a cursor per file, separate from state.json (contract #3).
  Batches of ≤200 lines; the cursor advances after each batch the store accepted, so a
  failure re-sends at most one batch. Exponential backoff 1s→60s, then reconnect. sync.json
  stores a SHA-256 of the URI (never the URI): a different URI syncs everything again.
- **Sessions:** upserted with filter `{_id, updated_at: {$lte: new}}` + upsert. If the stored copy
  is newer, the upsert collides on `_id` (11000) = skipped. The engine's first update carries all
  sessions, so a relaunch re-sends anything that was pending at quit.
- **Medians:** from transitions with `$setWindowFields` + `$shift`, ordered by (at, _id) per session:
  needs_permission until the next transition; done_unreviewed until the next one, only when the next one is
  reviewed. Mongo returns the durations and Swift (`StatsMath`) takes the median, so Mongo and
  InMemoryStore agree exactly (an integration test checks this). Session counts = sessions with
  `updated_at` in the range.
- **History:** paged by an `(ts, event_id)` cursor, so events with equal timestamps are not skipped.
- **Dates:** BSON stores milliseconds and MongoKitten truncates `seconds*1000`, so a parsed
  `.811` (held as .81099…) became `.810`. Every date written or queried is rounded to the nearest
  millisecond first (`bsonDate`). Transition times are whole milliseconds from the start.
- **Integration test:** starts its own throwaway mongod (free port, temp dbpath, loopback) and
  stops/starts it. The real server is never touched. It is skipped if mongod is not installed.
- **Known gap:** if events.jsonl is rotated while Mongo is down, the unsynced tail of the old file is
  not synced (nothing rotates it today).

## D-014 — Phase 4: hook installer
- **Marking our entries:** the hook command carries a trailing shell comment:
  `bash "$HOME/Library/Application Support/ClaudeMonitor/bin/claude-monitor-hook.sh" # managed by Claude Monitor`.
  An extra JSON key on the hook object could break Claude Code's settings validation, while a comment can't;
  the shell ignores it (checked with `/bin/sh -c`). Ours = any hook whose command runs
  `claude-monitor-hook.sh`; managed = it also has the marker.
- **Hand-added entries** (Phase 0 told the user to merge `settings-snippet.json`, which ran the
  repo copy) are shown as "added by hand". **Take over** replaces each of them where it is with
  the managed command. Otherwise every event would fire twice. This is the one case where the
  installer changes an entry it did not write, and only entries that run our own script.
- **Merge rules:** other hooks are never removed, reordered or changed. An existing entry of ours is
  updated where it is, a missing one is appended as its own group at the end of that event's list,
  and duplicates of ours are dropped. Our entries under events this version no longer uses are
  removed. Uninstall removes only ours, plus any group, event list or `hooks` object that became
  empty because of that. So install → uninstall gives back the original file byte for byte (tested).
- **Formatting:** Claude Code writes settings.json as `JSON.stringify(v, null, 2)` + newline. An
  order-preserving parser and printer (`JSONValue`, numbers kept as written) reproduces that
  exactly, so the diff is only our lines. Checked read-only against the real file: byte-identical
  round trip, and only the 8 Claude Monitor hook objects change.
- **Writing:** a timestamped backup goes to `~/Library/Application Support/ClaudeMonitor/backups/`
  (not next to settings.json, to keep ~/.claude clean). The file is re-read just before writing; if
  Claude Code changed it meanwhile, nothing is written. The write is atomic (temp file + rename),
  keeps the file mode, and follows a symlinked settings.json (so the link stays a link). Then it is validated
  (JSONSerialization + our entries present/absent). On failure the backup is restored. Malformed
  settings are never touched.
- **Script:** bundled in the .app (`Contents/Resources`), installed to `…/ClaudeMonitor/bin` by an
  atomic rename (a hook starting at that moment runs the old or the new script, never half a
  file). "Outdated" = our entries differ from what this version writes, or the installed script
  differs from the bundled one. Uninstall also deletes the installed script.
- `hooks/settings-snippet.json` now matches exactly what the installer writes (a test checks this).
- Running Claude sessions keep the hooks they started with (Claude Code reads hooks at startup).
  The repo copy of the script stays in place, so sessions still running the old command keep working.
- Not handled: `CLAUDE_CONFIG_DIR` (a GUI app doesn't see the shell's environment). Only `~/.claude/settings.json` is used.

## D-015 — Phase 5: jump, epics, hotkey
- **Where a click goes** (`JumpPlan`, pure, in Core): from the session's tty and **host app**, the
  outermost `.app` in the hook's process chain (new `Session.hostApp`).
  Terminal.app / iTerm2 + tty → AppleScript selects the tab whose `tty` matches, un-minimises and
  raises its window. Another host (VS Code's built-in terminal) → just activate that app (its
  tabs can't be targeted). Desktop → activate Claude.app. tty without host → search Terminal,
  then iTerm2. Ended sessions don't jump (the tty may belong to something else by now).
- The tty is validated (`/dev/tty` + letters/digits only) before it goes into AppleScript, since
  events.jsonl is input.
- Only running terminals are searched (`tell application` would otherwise launch them).
- **Automation permission:** Info.plist has `NSAppleEventsUsageDescription`, and macOS asks the
  first time. If denied (-1743), the terminal is still activated and the menu explains where to allow it.
  Ad-hoc signing: a rebuilt app may be asked again.
- **Epics:** `ListItem.items` groups sessions with an epic_key. Each epic sits where its most
  urgent session would sit in the flat list, so urgency order still holds. The header shows the
  session count and how many need attention; rows inside show the task id first. Collapsed
  epics are remembered (UserDefaults). A notification for a session in a collapsed epic expands it.
- **Hotkey:** default ⌃⌥M, configurable (recorded from a key press; needs ⌘, ⌃ or ⌥) and can be
  turned off. Carbon `RegisterEventHotKey` = global and needs no Accessibility permission. Since
  the MenuBarExtra can't be opened from code (D-012), the hotkey toggles the same session window a
  notification click opens. If the shortcut is taken, Settings says so.
- **Sync hardening (found while testing):** one full test run hung once and could not be
  reproduced (4/4 runs passed after). Every store call in `SyncEngine` now has a time limit
  (30 s, then reconnect), so a hung connection can't stall the sync while it says "connected". The
  Mongo test suite has a 2-minute limit.

## D-016 — Opaque background for the menu-bar list
- The MenuBarExtra window's default glass background turned a muddy, low-contrast grey when the
  list was short and the window sat over a light page. `SessionListView` now draws
  `windowBackgroundColor` behind its content (follows light/dark mode).
