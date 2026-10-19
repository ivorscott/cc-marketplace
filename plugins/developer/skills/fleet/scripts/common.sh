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
max_agents() { cfg_int max_agents 4; }

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
permission_mode() { printf '%s\n' "${FLEET_PERMISSION_MODE:-$(cfg_str permission_mode auto)}"; }

# const_int <name> <default>: an internal timing or threshold. It is a constant of the code, not a setting:
# config.toml is not read for it; only the environment can change it (FLEET_<NAME>, upper case), for tests.
#   claim_settle_secs 5 (claim and takeover re-read) · tell_confirm_secs 15 (tell.sh delivery wait)
#   respawn_max 1 and respawn_window_hours 6 (tick's respawn budget) · bg_task_max_hours 6 · compact_above_pct 50
const_int() {
  local e v; e="FLEET_$(printf '%s' "$1" | tr 'a-z' 'A-Z')"; v="${!e:-}"
  case "$v" in "" | *[!0-9]*) v="$2" ;; esac
  printf '%s\n' "$v"
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

# caps_check <team> <repo> <agents>: dies naming the cap that starting <agents> more agents of <team> in <repo>
# would break (boot, unpark). Parked, Done and Retired rows never count, nor does <team>'s own.
#   max_agents      agents of other teams, plus <agents>
#   max_teams       teams with such an agent, plus this one (default 3). With `repos` set, only teams in a listed
#                   repo take a slot, so a tooling repo counts only when it is listed.
#   teams_per_repo  teams in the same repo, Parked ones included: a parked team still covers its repo (default 1)
# FLEET_FORCE=1 skips all three.
caps_check() {
  [ "${FLEET_FORCE:-}" != 1 ] || return 0
  local team="$1" repo="$2" need="$3" rows n cap
  rows="$("$FLEET_SCRIPTS/registry.sh" list | jq -c --arg t "$team" '[.[] | select(.tier != "Orchestrator" and .team != $t and .status != "Retired")]')"
  n="$(printf '%s' "$rows" | jq '[.[] | select(.status != "Done" and .status != "Parked")] | length')"; cap="$(max_agents)"
  [ $((n + need)) -le "$cap" ] ||
    die "$team needs $need agents; $n live, max_agents=$cap (park or retire a team, raise max_agents in $FLEET_CONFIG_DIR/config.toml, or set FLEET_FORCE=1)"
  n="$(printf '%s' "$rows" | jq --argjson r "$(config_list repos)" --arg me "$repo" '
    def listed($x): ($r | length) == 0 or any($r[]; . == $x or (split("/") | last) == ($x | split("/") | last));
    if listed($me) then [.[] | select(.status != "Done" and .status != "Parked" and listed(.repo // "")) | .team] | unique | length else -1 end')"
  cap="$(cfg_int max_teams 3)"
  [ "$n" -lt 0 ] || [ $((n + 1)) -le "$cap" ] ||
    die "$team would be team $((n + 1)); max_teams=$cap (park or retire a team, raise max_teams, or set FLEET_FORCE=1)"
  n="$(printf '%s' "$rows" | jq -r --arg me "$repo" '[.[] | select(.status != "Done" and .repo == $me) | .team] | unique | join(", ")')"
  cap="$(cfg_int teams_per_repo 1)"
  [ -z "$n" ] || [ $(($(printf '%s' "$n" | tr ',' '\n' | grep -c .) + 1)) -le "$cap" ] ||
    die "$repo already has a team ($n); teams_per_repo=$cap (parked teams count: they keep their repo)"
}

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
max_envs() { cfg_int max_envs 3; }

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

# config_check: warns, once per distinct set, about keys in config.toml that config.example.toml (the only list of
# keys, next to SKILL.md) does not know, and about a known number key whose value is not a whole number. The
# warned set is remembered in $FLEET_STATE_DIR/config.warned, so a loop tick says it once, not every five minutes.
# Reads names only; a value is never printed.
config_check() {
  local f="$FLEET_CONFIG_DIR/config.toml" ex="$FLEET_SKILL_DIR/config.example.toml" bad w
  [ -f "$f" ] && [ -f "$ex" ] || return 0
  bad="$(awk '
    function key(l,   k) { if (l ~ /^[[:space:]]*\[/) { k = l; sub(/^[[:space:]]*\[/, "", k); sub(/\].*/, "", k); return "[" k "]" }
                           if (l ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) { k = l; sub(/[[:space:]]*=.*/, "", k); gsub(/^[[:space:]]+/, "", k); return k } return "" }
    NR == FNR { k = key($0); if (k != "") { known[k] = 1; v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); if (v ~ /^[0-9]+/) isnum[k] = 1 } next }
    { k = key($0); if (k == "") next
      if (k ~ /^\[/) { insec = (k == "[context_window]"); if (!(k in known)) print "unknown " k; next }
      if (insec) next
      if (!(k in known)) { print "unknown " k; next }
      if (k in isnum) { v = $0; sub(/^[^=]*=[[:space:]]*/, "", v); if (v !~ /^[0-9]+([[:space:]]|#|$)/) print "unparsed " k } }' "$ex" "$f" | sort -u)"
  [ -n "$bad" ] || return 0
  w="$FLEET_STATE_DIR/config.warned"
  [ "$(cat "$w" 2>/dev/null || true)" != "$bad" ] || return 0
  mkdir -p "$FLEET_STATE_DIR" 2>/dev/null && printf '%s\n' "$bad" >"$w" 2>/dev/null || true
  warn "config.toml: $(printf '%s' "$bad" | sed 's/^unknown \(.*\)$/unknown key \1 (ignored)/; s/^unparsed \(.*\)$/\1 is not a whole number (default used)/' | paste -sd';' - | sed 's/;/; /g'). Keys: $ex"
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

# resume_brief <name> <expertise-file> <role brief>: what a respawned or unparked agent needs to carry on: its
# role brief, its assignment, the last report file of its role, `git status` and `git log` of its branch,
# and its open escalations (no screen text: it would come back as a user turn). A lead also gets
# the plan path (the planner's summary) and the team's rows. respawn.sh and unpark.sh share it; a Parked row
# reads "your team was parked", and one that was Done when parked is told to wait for its lead.
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
  if [ "$(printf '%s' "$row" | jq -r .status)" = Parked ]; then
    printf '%s\n\nYou are being unparked: your team was parked and its sessions closed. Carry on from where the record below says you were; do not start over.\nAssignment: %s\n' \
      "$role_brief" "$(printf '%s' "$row" | jq -r '.assignment // ""')"
    [ "$(printf '%s' "$row" | jq -r '.parked_from // ""')" != Done ] ||
      printf 'Your part was already done (%s); wait for your lead.\n' "$(printf '%s' "$row" | jq -r '[.outcome // "", .summary // ""] | map(select(. != "")) | join(": ")')"
  else
    printf '%s\n\nYou are being respawned: your previous session died. Carry on from where the record below says you were; do not start over.\nAssignment: %s\n' \
      "$role_brief" "$(printf '%s' "$row" | jq -r '.assignment // ""')"
  fi
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
# issue_done also takes outcome=, summary= and lessons= (what the agent itself wrote with done and debrief;
# cut at 40, 500 and 1000 characters), added only when given.
events_file() { printf '%s\n' "${FLEET_EVENTS:-$FLEET_STATE_DIR/events.jsonl}"; }
ev_log() {
  local type="$1" kv k v line f; shift
  local a_team="" a_name="" a_issue="" a_pr="" a_sha="" a_detail="" a_outcome="" a_summary="" a_lessons=""
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      team) a_team="$v" ;; name) a_name="$v" ;; issue) a_issue="$v" ;; pr) a_pr="$v" ;; sha) a_sha="$v" ;;
      detail) a_detail="${v:0:120}" ;;
      outcome) [ "$type" != issue_done ] || a_outcome="${v:0:40}" ;;
      summary) [ "$type" != issue_done ] || a_summary="${v:0:500}" ;;
      lessons) [ "$type" != issue_done ] || a_lessons="${v:0:1000}" ;;
    esac
  done
  line="$(jq -nc --arg at "${FLEET_NOW:-$(now)}" --arg type "$type" --arg team "$a_team" --arg name "$a_name" --arg issue "$a_issue" \
    --arg pr "$a_pr" --arg sha "$a_sha" --arg detail "$a_detail" --arg o "$a_outcome" --arg s "$a_summary" --arg l "$a_lessons" \
    '{at: $at, type: $type, team: $team, name: $name, issue: $issue, pr: $pr, sha: $sha, detail: $detail} | with_entries(if .value == "" then .value = null else . end)
     + ({outcome: $o, summary: $s, lessons: $l} | with_entries(select(.value != "")))')" || return 0
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

# tick_lock_take: take tick.sh's lock (the same mkdir directory, pid inside), so park, unpark and focus never run
# while a tick does: a tick in the middle of a park would see the closed panes as Zombies. A held lock is waited
# for, up to FLEET_LOCK_WAIT_SECS (default 30), then it returns 1 and nothing has changed. The lock is freed when
# the caller exits. FLEET_TICK_LOCK_HELD=1 means the caller's parent (tick.sh, focus.sh) already holds it.
tick_lock_take() {
  [ "${FLEET_TICK_LOCK_HELD:-}" != 1 ] || return 0
  local d="$FLEET_STATE_DIR/tick.lock" i=0 max; max=$((${FLEET_LOCK_WAIT_SECS:-30} * 10))
  mkdir -p "$FLEET_STATE_DIR"
  until mkdir "$d" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -le "$max" ] || return 1
    sleep 0.1
  done
  printf '%s\n' "$$" >"$d/pid"; date +%s >"$d/started"
  trap 'rm -rf "$FLEET_STATE_DIR/tick.lock"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM HUP
  export FLEET_TICK_LOCK_HELD=1
}

# focus_file: the focus focus.sh set ({team, at}); absent when there is none.
focus_file() { printf '%s\n' "$FLEET_STATE_DIR/focus.json"; }

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
  local maxs now_e; maxs=$(($(const_int bg_task_max_hours 6) * 3600))
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
