# Claude Monitor

macOS menu-bar app that tracks local Claude Code sessions (terminal + desktop).
Full spec: `docs/SPEC.md`. Deviations and choices: `docs/decisions.md` (log every one).

**Current phase:** 1, the core app (SwiftPM). Phase 0 is done: capture results are in decisions D-007 and D-008.

## Rules
- Work phase by phase. Stop at each phase end with test instructions, then commit.
- Never commit secrets (Mongo URI goes in the Keychain). Never commit real events.jsonl.
- No business logic in SwiftUI views.

## Layout
- `hooks/claude-monitor-hook.sh`: appends one JSON line per event to
  `~/Library/Application Support/ClaudeMonitor/events.jsonl` (override: `CLAUDE_MONITOR_EVENTS_FILE`)
- `hooks/settings-snippet.json`: hooks block to merge into `~/.claude/settings.json`
- `fixtures/`: anonymised captured payloads (test inputs)
- `app/`: Swift package + Xcode project (from Phase 1)

## Test the hook
```bash
bash hooks/test-hook.sh   # smoke tests, writes only to a temp dir
```
