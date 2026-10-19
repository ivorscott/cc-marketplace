#!/usr/bin/env bash
# Shared helpers for the /fleet scripts. Source it; don't run it.

FLEET_STATE_DIR="${FLEET_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/fleet}"
FLEET_CONFIG_DIR="${FLEET_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/fleet}"
FLEET_REGISTRY="${FLEET_REGISTRY:-$FLEET_STATE_DIR/fleet.json}"
FLEET_WORKTREES="${FLEET_WORKTREES:-$FLEET_STATE_DIR/worktrees}"
FLEET_INBOX="${FLEET_INBOX:-$FLEET_STATE_DIR/escalations.jsonl}"
FLEET_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_SKILL_DIR="$(dirname "$FLEET_SCRIPTS")"

die() { printf 'fleet: %s\n' "$*" >&2; exit 1; }
warn() { printf 'fleet: warning: %s\n' "$*" >&2; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# jq definitions for an agent row's .escalations, prepended to programs by registry.sh,
# status.sh and retire.sh. escs reads defensively: a non-array value is empty and non-object
# elements are skipped (never rewritten, so positions stay stable). Each entry gets .seq,
# its raw 1-based array position, and .id: the stored id, or for entries filed before ids
# existed "<at compact>-<seq>", the same shape escalate writes. norm makes a write path's
# non-array value []. esc_close($resolution; $at) closes every open entry of a row (the
# shared close helper: retire uses "closed at retire", next's reassign "closed at next").
# row_ok is the schema a registry write must keep (see registry.sh update).
ESC_DEFS='def norm: if (.escalations | type) != "array" then .escalations = [] else . end;
  def esc_close($res; $t): .escalations |= map(if type == "object" and .resolved_at == null
    then . + {resolved_at: $t, resolution: $res} else . end);
  def row_ok: type == "object" and (.name | type == "string")
    and ((has("discovered") | not) or (.discovered | type == "array"))
    and ((has("escalations") | not) or ((.escalations | type == "array") and all(.escalations[];
      type == "object" and (.severity | IN("P0", "P1", "P2")) and (.message | type == "string") and (.at | type == "string")
      and ((has("id") | not) or (.id | type == "string")))));
  def escs: (if (.escalations | type) == "array" then .escalations else [] end) | to_entries
    | map(select(.value | type == "object") | (.value + {seq: (.key + 1)})
      | .id = (.id // (((.at // "") | tostring | gsub("[-:]"; "")) + "-" + (.seq | tostring))));
  '

need() { command -v "$1" >/dev/null 2>&1 || die "requires '$1' on PATH"; }
need jq

# herdr, pinned to the fleet's session. FLEET_SESSION selects a named herdr session
# (used for isolated tests); otherwise the caller's inherited session is used.
hd() {
  if [ -n "${FLEET_SESSION:-}" ]; then herdr --session "$FLEET_SESSION" "$@"; else herdr "$@"; fi
}

require_herdr() {
  need herdr
  if [ -z "${FLEET_SESSION:-}" ] && [ "${HERDR_ENV:-}" != "1" ]; then
    die "run the Orchestrator inside a herdr pane (HERDR_ENV=1), or set FLEET_SESSION=<name>"
  fi
}

# max_agents from config.toml (key = value), default 4.
max_agents() {
  local v=""
  [ -f "$FLEET_CONFIG_DIR/config.toml" ] &&
    v="$(sed -n 's/^[[:space:]]*max_agents[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$FLEET_CONFIG_DIR/config.toml" | head -1)"
  printf '%s\n' "${v:-4}"
}

# cfg_int <key> <default>: an integer from config.toml (key = value).
cfg_int() {
  local v=""
  [ -f "$FLEET_CONFIG_DIR/config.toml" ] &&
    v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$FLEET_CONFIG_DIR/config.toml" | head -1)"
  printf '%s\n' "${v:-$2}"
}
# permission_mode: the Claude Code --permission-mode every agent starts in. FLEET_PERMISSION_MODE
# wins, then config.toml (permission_mode = "..."), default auto. A pane that starts in a
# stricter mode blocks on the first permission prompt and sits idle until someone enables auto.
permission_mode() {
  local v="${FLEET_PERMISSION_MODE:-}"
  [ -z "$v" ] && [ -f "$FLEET_CONFIG_DIR/config.toml" ] &&
    v="$(sed -n 's/^[[:space:]]*permission_mode[[:space:]]*=[[:space:]]*"\([A-Za-z]*\)".*/\1/p' "$FLEET_CONFIG_DIR/config.toml" | head -1)"
  printf '%s\n' "${v:-auto}"
}

# min_free_gb (boot refuses below it, default 40; 0 disables) and warn_free_gb (watch notifies below it, default 75).
min_free_gb() { cfg_int min_free_gb 40; }
warn_free_gb() { cfg_int warn_free_gb 75; }

# lease_hours: how long a claim lease runs, and how long without PR activity before a lapsed
# lease can be taken over (default 2).
lease_hours() { cfg_int lease_hours 2; }

# archive_after_days: how long a Retired row (with its lessons written and no open escalation)
# stays in the live registry before `registry.sh archive` moves it to fleet-archive.json (default 0 = at once).
archive_after_days() { cfg_int archive_after_days 0; }

# free_gb: whole GiB free on the volume holding the fleet worktrees (the nearest existing
# ancestor of $FLEET_WORKTREES). Prints nothing and returns 1 when df can't tell.
free_gb() {
  local d="$FLEET_WORKTREES" kb
  while [ ! -d "$d" ] && [ "$d" != "/" ]; do d="$(dirname "$d")"; done
  kb="$(df -Pk "$d" 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$kb" in "" | *[!0-9]*) return 1 ;; esac
  printf '%s\n' $((kb / 1024 / 1024))
}

# config_list <key>: a TOML array of strings from config.toml as a JSON array, default [].
# The array may span lines (key = [ "a", "b" ]). Used for tracker_allow and forge_allow,
# which keep tool-specific permissions (Linear/Jira, GitHub/GitLab, ...) out of templates.
config_list() {
  local f="$FLEET_CONFIG_DIR/config.toml" v
  [ -f "$f" ] || { printf '[]\n'; return 0; }
  v="$(awk -v k="$1" '
    !on && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { on = 1; sub(/^[^=]*=/, "") }
    on { sub(/#[^"]*$/, ""); buf = buf $0 " "; if ($0 ~ /\]/) exit }
    END { printf "%s", buf }' "$f")"
  [ -n "${v// /}" ] || { printf '[]\n'; return 0; }
  # A TOML array of double-quoted strings is JSON once a trailing comma is dropped.
  v="$(printf '%s' "$v" | sed -E 's/,[[:space:]]*\][[:space:]]*$/]/')"
  printf '%s' "$v" | jq -ce 'if type == "array" and all(type == "string") then . else error end' 2>/dev/null ||
    { warn "ignoring $1 in $f: not a one-level array of strings"; printf '[]\n'; }
}

# Agent names must match herdr's rule: [a-z][a-z0-9_-]{0,31}.
agent_name() {
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
  case "$n" in [a-z]*) ;; *) n="f-$n" ;; esac
  printf '%s\n' "${n:0:32}"
}

# max_envs from config.toml (key = value), default 3.
max_envs() {
  local v=""
  [ -f "$FLEET_CONFIG_DIR/config.toml" ] &&
    v="$(sed -n 's/^[[:space:]]*max_envs[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$FLEET_CONFIG_DIR/config.toml" | head -1)"
  printf '%s\n' "${v:-3}"
}

# Team environment: a repo opts in with <repo>/.claude/fleet-env.json.
env_config() { [ -f "$1/.claude/fleet-env.json" ] && printf '%s\n' "$1/.claude/fleet-env.json" || true; }
env_dir() { printf '%s\n' "$FLEET_STATE_DIR/env/$1"; }

# render_env <template> <team> <cluster> <http> <https> <branch> <kubeconfig> [<image_tag> <image_label> <builder>]
# Values are shell-quoted: templates run through `bash -c`, and branch names are free text.
render_env() {
  local s="$1" v
  v="$(printf '%q' "$2")"; s="${s//\{\{team\}\}/$v}"
  v="$(printf '%q' "$3")"; s="${s//\{\{cluster\}\}/$v}"
  v="$(printf '%q' "$4")"; s="${s//\{\{http_port\}\}/$v}"
  v="$(printf '%q' "$5")"; s="${s//\{\{https_port\}\}/$v}"
  v="$(printf '%q' "$6")"; s="${s//\{\{branch\}\}/$v}"
  v="$(printf '%q' "$7")"; s="${s//\{\{kubeconfig\}\}/$v}"
  v="$(printf '%q' "${8:-}")"; s="${s//\{\{image_tag\}\}/$v}"
  v="$(printf '%q' "${9:-}")"; s="${s//\{\{image_label\}\}/$v}"
  v="$(printf '%q' "${10:-}")"; s="${s//\{\{builder\}\}/$v}"
  printf '%s' "$s"
}

# cfg_str <key> <default>: a double-quoted string from config.toml (key = "value").
cfg_str() {
  local v=""
  [ -f "$FLEET_CONFIG_DIR/config.toml" ] &&
    v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$FLEET_CONFIG_DIR/config.toml" | head -1)"
  printf '%s\n' "${v:-$2}"
}

# This machine's tracker identity (see machine-id.sh). The claim label is <label_prefix><key>;
# FLEET_LABEL_PREFIX wins over label_prefix in config.toml, default "fleet:".
label_prefix() { printf '%s\n' "${FLEET_LABEL_PREFIX:-$(cfg_str label_prefix 'fleet:')}"; }
machine_key() { "$FLEET_SCRIPTS/machine-id.sh" key; }
machine_label() { printf '%s%s\n' "$(label_prefix)" "$(machine_key)"; }

# contract <name> <expertise-file>: the fleet rules appended to every brief (boot, next).
contract() {
  local name="$1" expertise="$2" x="" registry="$FLEET_SCRIPTS/registry.sh"
  [ -n "$expertise" ] && x=" Before you start, read your expertise file $expertise and follow it."
  printf '%s' "

Fleet rules for $name.$x Stay on this one task. If you notice unrelated work, run \`$registry note $name discovered \"<what>\"\` instead of doing it. If you need a decision you cannot make, run \`$registry escalate $name P1 \"<question>\"\` and wait. P1 is only for a decision the user must make; \"PR ready\" goes through done, not an escalation. If you stop to wait for instructions, first run \`$registry set $name status=Idle\`. Every commit carries the trailer \`Agent: $name\`. When your part is finished: push your branch if you have one, then run \`$registry done $name --outcome <Shipped|Partial|Failed> --summary \"<one line>\"\`, then stop. Going idle without that command marks you Stalled."
}

# build_brief <name> <expertise-file> <text>: a brief plus the fleet rules.
build_brief() { printf '%s%s' "$3" "$(contract "$1" "$2")"; }

# FLEET_GH: the GitHub CLI, overridable for tests. Scripts only ever make read-only calls (pr view).
FLEET_GH="${FLEET_GH:-gh}"

# tick_state_file, tick_state: the Orchestrator tick's memory of what it already reported.
tick_state_file() { printf '%s\n' "$FLEET_STATE_DIR/tick.state.json"; }
tick_state() {
  local f; f="$(tick_state_file)"
  if [ -f "$f" ] && jq -e 'type == "object"' "$f" >/dev/null 2>&1; then cat "$f"; else printf '{}\n'; fi
}
tick_state_write() { # tick_state_write <json>
  local f tmp; f="$(tick_state_file)"; mkdir -p "$(dirname "$f")"
  tmp="$(mktemp "$f.XXXXXX")"; printf '%s\n' "$1" >"$tmp" && mv "$tmp" "$f"
}

# forge_pr_json <pr url>: read-only PR state as JSON. Fails (stderr says why) when gh can't tell.
forge_pr_json() {
  "$FLEET_GH" pr view "$1" --json state,mergeable,statusCheckRollup,headRefOid,body,url
}

# Claude Code transcripts. projects_dir is where Claude keeps them (tests point HOME at a fixture
# tree); transcript_dir_for <cwd> is the project directory for a working directory (cwd with "/"
# and "." replaced by "-"). Scripts read them only through these helpers.
projects_dir() { printf '%s\n' "${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"; }
transcript_dir_for() { printf '%s/%s\n' "$(projects_dir)" "$(printf '%s' "$1" | tr '/.' '--')"; }
new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'
  elif [ -r /proc/sys/kernel/random/uuid ]; then cat /proc/sys/kernel/random/uuid
  else od -An -N16 -tx1 /dev/urandom | tr -d ' \n' | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'; fi
}

# context_window <model>: the model's context window in tokens, from the [context_window] table
# of config.toml (model = N lines, the model name optionally quoted); default 200000.
# UNVERIFIED: the real window per model (DEV-368).
context_window() {
  local v="" f="$FLEET_CONFIG_DIR/config.toml"
  [ -f "$f" ] && v="$(awk -v m="$1" '
    /^[[:space:]]*\[/ { on = ($0 ~ /^[[:space:]]*\[context_window\]/); next }
    on { k = $0; sub(/[[:space:]]*=.*/, "", k); gsub(/^[[:space:]]*"?|"?[[:space:]]*$/, "", k)
         if (k == m) { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); sub(/[^0-9].*/, "", v); print v; exit } }' "$f")"
  printf '%s\n' "${v:-200000}"
}

# transcript_context_pct <transcript file>: percent of the context window the latest assistant
# turn used (input + cache read + cache creation tokens). Prints nothing when it can't be read.
transcript_context_pct() {
  [ -r "$1" ] || return 0
  local last model tokens
  last="$(grep -F '"type":"assistant"' "$1" 2>/dev/null | tail -n 1)" || true
  [ -n "$last" ] || return 0
  tokens="$(printf '%s' "$last" | jq -r '.message.usage | if type == "object" then ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) else empty end' 2>/dev/null)" || return 0
  [ -n "$tokens" ] || return 0
  model="$(printf '%s' "$last" | jq -r '.message.model // ""' 2>/dev/null)"
  printf '%s\n' $((tokens * 100 / $(context_window "$model")))
}
