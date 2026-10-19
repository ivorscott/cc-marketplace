#!/usr/bin/env bash
# Shared helpers for the /fleet scripts. Source it; don't run it.

FLEET_STATE_DIR="${FLEET_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/fleet}"
FLEET_CONFIG_DIR="${FLEET_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/fleet}"
FLEET_REGISTRY="${FLEET_REGISTRY:-$FLEET_STATE_DIR/fleet.json}"
FLEET_WORKTREES="${FLEET_WORKTREES:-$FLEET_STATE_DIR/worktrees}"
FLEET_INBOX="${FLEET_INBOX:-$FLEET_STATE_DIR/escalations.jsonl}"
FLEET_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_SKILL_DIR="$(dirname "$FLEET_SCRIPTS")"

# Tests never touch the live fleet. With FLEET_TEST=1, any script that sources this file dies when the
# registry, the state dir or the escalation inbox resolves to the live default, computed from the real
# HOME (FLEET_REAL_HOME, captured by the suite before it overrides HOME).
if [ "${FLEET_TEST:-}" = 1 ]; then
  _live="${FLEET_REAL_HOME:-$HOME}/.local/state/fleet"
  for _v in "$FLEET_REGISTRY" "$FLEET_STATE_DIR" "$FLEET_INBOX"; do
    case "$_v" in
      "$_live" | "$_live"/*) printf 'fleet: FLEET_TEST=1 but %s is under the live fleet state (%s); refusing\n' "$_v" "$_live" >&2; exit 1 ;;
    esac
  done
  unset _live _v
fi

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
    and ((has("herdr_ref") | not) or (.herdr_ref | type == "string"))
    and ((has("repo") | not) or (.repo | type == "string"))
    and ((has("pr") | not) or (.pr | type == "string" and (. == "" or startswith("https://"))))
    and ((has("signoff") | not) or (.signoff | type == "object" and (.sha | type == "string" and test("^[0-9a-f]{7,40}$"))
         and ((has("pr") | not) or (.pr | type == "string"))))
    and ((has("transcript") | not) or (.transcript | type == "string"))
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
# build_brief --resume <name> <expertise-file> <role brief>: the brief for a respawned agent.
build_brief() {
  if [ "${1:-}" = "--resume" ]; then shift; resume_brief "$@"; return; fi
  printf '%s%s' "$3" "$(contract "$1" "$2")"
}

# resume_brief <name> <expertise-file> <role brief>: what a respawned agent needs to carry on: its role
# brief, its assignment, the last report file of its role, `git status` and `git log` of its branch,
# and its open escalations (no screen text: it would come back as a user turn). A lead also gets
# the plan path (the planner's summary) and the team's rows.
resume_brief() {
  local name="$1" ex="$2" role_brief="$3" row dir role team report="" gs="" gl="" esc="" plan="" rows=""
  row="$("$FLEET_SCRIPTS/registry.sh" get "$name")" || return 1
  dir="$(printf '%s' "$row" | jq -r 'if (.worktree // "") != "" then .worktree else (.cwd // "") end')"
  role="${name#*/}"; team="${name%%/*}"
  [ -z "$dir" ] || [ ! -d "$dir" ] || {
    report="$(ls -t "$dir"/reports/*-"$role"*.md "$dir"/*-"$role"*.md 2>/dev/null | head -n 1 || true)"
    gs="$(git -C "$dir" status --short 2>/dev/null | head -n 30 || true)"
    gl="$(git -C "$dir" log -5 --oneline 2>/dev/null || true)"
  }
  esc="$("$FLEET_SCRIPTS/registry.sh" escalations --open | jq -r --arg n "$name" '.[] | select(.name == $n) | "- [\(.severity)] \(.message)"')"
  if [ "$(printf '%s' "$row" | jq -r .tier)" = "Lead" ]; then
    plan="$("$FLEET_SCRIPTS/registry.sh" list --team "$team" | jq -r '[.[] | select(.name | endswith("/planner")) | .summary // ""] | first // ""')"
    rows="$("$FLEET_SCRIPTS/registry.sh" list --team "$team" | jq -r '.[] | "- \(.name): \(.status)\(if (.summary // "") != "" then " (\(.summary))" else "" end)"')"
  fi
  printf '%s\n\nYou are being respawned: your previous session died. Carry on from where the record below says you were; do not start over.\nAssignment: %s\n' \
    "$role_brief" "$(printf '%s' "$row" | jq -r '.assignment // ""')"
  [ -z "$report" ] || printf 'Your last report file: %s\n' "$report"
  [ -z "$gl" ] || printf '\ngit log -5 --oneline:\n%s\n' "$gl"
  printf '\ngit status --short:\n%s\n' "${gs:-(clean)}"
  [ -z "$esc" ] || printf '\nYour open escalations:\n%s\n' "$esc"
  [ -z "$plan" ] || printf '\nThe plan (from the planner summary): %s\n' "$plan"
  [ -z "$rows" ] || printf '\nThe team:\n%s\n' "$rows"
  contract "$name" "$ex"
}

# --- the event log: one append-only JSON line per thing that happened ---------------------------------
# ev_log <type> [team=T] [name=N] [issue=I] [pr=URL] [sha=S] [detail=SHORT REASON]
# {at, type, team, name, issue, pr, sha, detail}; empty values are null. detail is a short reason (cut
# at 120 characters), never brief text and never the Linear key; any other key is ignored. One `>>`
# write. A write that fails is a warning, never a failure of the caller.
events_file() { printf '%s\n' "${FLEET_EVENTS:-$FLEET_STATE_DIR/events.jsonl}"; }
ev_log() {
  local type="$1" kv k v line f; shift
  local a_team="" a_name="" a_issue="" a_pr="" a_sha="" a_detail=""
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      team) a_team="$v" ;; name) a_name="$v" ;; issue) a_issue="$v" ;; pr) a_pr="$v" ;; sha) a_sha="$v" ;;
      detail) a_detail="${v:0:120}" ;;
    esac
  done
  line="$(jq -nc --arg at "${FLEET_NOW:-$(now)}" --arg type "$type" --arg team "$a_team" --arg name "$a_name" --arg issue "$a_issue" \
    --arg pr "$a_pr" --arg sha "$a_sha" --arg detail "$a_detail" \
    '{at: $at, type: $type, team: $team, name: $name, issue: $issue, pr: $pr, sha: $sha, detail: $detail} | with_entries(if .value == "" then .value = null else . end)')" || return 0
  f="$(events_file)"
  { mkdir -p "$(dirname "$f")" && printf '%s\n' "$line" >>"$f"; } 2>/dev/null || warn "cannot write the event log $f"
  return 0
}

# linear_writes: whether anything may write to Linear. off (the default; anything unrecognised too),
# test:<TEAM> (writes only on issues of that Linear team) or on. Checked by linear.sh before any write.
linear_writes() {
  local v; v="$(cfg_str linear_writes off)"
  case "$v" in
    off | on | test:?*) printf '%s\n' "$v" ;;
    *) warn "linear_writes = '$v' is not off, test:<TEAM> or on; treating it as off"; printf 'off\n' ;;
  esac
}

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
# tree); transcript_dir_for <cwd> is the project directory for a working directory (every character
# of the cwd that is not a letter or digit becomes "-"). Observed for "/" and "."; UNVERIFIED for other
# characters such as "_" (no existing project directory has one in its name, which is consistent). Scripts read them only through these helpers.
projects_dir() { printf '%s\n' "${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"; }
transcript_dir_for() { printf '%s/%s\n' "$(projects_dir)" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g')"; }
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

# transcript_bg_running <transcript file>: how many background tasks the agent has running: tool_use blocks
# with input.run_in_background == true, or named Monitor, whose task id (in the matching tool_result text:
# "...running in background with ID: <id>" or "Monitor started ... task <id>") has no later
# <task-notification><task-id><id></task-id> line, and that started less than bg_task_max_hours (default 6)
# ago (a task killed without a notification would otherwise count until the session ends). Observed shape of
# Claude Code transcripts, not a documented contract: UNVERIFIED for stability. Unreadable: 0.
transcript_bg_running() {
  [ -r "$1" ] || { echo 0; return 0; }
  local maxs now_e; maxs=$(($(cfg_int bg_task_max_hours 6) * 3600))
  now_e="$(jq -rn --arg t "${FLEET_NOW:-$(now)}" '$t | fromdateiso8601')"
  jq -nRr --argjson now "$now_e" --argjson max "$maxs" '
    def ep: (. // "" | tostring | sub("\\.[0-9]+Z$"; "Z") | (try fromdateiso8601 catch null));
    def body: if type == "string" then . elif type == "array" then
        [.[]? | if type == "string" then . else (.text? // (if (.content | type) == "string" then .content else ([.content[]? | .text? // ""] | join("")) end) // "") end] | join(" ")
      else "" end;
    [inputs | fromjson? | select(type == "object")] as $L
    | ([$L[] | select(.type == "assistant") | .timestamp as $t | (.message.content // [])[]?
        | select(type == "object" and .type == "tool_use" and ((.input.run_in_background? == true) or .name == "Monitor"))
        | {tool: .id, at: ($t | ep)}]) as $starts
    | ([$L[] | select(.type == "user") | (.message.content // [])[]? | select(type == "object" and .type == "tool_result")
        | {tool: .tool_use_id, text: (.content | body)}]) as $results
    | ([$L[] | select(.type == "user") | (.message.content | body) | select(contains("<task-notification>"))
        | scan("<task-id>([A-Za-z0-9_-]+)</task-id>") | .[0]] | unique) as $ended
    | [$starts[] | . as $s | ($results | map(select(.tool == $s.tool)) | first | .text // "") as $x
        | ($x | (try capture("running in background with ID: (?<id>[A-Za-z0-9_-]+)").id catch null)
            // (try capture("Monitor started[^\n]*?task (?<id>[A-Za-z0-9_-]+)").id catch null)) as $id
        | select($id != null and (($ended | index($id)) == null) and ($s.at == null or ($now - $s.at) <= $max))] | length' "$1" 2>/dev/null || echo 0
}

# footer_bg_running <screen text>: the pane footer says "N shell(s)" or "N monitor(s)" still running.
footer_bg_running() { printf '%s\n' "$1" | tail -n 8 | grep -Eq '[0-9]+ (shell|monitor)s?([ ,.]|$)'; }
