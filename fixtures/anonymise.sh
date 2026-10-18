#!/bin/bash
# Anonymise a captured events.jsonl for use as a test fixture.
#   ANON_REPLACE='acme-corp=acme,ACME=PROJ' bash fixtures/anonymise.sh < events.jsonl > fixtures/<name>.jsonl
# ANON_REPLACE: optional comma-separated from=to pairs (org/repo/ticket names).
# Keeps structure, event names, timings, tty, proc_chain shape and system notification
# text. Replaces: home dir, user name, hostname, prompts, assistant messages,
# tool inputs/responses. Session/event UUIDs are random and kept as-is.
set -euo pipefail
user="$(id -un)"
host="$(hostname -s)"
jq -c --arg home "$HOME" --arg user "$user" --arg host "$host" \
  --arg repl "${ANON_REPLACE:-}" '
  ($repl | split(",") | map(select(. != "") | split("="))) as $pairs
  | def scrub: if type == "string"
    then gsub($home; "/Users/user") | gsub($user; "user") | gsub($host; "host")
      | reduce $pairs[] as $p (.; gsub($p[0]; $p[1]))
    else . end;
  walk(scrub)
  | if has("prompt") then .prompt = "<prompt>" else . end
  | if has("last_assistant_message") and .last_assistant_message != null
      then .last_assistant_message = "<assistant message>" else . end
  | if has("tool_input") then .tool_input = {"redacted": true} else . end
  | if has("tool_response") then .tool_response = {"redacted": true} else . end
'
