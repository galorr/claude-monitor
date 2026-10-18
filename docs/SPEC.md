# Claude Monitor: Build Spec

Build a macOS menu-bar app, "Claude Monitor", that tracks all my Claude Code
sessions (terminal CLI + Claude desktop app, both running locally on this Mac) so I
never miss one that needs me: waiting for permission, waiting for input, finished
but not reviewed, or stuck. Single user, local only. Private repo.

Stack: SwiftUI (MenuBarExtra), macOS 14+, Swift Package Manager + Xcode project.
Persistence: my existing MongoDB via MongoKitten
(see docs/decisions.md D-002: `agent_memory` db, new collections).

## Working rules
- Work in phases. At the end of each phase STOP, show me exactly what to run to
  test it, and wait for my OK. Commit at the end of each phase.
- When this spec conflicts with current Claude Code docs or library reality, follow
  reality and tell me what you changed.
- Never commit secrets (Mongo URI, tokens). .gitignore anything local.
- Keep logic in testable modules (no business logic in SwiftUI views).
- Log app errors to ~/Library/Logs/ClaudeMonitor/.

## Architecture contract (don't change without asking)
1. Hook → file: every Claude Code process runs a hook script that APPENDS one JSON
   line per event to
   ~/Library/Application Support/ClaudeMonitor/events.jsonl
   Single write, line < 4KB, always exit 0, no network, must never slow or block Claude.
2. File = source of truth. The app tails it (DispatchSource/FSEvents) with a persisted
   read_offset, and keeps live state in memory.
3. Mongo = query store. A separate synced_offset tracks persistence. A Mongo
   outage must NEVER affect live state or notifications; backfill on reconnect.
4. Notifications come from the app (UNUserNotificationCenter).
5. Branch format `epic/<KEY>/T<n>` is a fixed contract with another tool
   (an epic-planner plugin). Parse it to epic_key / task_id.

Repo layout:
  hooks/        hook script + settings snippet
  app/          Swift package + Xcode project
  fixtures/     real captured hook payloads (used by tests)
  docs/         SPEC.md (this file), decisions.md (log of deviations/choices)
  CLAUDE.md     short: points to docs/SPEC.md, current phase, how to build/test

## Phase 0: Spike (no app yet)
1. Create CLAUDE.md, .gitignore, docs/decisions.md.
2. Read the current Claude Code hooks docs: event names, the stdin JSON fields for
   SessionStart, UserPromptSubmit, Notification, Stop, SessionEnd; timeouts; and
   where user-level hooks go in ~/.claude/settings.json. Summarise them in decisions.md.
3. Write hooks/claude-monitor-hook.sh (bash + jq, or python3 if jq is missing):
   read stdin JSON; add ts (ISO8601 ms), event_id (uuid), hostname, git branch
   of cwd (fast, with a timeout), the TTY of the parent claude process (ps), and on
   SessionStart only the env var NAMES (not values), so we can find a
   terminal-vs-desktop signal. Truncate large fields to stay < 4KB. Append atomically.
4. Give me the exact settings.json snippet to MERGE by hand with my existing hooks.
   Tell me to back up settings.json first.
5. I'll run one terminal session and one desktop session (including a permission
   prompt, an idle wait, and a normal finish). Then you analyse the file: which events
   fired from each source, payload shapes, proposed `source` detection rule. Copy
   anonymised samples to fixtures/.
   If desktop sessions produce NO events, STOP. The design depends on this.

## Phase 1: Core app
- MenuBarExtra with a badge count of sessions needing me.
- File tailer: persisted read_offset, handles rotation, partial lines, malformed lines
  (skip + log).
- Session model keyed by session_id: cwd, repo (folder name / git root), branch,
  epic_key, task_id, source (terminal|desktop|unknown), tty, state, last_event_at,
  last_message, acknowledged_at, updated_at.
- State machine (pure Swift, unit-tested against fixtures/):
  SessionStart → idle
  UserPromptSubmit → working
  Notification(permission) → needs_permission
  Notification(idle / waiting for input) → waiting_input
  Stop → done_unreviewed
  user "Mark reviewed" → reviewed
  SessionEnd → closed
  The same session_id resumed from another source = same session; update source.
- List sorted by urgency: needs_permission > waiting_input > done_unreviewed >
  stale > working > idle > reviewed. Each row: repo, branch/task, source icon, state,
  time since last event, last message snippet.

## Phase 2: Notifications, review, sweeper
- Notify on entering needs_permission, waiting_input, done_unreviewed (deduped per
  state transition; clicking a notification opens the app on that session).
- "Mark reviewed" per session + "Review all done".
- Sweeper every 60s: working with no event > 10 min → stale; any state with no event
  > 6h → presumed_dead. Closed/dead hidden after 24h. All thresholds in Settings.
- Test: kill a terminal mid-session → it ends up presumed_dead, not stuck in working.

## Phase 3: Persist to Mongo with MongoKitten
- First: confirm MongoKitten's current version, maintenance status, Swift/macOS
  compatibility, and that it supports my Mongo server version (ask me). If it's
  unmaintained or incompatible, STOP and tell me before writing code.
- Ask me for the Mongo URI. Mongo must be published on 127.0.0.1:27017 (never 0.0.0.0);
  check this with me. Use a dedicated user with readWrite on `claude_monitor` only.
  Store the URI in the Keychain; Settings screen to enter and test it.
- All Mongo code behind a `PersistenceStore` protocol (MongoStore + InMemoryStore for
  tests). UI and state machine never import MongoKitten.
- On launch, idempotently ensure these indexes:
  events: unique event_id; {session_id:1, ts:-1}; TTL on ts (30 days, configurable)
  sessions: _id = session_id; state; repo; epic_key; updated_at
- Sync: batch-insert events (≤200, ordered:false; duplicate key = already synced).
  Advance synced_offset only after success. Exponential backoff.
  Upsert the session doc on each state change; skip if the stored updated_at is newer.
- History view: per-session event timeline from Mongo (paged).
- Stats view (aggregations, 1d/7d/30d): sessions by state/source/repo; median time in
  needs_permission; median done_unreviewed → reviewed.
- Menu shows Mongo status: connected / backlog N / offline.
- Integration test against a separate test database: stop Mongo → run sessions →
  start Mongo → backlog drains, counts match, no duplicates.

## Phase 4: Hook installer (in the app)
- Install the hook script to ~/Library/Application Support/ClaudeMonitor/bin
  (versioned; update in place).
- MERGE our entries into ~/.claude/settings.json: timestamped backup first; never
  remove, reorder or modify my existing hooks; validate the JSON after writing; restore
  the backup on any failure. Mark our entries so they're identifiable.
- Clean uninstall removes only our entries. Status shows installed / outdated / missing.
- Unit tests for merge/unmerge on fixture settings files (empty, existing hooks,
  hooks already installed, malformed).

## Phase 5: Jump + epics
- Click a session → focus its iTerm2 or Terminal.app tab via the recorded tty
  (AppleScript; request Automation permission gracefully). Desktop sessions: just
  activate the Claude app.
- Group by epic_key in the list (collapsible), showing task_id per session.
- Hotkey to open the menu (configurable).

## Build & distribution
- Ad-hoc signed local build. Give me: build command, where the .app lands, how to
  make a .dmg (create-dmg or hdiutil), first-launch steps (Gatekeeper right-click →
  Open), and how to grant notification permission.
- Launch at login option (SMAppService).

## Definition of done
- Over one normal workday, every permission prompt, idle wait and finish in
  both terminal and desktop sessions shows up in the app and fires one notification.
- Killing terminals or sleeping the Mac leaves no zombie "working" sessions.
- Docker/Mongo down for an hour → no live impact; full backfill after.
- Installer round-trip leaves my original settings.json byte-identical after uninstall.
