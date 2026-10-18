#!/bin/bash
# Claude Monitor hook: appends ONE JSON line per Claude Code hook event to
#   ~/Library/Application Support/ClaudeMonitor/events.jsonl
# Contract: single append, line < 4KB, no network, always exit 0, never blocks Claude.
# Usage (settings.json): bash "<path>/claude-monitor-hook.sh"
# Env overrides (tests): CLAUDE_MONITOR_EVENTS_FILE

HOOK_VERSION=1
set +e
trap 'exit 0' ERR INT TERM
export LC_ALL=C

OUT="${CLAUDE_MONITOR_EVENTS_FILE:-$HOME/Library/Application Support/ClaudeMonitor/events.jsonl}"
JQ="$(command -v jq || echo /usr/bin/jq)"
[ -x "$JQ" ] || exit 0

input="$(cat 2>/dev/null)"
[ -n "$input" ] || exit 0

# --- git root + branch: pure bash, no git fork (reads .git/HEAD; handles worktrees) ---
cwd="$("$JQ" -r '.cwd // empty' <<<"$input" 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"
git_root="" ; git_branch=""
d="$cwd"; i=0
while [ -n "$d" ] && [ "$d" != "/" ] && [ $i -lt 40 ]; do
  if [ -d "$d/.git" ]; then git_root="$d"; head_file="$d/.git/HEAD"; break; fi
  if [ -f "$d/.git" ]; then
    git_root="$d"
    gd="$(sed -n 's/^gitdir: //p' "$d/.git" 2>/dev/null | head -n1)"
    case "$gd" in /*) ;; *) gd="$d/$gd" ;; esac
    head_file="$gd/HEAD"; break
  fi
  d="${d%/*}"; i=$((i+1))
done
if [ -n "$git_root" ] && [ -r "$head_file" ]; then
  IFS= read -r head < "$head_file"
  case "$head" in
    "ref: refs/heads/"*) git_branch="${head#ref: refs/heads/}" ;;
    *) git_branch="detached:${head:0:12}" ;;
  esac
fi

# --- process ancestry: find the claude process, its pid/tty/path (one ps fork) ---
proc="$(ps -A -o pid=,ppid=,tty=,comm= 2>/dev/null | awk -v start="$$" '
  { pid=$1; ppid[pid]=$2; tty[pid]=$3; $1=$2=$3=""; sub(/^ +/,""); comm[pid]=$0 }
  END {
    p=ppid[start]; n=0; found=""
    while (p != "" && p > 1 && n < 12) {
      c=comm[p]; k=c; sub(/.*\//,"",k)
      chain = chain (n ? "\x1f" : "") c
      if (found == "" && (k == "claude" || k ~ /^claude[ -]/ || c ~ /claude-code/)) found=p
      p=ppid[p]; n++
    }
    if (found == "") { printf "\x1e\x1e\x1e%s", chain; exit }
    printf "%s\x1e%s\x1e%s\x1e%s", found, tty[found], comm[found], chain
  }')"
IFS=$'\x1e' read -r claude_pid claude_tty claude_path proc_chain <<<"$proc"
[ "$claude_tty" = "??" ] && claude_tty=""

# --- env var NAMES (not values) on SessionStart only ---
env_names=""
case "$input" in
  *'"SessionStart"'*) env_names="$(compgen -e | tr '\n' ' ')" ;;
esac

event_id="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')"

build() { # $1 = max string length
  "$JQ" -c --arg eid "$event_id" --arg host "${HOSTNAME%%.*}" \
    --arg root "$git_root" --arg branch "$git_branch" \
    --arg cpid "$claude_pid" --arg tty "$claude_tty" --arg cpath "$claude_path" \
    --arg chain "$proc_chain" --arg envn "$env_names" --argjson max "$1" \
    --argjson hv "$HOOK_VERSION" '
    def trunc: if type == "string" and length > $max then .[0:$max] + "…" else . end;
    def ms: (now * 1000 | floor) as $m
      | ($m / 1000 | floor | strftime("%Y-%m-%dT%H:%M:%S")) + "."
        + (($m % 1000) + 1000 | tostring | .[1:]) + "Z";
    # Build every extra field, then drop the empty ones. (A `select` inside an object
    # literal would yield NO object at all when any field is empty.)
    (walk(trunc)) + ({
      ts: ms, event_id: $eid, hostname: $host, hook_version: $hv,
      git_root: $root, git_branch: $branch,
      claude_pid: (try ($cpid | tonumber) catch null), tty: $tty,
      claude_path: ($cpath | trunc),
      proc_chain: (if $chain == "" then null else $chain | split("\u001f") | map(trunc) end),
      env_names: (if $envn == "" then null else $envn | split(" ") | map(select(. != "")) end)
    } | with_entries(select(.value != null and .value != "")))
  ' <<<"$input" 2>/dev/null
}

line="$(build 400)"
[ ${#line} -ge 3900 ] && line="$(build 120 | "$JQ" -c 'del(.env_names, .proc_chain)')"
[ ${#line} -ge 3900 ] && line="$("$JQ" -c '{ts, event_id, hostname, hook_version, session_id,
  hook_event_name, cwd, git_root, git_branch, claude_pid, tty, notification_type, source,
  reason, truncated: true}' <<<"$line" 2>/dev/null)"
[ -n "$line" ] && [ ${#line} -lt 4000 ] || exit 0

mkdir -p "${OUT%/*}" 2>/dev/null
# One printf of < 4KB to an O_APPEND fd = one write(2): atomic w.r.t. concurrent appenders.
printf '%s\n' "$line" >> "$OUT" 2>/dev/null
exit 0
