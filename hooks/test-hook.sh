#!/bin/bash
# Smoke tests for claude-monitor-hook.sh. Run: bash hooks/test-hook.sh
set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/claude-monitor-hook.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export CLAUDE_MONITOR_EVENTS_FILE="$TMP/ev.jsonl"
fail=0
check() { # name, expected line count delta, jq assertion on last line, stdin, [env -i?]
  local name="$1" want="$2" assert="$3" input="$4" before after out
  before=$( (wc -l < "$CLAUDE_MONITOR_EVENTS_FILE") 2>/dev/null || echo 0)
  out=$(printf '%s' "$input" | ${CLEAN_ENV:+env -i HOME=$HOME PATH=/usr/bin:/bin CLAUDE_MONITOR_EVENTS_FILE=$CLAUDE_MONITOR_EVENTS_FILE} bash "$HOOK"; echo "rc=$?")
  after=$( (wc -l < "$CLAUDE_MONITOR_EVENTS_FILE") 2>/dev/null || echo 0)
  if [ "$out" != "rc=0" ]; then echo "FAIL $name: stdout/exit was '$out'"; fail=1; return; fi
  if [ $((after - before)) -ne "$want" ]; then echo "FAIL $name: wrote $((after - before)) lines, want $want"; fail=1; return; fi
  if [ "$want" -gt 0 ] && ! tail -n1 "$CLAUDE_MONITOR_EVENTS_FILE" | jq -e "$assert" >/dev/null; then
    echo "FAIL $name: assertion '$assert' on: $(tail -n1 "$CLAUDE_MONITOR_EVENTS_FILE")"; fail=1; return; fi
  echo "ok   $name"
}

check "git repo cwd" 1 '.git_branch != null and .event_id and (.ts|test("\\.[0-9]{3}Z$"))' \
  '{"session_id":"s1","hook_event_name":"Stop","cwd":"'"$PWD"'"}'
check "non-git cwd (no branch)" 1 '(has("git_root")|not) and .session_id=="s1"' \
  '{"session_id":"s1","hook_event_name":"Stop","cwd":"/"}'
# Regression: an empty extra field (no tty/claude/git, e.g. desktop sessions) used to drop the whole line.
CLEAN_ENV=1 check "minimal env (GUI-like), non-git cwd" 1 '.session_id=="s1" and (has("git_root")|not)' \
  '{"session_id":"s1","hook_event_name":"Notification","notification_type":"idle_prompt","cwd":"/"}'
check "SessionStart has env names only" 1 '(.env_names|type=="array") and (.env_names|index("HOME")) and (tostring|contains(env.HOME)|not)' \
  '{"session_id":"s1","hook_event_name":"SessionStart","source":"startup","cwd":"/"}'
big=$(printf 'x%.0s' $(seq 1 20000))
check "huge field truncated < 4KB" 1 '(tostring|length) < 4000' \
  '{"session_id":"s1","hook_event_name":"Stop","cwd":"/","last_assistant_message":"'"$big"'"}'
check "malformed input" 0 '' 'not json'
check "empty input" 0 '' ''
awk 'length($0) >= 4000 { print "FAIL line over 4KB"; exit 1 }' "$CLAUDE_MONITOR_EVENTS_FILE" || fail=1

[ $fail -eq 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
