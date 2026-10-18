# Claude Monitor

macOS menu-bar app that tracks local Claude Code sessions (terminal + desktop).
Full spec: `docs/SPEC.md`. Deviations and choices: `docs/decisions.md` (log every one).

**Current phase:** 3, persist to Mongo with MongoKitten. Phases 0–2 are done.

## Rules
- Work phase by phase. Stop at each phase end with test instructions, then commit.
- Never commit secrets (Mongo URI goes in the Keychain). Never commit real events.jsonl.
- No business logic in SwiftUI views.

## Layout
- `hooks/claude-monitor-hook.sh`: appends one JSON line per event to
  `~/Library/Application Support/ClaudeMonitor/events.jsonl` (override: `CLAUDE_MONITOR_EVENTS_FILE`)
- `hooks/settings-snippet.json`: hooks block to merge into `~/.claude/settings.json`
- `fixtures/`: anonymised captured payloads (test inputs)
- `app/`: Swift package (no Xcode, D-009). `ClaudeMonitorCore` = all logic; `ClaudeMonitor` = SwiftUI shell

## Build & test the app
```bash
bash app/scripts/test.sh        # unit tests (not bare `swift test`, see D-009)
bash app/scripts/build-app.sh   # → app/build/ClaudeMonitor.app
```
State: `~/Library/Application Support/ClaudeMonitor/state.json`; log: `~/Library/Logs/ClaudeMonitor/app.log`.

## Test the hook
```bash
bash hooks/test-hook.sh   # smoke tests, writes only to a temp dir
```
