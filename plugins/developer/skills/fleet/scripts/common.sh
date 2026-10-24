#!/usr/bin/env bash
# Shared helpers for the /fleet scripts. Source it; don't run it.

FLEET_STATE_DIR="${FLEET_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/fleet}"
FLEET_CONFIG_DIR="${FLEET_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/fleet}"
# One state root: every path below comes from FLEET_STATE_DIR. There are no overrides for the registry, the
# inbox, the worktrees or the archive, so a stray FLEET_REGISTRY in an agent's environment cannot point a
# scratch run at the live registry. (Set FLEET_STATE_DIR to a scratch directory to work in a sandbox.)
FLEET_REGISTRY="$FLEET_STATE_DIR/fleet.json"
FLEET_WORKTREES="$FLEET_STATE_DIR/worktrees"
FLEET_INBOX="$FLEET_STATE_DIR/escalations.jsonl"
FLEET_ARCHIVE="$FLEET_STATE_DIR/fleet-archive.json"
FLEET_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_SKILL_DIR="$(dirname "$FLEET_SCRIPTS")"

# The suite never touches the live fleet. With FLEET_TEST=1, any script that sources this file dies when
# FLEET_STATE_DIR (the root of every path) is the live default, computed from the real HOME
# (FLEET_REAL_HOME, captured by the suite before it overrides HOME).
if [ "${FLEET_TEST:-}" = 1 ]; then
  _live="${FLEET_REAL_HOME:-$HOME}/.local/state/fleet"
  case "$FLEET_STATE_DIR" in
    "$_live" | "$_live"/*) printf 'fleet: FLEET_TEST=1 but FLEET_STATE_DIR (%s) is the live fleet state (%s); refusing\n' "$FLEET_STATE_DIR" "$_live" >&2; exit 1 ;;
  esac
  unset _live
fi

# die <what failed> [the one next step]: the message on stderr, and exit 1. With a next step the line is
# "fleet: <what failed>. <next step>." (the error form of references/output.md, which the dispatcher relays).
die() {
  if [ $# -ge 2 ] && [ -n "$2" ]; then printf 'fleet: %s. %s.\n' "${1%.}" "${2%.}" >&2; else printf 'fleet: %s\n' "$*" >&2; fi
  exit 1
}
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
    and ((has("notes") | not) or (.notes | type == "array"))
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
# herdr_integration_ok: herdr's Claude integration (its hooks) is installed and current, so `agent get` reports a
# Claude agent's real state and state_change_seq. tell.sh and status.sh rely on those and read no screen text for
# state (references/herdr-patterns.md). `herdr integration status` says "claude: current" when it is; UNVERIFIED
# beyond that line.
herdr_integration_ok() { hd integration status 2>/dev/null | grep -q '^claude: current'; }

require_herdr() {
  need herdr
  if [ -z "${FLEET_SESSION:-}" ] && [ "${HERDR_ENV:-}" != "1" ]; then
    die "run the Orchestrator inside a herdr pane (HERDR_ENV=1), or set FLEET_SESSION=<name>"
  fi
}

# const_int <NAME> <default>: an internal timing or limit. It is a constant, not a setting: only the
# FLEET_<NAME> environment variable (upper case) overrides it, and the tests use that.
const_int() {
  local v; eval "v=\${FLEET_$1:-}"
  case "$v" in "" | *[!0-9]*) v="$2" ;; esac
  printf '%s\n' "$v"
}

# cfg_int <key> <default>: an integer from config.toml (key = value).
cfg_int() {
  local v=""
  [ -f "$FLEET_CONFIG_DIR/config.toml" ] &&
    v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$FLEET_CONFIG_DIR/config.toml" | head -1)"
  printf '%s\n' "${v:-$2}"
}
# permission_mode: the Claude Code --permission-mode every agent starts in. FLEET_PERMISSION_MODE
# wins, then config.toml, default auto. A pane that starts in a stricter mode blocks on the first
# permission prompt and sits idle until someone enables auto.
permission_mode() {
  local v="${FLEET_PERMISSION_MODE:-}"
  [ -n "$v" ] || v="$(cfg_str permission_mode auto)"
  check_permission_mode "${v:-auto}"
}
# check_permission_mode <mode>: prints the mode, or dies for one that turns permission checks off. No setting
# allows bypassPermissions (or --dangerously-skip-permissions): agents always run with checks on.
check_permission_mode() {
  case "$1" in
    bypassPermissions | *dangerously* | *skip-permissions*) die "permission mode '$1' turns permission checks off; fleet agents never run that way" ;;
  esac
  printf '%s\n' "$1"
}

# max_teams: live teams at once (Parked teams do not count), default 3.
max_teams() { cfg_int max_teams 3; }

# min_free_gb (boot refuses below it, default 40; 0 disables) and warn_free_gb (status marks LOW and the loop alerts below it, default 75).
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

# Disk the fleet's tools fill (tick's prune, env.sh down, the status disk line). FLEET_DOCKER and FLEET_GO name the
# docker and go binaries (the tests point them at stubs).
# anon_volume <name>: an anonymous docker volume's name is 64 hex characters; a named volume's never is.
anon_volume() { case "$1" in *[!0-9a-f]* | "") return 1 ;; esac; [ "${#1}" = 64 ]; }
# du_gb <dir>: its size in whole GB, 0 when it is missing.
du_gb() { if [ -d "$1" ]; then du -sk "$1" 2>/dev/null | awk '{printf "%d\n", $1 / 1048576}'; else echo 0; fi; }
# docker_reclaimable_gb: what `docker system df` says can be reclaimed, summed, in whole GB (0 when it says nothing).
docker_reclaimable_gb() {
  "${FLEET_DOCKER:-docker}" system df --format '{{.Reclaimable}}' 2>/dev/null | awk '
    { n = $1 + 0; u = $1; sub(/^[0-9.]+/, "", u)
      t += n * ((u == "TB") ? 1024 : (u == "GB") ? 1 : (u == "MB") ? 1 / 1024 : (u == "kB" || u == "KB") ? 1 / 1048576 : 0) }
    END { printf "%d\n", t }'
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

# config_pairs <file> [commented]: the top-level keys of a TOML file as "key<TAB>value" lines, plus a "[table]<TAB>"
# line for each table header (the keys inside a table are not listed). With a 2nd argument, commented
# lines (# key = value) count too: that is how config.example.toml lists the keys that have no default worth setting.
config_pairs() {
  awk -v c="${2:-}" '
    /^[[:space:]]*\[[A-Za-z_]+\]/ { t = $0; gsub(/[][[:space:]]/, "", t); print "[" t "]\t"; intbl = 1; next }
    intbl { next }
    { l = $0; if (c != "") sub(/^[[:space:]]*#+[[:space:]]*/, "", l)
      if (match(l, /^[a-z_]+[[:space:]]*=[[:space:]]*/)) { k = substr(l, 1, RLENGTH); v = substr(l, RLENGTH + 1)
        sub(/[[:space:]]*=[[:space:]]*$/, "", k); print k "\t" v } }' "$1"
}

# config_warn_unknown: config.example.toml is the only list of keys. One warning per key in config.toml that the
# example does not list (a typo, or a key an older fleet read), and one per key whose value is not the kind the
# example shows (a number, a quoted string, an array): the setting is ignored either way.
config_warn_unknown() {
  local f="$FLEET_CONFIG_DIR/config.toml" ex="$FLEET_SKILL_DIR/config.example.toml" k v want got
  [ -f "$f" ] && [ -f "$ex" ] || return 0
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] || continue
    want="$(config_pairs "$ex" 1 | awk -F'\t' -v k="$k" '$1 == k { print $2; found = 1; exit } END { if (!found) print "?" }')"
    if [ "$want" = "?" ]; then warn "unknown key '$k' in $f (ignored; the keys are listed in config.example.toml)"; continue; fi
    case "$want" in [0-9]*) want=number ;; '"'*) want=string ;; '['*) want=array ;; *) want="" ;; esac
    case "$v" in [0-9]*) got=number ;; '"'*) got=string ;; '['*) got=array ;; *) got=other ;; esac
    [ -z "$want" ] || [ "$got" = "$want" ] || warn "key '$k' in $f is not a $want (ignored)"
  done < <(config_pairs "$f")
}

# live_team_count [exclude-team]: teams with a live row (Parked, Done and Retired rows are not live), which is what
# max_teams caps. When `repos` is set in config.toml only the teams on a listed repo count: a tooling repo
# takes a slot only when it is listed.
live_team_count() {
  "$FLEET_SCRIPTS/registry.sh" list --live | jq -r --arg x "${1:-}" --argjson repos "$(config_list repos)" '
    [.[] | select(.tier != "Orchestrator" and .team != $x)
      | select(($repos | length) == 0 or ((.repo // "") as $r | any($repos[]; . == $r or (split("/") | last) == ($r | split("/") | last))))
      | .team] | unique | length'
}
# teams_per_repo: live teams on one repo, default 1.
teams_per_repo() { cfg_int teams_per_repo 1; }
# teams_on_repo <repo> [exclude-team]: the live teams other than exclude-team that work <repo>, one per line.
teams_on_repo() {
  "$FLEET_SCRIPTS/registry.sh" list --live | jq -r --arg r "$1" --arg x "${2:-}" \
    '[.[] | select(.tier != "Orchestrator" and .team != $x and (.repo // "") == $r) | .team] | unique[]'
}

# Agent names must match herdr's rule: [a-z][a-z0-9_-]{0,31}.
agent_name() {
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
  case "$n" in [a-z]*) ;; *) n="f-$n" ;; esac
  printf '%s\n' "${n:0:32}"
}

# max_envs: test clusters at once, default 3.
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

Fleet rules for $name.$x Stay on this one task. If you notice unrelated work, run \`$registry note $name discovered \"<what>\"\` instead of doing it. If you need a decision you cannot make, run \`$registry escalate $name P1 \"<question>\" \"<recommended option>\" \"<other option>\"\` (options optional, your recommendation first) and wait. P1 is only for a decision the user must make; \"PR ready\" goes through done, not an escalation. If you stop to wait for instructions, first run \`$registry set $name status=Idle\`. When your part is finished: push your \`fleet/<slug>\` branch if you have one (with \`--force-with-lease\`, never to the default branch), then run \`$registry done $name --outcome <Shipped|Partial|Failed> --summary \"<one line>\"\`, then stop. Going idle without that command marks you Stalled."
}

# build_brief <name> <expertise-file> <text>: a brief plus the fleet rules and the house rules.
# build_brief --resume <name> <expertise-file> <role brief>: the brief for a respawned agent.
# Either way the house rules (rules/house.md, then the repo's own .claude/fleet-rules.md) come last, once.
build_brief() {
  if [ "${1:-}" = "--resume" ]; then shift; resume_brief "$@"; house_rules "$1"; return; fi
  printf '%s%s' "$3" "$(contract "$1" "$2")"
  house_rules "$1"
}

# house_rules <agent row name>: the fleet's house rules, then the agent's repository's .claude/fleet-rules.md
# when it has one. The repository is the row's `repo`; without a row only the fleet's rules are printed.
house_rules() {
  local repo f
  repo="$("$FLEET_SCRIPTS/registry.sh" get "$1" 2>/dev/null | jq -r '.repo // ""' 2>/dev/null)" || repo=""
  printf '\n\n'
  cat "$FLEET_SKILL_DIR/rules/house.md" 2>/dev/null || warn "house rules missing: $FLEET_SKILL_DIR/rules/house.md"
  f="$repo/.claude/fleet-rules.md"
  if [ -n "$repo" ] && [ -f "$f" ]; then printf '\nRepository rules (%s):\n' "$f"; cat "$f"; fi
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
  printf '%s\n\nYou are being respawned: %s. Carry on from where the record below says you were; do not start over.\nAssignment: %s\n' \
    "$role_brief" "${FLEET_RESUME_WHY:-your previous session died}" "$(printf '%s' "$row" | jq -r '.assignment // ""')"
  [ -z "$report" ] || printf 'Your last report file: %s\n' "$report"
  [ -z "$gl" ] || printf '\ngit log -5 --oneline:\n%s\n' "$gl"
  printf '\ngit status --short:\n%s\n' "${gs:-(clean)}"
  [ -z "$esc" ] || printf '\nYour open escalations:\n%s\n' "$esc"
  [ -z "$plan" ] || printf '\nThe plan (from the planner summary): %s\n' "$plan"
  [ -z "$rows" ] || printf '\nThe team:\n%s\n' "$rows"
  contract "$name" "$ex"
}

# notify <title> <body> [sound] [alert]: the one notification path. The herdr notification shows when herdr is
# reachable; with a 4th argument "alert" the optional config `alert_cmd` also runs, with the body as its one
# argument (a script that sends an iMessage via osascript, or a Pushover or ntfy curl: see the README). A failure of either is logged on stderr, never
# hidden, and never fails the caller.
notify() {
  local err cmd
  if { [ "${HERDR_ENV:-}" = "1" ] || [ -n "${FLEET_SESSION:-}" ]; } && command -v herdr >/dev/null 2>&1; then
    if ! err="$(hd notification show "$1" --body "$2" --sound "${3:-done}" 2>&1 >/dev/null)"; then
      warn "notification failed: $1: $(printf '%s' "$err" | head -1)"
    fi
  fi
  if [ "${4:-}" = alert ]; then
    cmd="$(cfg_str alert_cmd '')"
    if [ -n "$cmd" ] && ! err="$(/bin/sh -c "$cmd \"\$1\"" fleet-alert "$2" 2>&1 >/dev/null)"; then
      warn "alert_cmd failed: $(printf '%s' "$err" | head -1)"
    fi
  fi
  return 0
}

# api_error_detail <transcript>: "login expired" or "API error" when the newest assistant line of the
# transcript is an API error message (isApiErrorMessage), else nothing. Lines are parsed one at a time;
# a bad line is skipped. UNVERIFIED: the line shape (.type == "assistant", .isApiErrorMessage, the text
# in .message.content[].text) is what Claude Code writes today (DEV-368).
api_error_detail() {
  [ -n "$1" ] && [ -f "$1" ] || return 0
  tail -n 40 "$1" 2>/dev/null | jq -Rr 'fromjson? // empty | select(type == "object" and .type == "assistant")
      | if .isApiErrorMessage == true then
          ([.message.content? | if type == "array" then .[] | select(type == "object") | .text? // empty elif type == "string" then . else empty end] | join(" ")) as $t
          | (if ($t | test("login|log in|authenticat|expired|401|unauthorized"; "i")) then "login expired" else "API error" end)
        else "" end' 2>/dev/null | tail -n 1 || true
}

# --- the event log: one append-only JSON line per thing that happened ---------------------------------
# ev_log <type> [team=T] [name=N] [issue=I] [pr=URL] [sha=S] [detail=SHORT REASON]
# {at, type, team, name, issue, pr, sha, detail}; empty values are null. detail is a short reason (cut
# at 120 characters), never brief text and never the Linear key; any other key is ignored. The one exception is
# issue_done, which also takes outcome, summary and lessons (what a debrief reads after a row is cleared). One `>>`
# write. A write that fails is a warning, never a failure of the caller.
events_file() { printf '%s\n' "$FLEET_STATE_DIR/events.jsonl"; } # no override: every path comes from FLEET_STATE_DIR
ev_log() {
  local type="$1" kv k v line f; shift
  local a_team="" a_name="" a_issue="" a_pr="" a_sha="" a_detail="" a_outcome="" a_summary="" a_lessons=""
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in
      team) a_team="$v" ;; name) a_name="$v" ;; issue) a_issue="$v" ;; pr) a_pr="$v" ;; sha) a_sha="$v" ;;
      detail) a_detail="${v:0:120}" ;;
      outcome) a_outcome="${v:0:40}" ;; summary) a_summary="${v:0:300}" ;; lessons) a_lessons="${v:0:2000}" ;;
    esac
  done
  line="$(jq -nc --arg at "${FLEET_NOW:-$(now)}" --arg type "$type" --arg team "$a_team" --arg name "$a_name" --arg issue "$a_issue" \
    --arg pr "$a_pr" --arg sha "$a_sha" --arg detail "$a_detail" --arg outcome "$a_outcome" --arg summary "$a_summary" --arg lessons "$a_lessons" \
    '{at: $at, type: $type, team: $team, name: $name, issue: $issue, pr: $pr, sha: $sha, detail: $detail}
      + (if $type == "issue_done" then {outcome: $outcome, summary: $summary, lessons: $lessons} else {} end)
      | with_entries(if .value == "" then .value = null else . end)')" || return 0
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
  "$FLEET_GH" pr view "$1" --json state,mergeable,statusCheckRollup,headRefOid,body,url,isDraft
}

# PR_DEFS: jq definitions for whether a PR is ready to merge, the one rule tick's pr_ready and the merge queue
# share. Input: the PR as forge_pr_json prints it.
#   pr_noci_ok($noci; $repo; $url)  the repo is in no_pr_ci ($noci: config_list no_pr_ci), by name, owner/name or path
#   pr_ci($nociok)                  green, pending, red, none (no checks, and the repo needs none) or unknown (no checks)
#   pr_held                         the body asks to hold it: DO NOT MERGE, merge order, before/after, merge
#                                   after/before, stacked on (a stacked child must not go ready before its parent)
#   pr_missing($signoff; $nociok)   what keeps it from being ready, [] when it is ready: its state when not open,
#                                   "no sign-off", "signed <sha7> ≠ head", "CI pending", "CI red", "no CI checks",
#                                   "conflicting", "mergeable unknown" (GitHub still computing: never read as
#                                   conflicting), "draft", "held". Ready: open, the tester's signed SHA is the head
#                                   (a short SHA counts as the full one it starts), CI green or none, mergeable, not a
#                                   draft, not held.
PR_DEFS='def pr_noci_ok($noci; $repo; $url): ($repo | split("/") | last) as $base
    | ($url | sub("^https?://[^/]+/"; "") | sub("/(pull|merge_requests)/.*$"; "")) as $slug
    | (($noci | index($base)) != null or ($noci | index($slug)) != null or ($noci | index($repo)) != null);
  def pr_ci($nociok): ((.statusCheckRollup // []) | map(if .__typename == "StatusContext" or (.conclusion == null and .state != null)
        then (if .state == "SUCCESS" then "ok" elif (.state == "PENDING" or .state == "EXPECTED") then "pending" else "red" end)
        else (if .status != "COMPLETED" then "pending" elif (.conclusion | IN("SUCCESS", "NEUTRAL", "SKIPPED")) then "ok" else "red" end) end)) as $cs
    | if ($cs | length) == 0 then (if $nociok then "none" else "unknown" end)
      elif ($cs | index("red")) then "red" elif ($cs | index("pending")) then "pending" else "green" end;
  def pr_held: (.body // "") | test("DO NOT MERGE|merge order|before/after|merge (after|before)|stacked on"; "i");
  def pr_missing($signoff; $nociok): (($signoff // "") | ascii_downcase) as $so | ((.headRefOid // "") | ascii_downcase) as $head
    | pr_ci($nociok) as $ci
    | [(if .state != "OPEN" then ((.state // "unknown") | ascii_downcase) else empty end),
       (if $so == "" then "no sign-off" elif ($head != "" and ($head | startswith($so))) | not then "signed \($so[0:7]) ≠ head" else empty end),
       (if $ci == "pending" then "CI pending" elif $ci == "red" then "CI red" elif $ci == "unknown" then "no CI checks" else empty end),
       (if .mergeable == "CONFLICTING" then "conflicting" elif .mergeable != "MERGEABLE" then "mergeable unknown" else empty end),
       (if .isDraft == true then "draft" else empty end),
       (if pr_held then "held" else empty end)];
  '

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


# plugin_version: the version of the plugin these scripts belong to (its plugin.json).
plugin_version() { jq -r '.version // ""' "$FLEET_SKILL_DIR/../../.claude-plugin/plugin.json" 2>/dev/null || true; }
# installed_version: the newest developer plugin version installed in Claude Code's plugin cache
# (FLEET_INSTALLED_VERSION wins, for tests); empty when none is found.
installed_version() {
  if [ -n "${FLEET_INSTALLED_VERSION:-}" ]; then printf '%s\n' "$FLEET_INSTALLED_VERSION"; return 0; fi
  local d v best=""
  for d in "${HOME:-/nonexistent}"/.claude/plugins/cache/*/developer/*/; do
    [ -d "$d" ] || continue
    v="$(basename "$d")"
    case "$v" in *[!0-9.]* | "") continue ;; esac
    if [ -z "$best" ] || version_gt "$v" "$best"; then best="$v"; fi
  done
  printf '%s\n' "$best"
}
# version_gt <a> <b>: a is a newer dotted version than b (numeric per part; BSD and GNU tools alike).
version_gt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    na = split(a, x, "."); nb = split(b, y, "."); n = (na > nb ? na : nb)
    for (i = 1; i <= n; i++) { p = x[i] + 0; q = y[i] + 0; if (p > q) exit 0; if (p < q) exit 1 }
    exit 1 }'
}
# version_switch_check <rows JSON array> <who>: a restart starts each agent on the newest installed plugin, so when
# that is newer than a row's plugin_version the restart would switch versions, which waits for the user's go (tick
# asks with stale_version). Exit 5, naming both versions, unless FLEET_VERSION_OK=1 (next.sh, respawn.sh --restart).
version_switch_check() {
  [ "${FLEET_VERSION_OK:-}" != 1 ] || return 0
  local iv v old=""
  iv="$(installed_version)"; [ -n "$iv" ] || return 0
  while IFS= read -r v; do
    [ -n "$v" ] && version_gt "$iv" "$v" || continue
    if [ -z "$old" ] || version_gt "$old" "$v"; then old="$v"; fi
  done < <(jq -r '.[] | .plugin_version // empty' <<<"$1")
  [ -n "$old" ] || return 0
  printf 'fleet: %s runs plugin %s and %s is installed, so a restart would switch it to %s. Ask the user, then run it again with FLEET_VERSION_OK=1.\n' "$2" "$old" "$iv" "$iv" >&2
  exit 5
}

# transcript_bg_running <transcript file>: how many background tasks the agent has running: tool_use blocks
# with input.run_in_background == true, or named Monitor, whose task id (in the matching tool_result text:
# "...running in background with ID: <id>" or "Monitor started ... task <id>") has no later
# <task-notification><task-id><id></task-id> line and no KillShell or TaskStop tool_use naming it
# (input.shell_id or input.task_id), and that started less than bg_task_max_hours (default 6) ago (a task killed
# without either would otherwise count until the session ends). Observed shape of Claude Code transcripts, not a
# documented contract: UNVERIFIED for stability. Unreadable: 0.
transcript_bg_running() {
  [ -r "$1" ] || { echo 0; return 0; }
  local maxs now_e; maxs=$(($(const_int BG_TASK_MAX_HOURS 6) * 3600))
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
    | ([($L[] | select(.type == "user") | (.message.content | body) | select(contains("<task-notification>"))
        | scan("<task-id>([A-Za-z0-9_-]+)</task-id>") | .[0]),
        ($L[] | select(.type == "assistant") | (.message.content // [])[]?
        | select(type == "object" and .type == "tool_use" and (.name == "KillShell" or .name == "TaskStop"))
        | (.input.task_id? // .input.shell_id?) | select(type == "string"))] | unique) as $ended
    | [$starts[] | . as $s | ($results | map(select(.tool == $s.tool)) | first | .text // "") as $x
        | ($x | (try capture("running in background with ID: (?<id>[A-Za-z0-9_-]+)").id catch null)
            // (try capture("Monitor started[^\n]*?task (?<id>[A-Za-z0-9_-]+)").id catch null)) as $id
        | select($id != null and (($ended | index($id)) == null) and ($s.at == null or ($now - $s.at) <= $max))] | length' "$1" 2>/dev/null || echo 0
}


# report_dir: where fleet reports go: reports/ under the Orchestrator's cwd when its row records one (registry.sh
# orchestrator here), else reports/ in the state dir (a launchd job's cwd is /).
report_dir() {
  local d; d="$("$FLEET_SCRIPTS/registry.sh" get orchestrator 2>/dev/null | jq -r '.cwd // ""' 2>/dev/null)" || d=""
  if [ -n "$d" ] && [ -d "$d" ]; then printf '%s/reports\n' "$d"; else printf '%s/reports\n' "$FLEET_STATE_DIR"; fi
}

# --- replies ---------------------------------------------------------------------------------------------
# Every user-facing reply has one shape, listed in references/output.md and pinned by scripts/test/golden/: the
# team table, the agent table, the decision form, the error form and one line per command or wake (render_line).
# Scripts print through these functions, never with a printf of their own, so every machine shows the same thing
# and the Orchestrator relays it as it is.

# reply <block>...: a reply made of blocks (a command's line, the team table, the merge queue, a footer line), the
# empty ones left out, with exactly one blank line between two. Markdown ends a table only at a blank line, and runs
# adjacent lines together into one paragraph.
reply() {
  local b n=0
  for b in "$@"; do
    [ -n "$b" ] || continue
    [ "$n" = 0 ] || printf '\n'
    printf '%s\n' "$b"; n=1
  done
}

# RENDER_DEFS: jq definitions the tables share. md makes text safe in a table cell; issue_cell and pr_cell give
# [DEV-1](url) and [repo #N](url) (or the bare key, or -); word is the one-word state of an agent status; rank
# orders those words, worst last; mark is a word's symbol and group the summary line's name for it (references/
# output.md, "symbols": plain Unicode, never emoji); marked is "<symbol> <word>"; sev puts P0 and P1 in bold;
# ago($now) turns an ISO time into "5m ago", "3h ago" or "2d ago".
RENDER_DEFS='def md: tostring | gsub("[\r\n\t]+"; " ") | gsub("\\|"; "\\|");
  def issue_cell($k; $u): if ($k // "") == "" then "-" elif ($u // "") == "" then $k else "[\($k)](\($u))" end;
  def pr_cell($u): if ($u // "") == "" then "-"
    else ([$u | capture("^https?://[^/]+/[^/]+/(?<r>[^/]+)/(pull|merge_requests)/(?<n>[0-9]+)")] | first) as $m
      | if $m == null then "[PR](\($u))" else "[\($m.r) #\($m.n)](\($u))" end end;
  def word: {"Working": "Working", "Booting": "Working", "Idle": "Idle", "Needs input": "Waiting", "Stalled": "Stalled",
    "Zombie": "Zombie", "Failed": "Failed", "Done": "Done", "Parked": "Parked"}[.] // "Idle";
  def rank: {"Parked": 0, "Done": 1, "Idle": 2, "Working": 3, "Waiting": 4, "Stalled": 5, "Failed": 6, "Zombie": 7}[.] // 2;
  def mark: {"Working": "●", "Idle": "○", "Waiting": "◐", "Stalled": "✗", "Failed": "✗", "Zombie": "✗", "Parked": "‖", "Done": "✓"}[.] // "○";
  def group: {"Working": "working", "Idle": "idle", "Waiting": "waiting", "Stalled": "blocked", "Failed": "blocked",
    "Zombie": "blocked", "Parked": "parked", "Done": "done"}[.] // "idle";
  def marked: "\(mark) \(.)";
  def sev: if . == "P0" or . == "P1" then "**\(.)**" else . end;
  def ago($now): if (. // "") == "" then "-"
    else ([(($now - (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) / 60 | floor), 0] | max) as $m
      | if $m < 60 then "\($m)m ago" elif $m < 2880 then "\($m / 60 | floor)h ago" else "\($m / 1440 | floor)d ago" end end;
  '

# issue_link <key> [url] and pr_link <url>: the Issue and PR cells as a reply line writes them.
issue_link() { if [ -z "${1:-}" ]; then return 0; elif [ -n "${2:-}" ]; then printf '[%s](%s)' "$1" "$2"; else printf '%s' "$1"; fi; }
pr_link() { jq -rn --arg u "${1:-}" "$RENDER_DEFS"'pr_cell($u)'; }
# roles_line <team>: each agent's role and a mark, lead first: "lead ✓ builder ✗ (did not start)".
roles_line() {
  "$FLEET_SCRIPTS/registry.sh" list --team "$1" | jq -r '[.[] | select(.status != "Retired")] | sort_by(if .tier == "Lead" then 0 else 1 end)
    | map((.name | split("/")[1:] | join("/")) + " " + (if .status == "Failed" then "✗ (brief not delivered)"
        elif .status == "Zombie" then "✗ (did not start)" else "✓" end)) | join(" ")'
}

# render_table [team...]: the team table of the registry as it stands (no herdr call): the summary line ("3 teams ·
# ● 2 working · ✗ 1 blocked"), then one row per team that has a row not yet Retired, or only the teams named, then
# "Waiting on you: ..." when a P0 or P1 is open, a blank line between the three (reply). "No teams." when there is
# none. State is the worst agent state, its symbol and one word (Parked when the team is parked); Needs you is the
# team's most severe open escalation, else what its state needs, else -.
render_table() {
  local rows esc only
  rows="$("$FLEET_SCRIPTS/registry.sh" list)" || return 1
  esc="$("$FLEET_SCRIPTS/registry.sh" escalations --open --not-retired 2>/dev/null)" || esc='[]'
  only="$(printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != ""))')"
  jq -rn --argjson rows "$rows" --argjson esc "$esc" --argjson only "$only" "$RENDER_DEFS"'
    def shown: ($only | length) == 0 or (. as $t | $only | index($t) != null);
    [$rows[] | select(.tier != "Orchestrator" and .status != "Retired" and (.team // "") != "" and (.team | shown))]
    | group_by(.team) | map(. as $g | $g[0].team as $t
      | ([$esc[] | select(.team == $t)] | sort_by({"P0": 0, "P1": 1, "P2": 2}[.severity] // 3) | first) as $e
      | (if any($g[]; .status == "Parked") then "Parked" else ($g | map(.status | word) | sort_by(rank) | last) end) as $state
      | ($g | map(.pr // "") | map(select(. != "")) | first // "") as $pr
      | {team: $t,
         issue: issue_cell(($g | map(.issue // "") | map(select(. != "")) | first // ""); ($g | map(.issue_url // "") | map(select(. != "")) | first // "")),
         pr: pr_cell($pr), state: $state,
         needs: (if $e != null then "\($e.severity | sev): \($e.message | .[0:60])"
           elif any($g[]; .status == "Needs input") then ($g | map(.status_detail // "") | map(select(. != "")) | first // "answer its prompt")
           elif $state == "Zombie" then "agent gone: respawn or retire"
           elif $state == "Stalled" then "ask for its done step"
           elif $state == "Failed" then "brief not delivered"
           elif $state == "Done" then (if $pr != "" then "merge the PR" else "retire the team" end)
           else "-" end)}) as $t
    | if ($t | length) == 0 then "No teams." else
        [([$t | length | "\(.) team\(if . == 1 then "" else "s" end)"]
          + ([$t[].state] as $s | ["Working", "Idle", "Waiting", "Stalled", "Parked", "Done"]
            | map(. as $w | group as $g | ([$s[] | select(group == $g)] | length) as $n | select($n > 0) | "\($w | mark) \($n) \($g)"))
          | join(" · ")),
         (["| Team | Issue | PR | State | Needs you |", "|---|---|---|---|---|",
           ($t[] | "| \(.team | md) | \(.issue) | \(.pr) | \(.state | marked) | \(.needs | md) |")] | join("\n")),
         ([$esc[] | select((.severity | IN("P0", "P1")) and (.team | shown)) | "\(.name) \(.severity | sev): \(.message | .[0:60] | md)"]
          | if length > 0 then "Waiting on you: " + join("; ") else empty end)]
        | join("\n\n")
      end'
}

# render_agent_table <team>: | Agent | Role | State | Model | Last action |, the lead first. The last action is the
# agent's newest event in events.jsonl (type and age), else when its row last changed. Returns 1 for no such team.
render_agent_table() {
  local rows ev f
  rows="$("$FLEET_SCRIPTS/registry.sh" list --team "$1" | jq -c '[.[] | select(.status != "Retired" and .tier != "Orchestrator")]')" || return 1
  [ "$(jq length <<<"$rows")" != 0 ] || return 1
  f="$(events_file)"; ev='{}'
  [ ! -s "$f" ] || ev="$(jq -Rn --arg t "$1" '[inputs | fromjson? // empty | select(type == "object" and .team == $t and (.name // "") != "")]
    | group_by(.name) | map({key: .[0].name, value: (max_by(.at) | {type, at})}) | from_entries' "$f")"
  jq -rn --argjson rows "$rows" --argjson ev "$ev" --argjson now "$(jq -rn --arg t "${FLEET_NOW:-$(now)}" '$t | fromdateiso8601')" "$RENDER_DEFS"'
    "| Agent | Role | State | Model | Last action |", "|---|---|---|---|---|",
    ($rows | sort_by((if .tier == "Lead" then 0 else 1 end), .name)[] | ($ev[.name] // null) as $e
      | "| \(.name | md) | \(.name | split("/")[1:] | join("/") | md) | \(.status | word | marked) | \(if (.model // "") == "" then "-" else (.model | md) end) | \(if $e != null then "\($e.type) \($e.at | ago($now))" else "updated \(.updated_at | ago($now))" end) |")'
}

# render_escalations <escalations JSON (registry.sh escalations)>: | Id | Severity | Agent | Question | Age |, oldest
# first, a resolved one marked; "No escalations." when there is none.
render_escalations() {
  jq -rn --argjson e "$1" --argjson now "$(jq -rn --arg t "${FLEET_NOW:-$(now)}" '$t | fromdateiso8601')" "$RENDER_DEFS"'
    if ($e | length) == 0 then "No escalations." else
      "| Id | Severity | Agent | Question | Age |", "|---|---|---|---|---|",
      ($e | sort_by(.at)[] | "| \(.id) | \(.severity | sev) | \(.name | md) | \(.message | .[0:80] | md)\(if .resolved_at != null then " (resolved)" else "" end) | \(.at | ago($now)) |")
    end'
}

# render_queue <queue.sh JSON>: "Merge in this order:" and | # | PR | Issue | Why this order | After merge |, each
# PR marked ✓ ("Merge in this order: none ready." when nothing is), then "Not ready: [repo #N](url) ✗ <missing> · ✗
# ..." per open PR that is not, then the queue's notes, a blank line between any two (reply). Nothing at all when
# no PR is open.
render_queue() {
  jq -r 'if (.ready | length) == 0 and (.not_ready | length) == 0 then empty else
      [(if (.ready | length) == 0 then "Merge in this order: none ready." else "Merge in this order:" end),
       (if (.ready | length) == 0 then empty else
         (["| # | PR | Issue | Why this order | After merge |", "|---|---|---|---|---|",
           (.ready[] | "| \(.n) | ✓ \(.pr) | \(.issue) | \(.why) | \(.after) |")] | join("\n")) end),
       (.not_ready[] | "Not ready: \(.pr) \(.missing | map("✗ " + .) | join(" · "))"),
       (.notes[] | "\(.).")]
      | join("\n\n")
    end' <<<"$1"
}

# render_metrics <metrics.sh --json array>: | Week | Issues shipped | PRs | Rework | Median cycle |, one row per ISO
# week of the PRs' end (merge, else now): issues with a merged PR, PRs, rework rounds, the median minutes to ready.
render_metrics() {
  jq -rn --argjson p "$1" '
    def wk: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | gmtime | strftime("%G-W%V");
    def dur: if . == null then "-" elif . < 60 then "\(.)m" else "\(. / 60 | floor)h \(. % 60)m" end;
    def median: sort | if length == 0 then null else .[(length - 1) / 2 | floor] end;
    "| Week | Issues shipped | PRs | Rework | Median cycle |", "|---|---|---|---|---|",
    ($p | map(. + {week: ((.merged_at // .end_at) | wk)}) | group_by(.week)[]
      | "| \(.[0].week) | \([.[] | select(.merged_at != null) | .issue // empty] | unique | length) | \(length) | \([.[].rework_rounds] | add // 0) | \([.[].ready_minutes // empty] | median | dur) |")'
}
# render_metrics_prs <metrics.sh --json array>: the report's per-PR table.
render_metrics_prs() {
  jq -rn --argjson p "$1" "$RENDER_DEFS"'
    "| PR | Team | Issue | Ready (min) | Rework | Stalls | Missed | Tokens |", "|---|---|---|---|---|---|---|---|",
    ($p[] | "| \(pr_cell(.pr)) | \(.team // "-" | md) | \(.issue // "-" | md) | \(.ready_minutes // "-") | \(.rework_rounds) | \(.stalls) | \(.missed_messages) | \(.tokens) |")'
}

# render_decision <P0|P1|P2> <team/role> <question> [option...]: the decision form, P0 and P1 in bold. The first
# option is the recommended one; with no options it is the question line alone.
render_decision() {
  local p="$1" who="$2" q="$3" letters=ABCDEFGHIJ i=0 o opts="" reply=""; shift 3
  case "$p" in P0 | P1) p="**$p**" ;; esac
  printf '%s %s: %s\n' "$p" "$who" "$q"
  [ $# -gt 0 ] || return 0
  for o in "$@"; do
    [ "$i" -lt 10 ] || break
    if [ "$i" = 0 ]; then opts="${letters:0:1}) $o (recommended)"; else opts="$opts · ${letters:$i:1}) $o"; fi
    i=$((i + 1))
  done
  case "$i" in
    1) reply="A" ;;
    *) reply="$(printf '%s' "${letters:0:$((i - 1))}" | sed 's/./&, /g; s/, $//') or ${letters:$((i - 1)):1}" ;;
  esac
  printf '%s\nReply %s.\n' "$opts" "$reply"
}

# render_error <command> <what failed> [next step]: the error form, "<command>: <what failed>. <next step>."; the
# next step defaults to "Run fleet help <command>".
render_error() { local n="${3:-Run fleet help $1}"; printf '%s: %s. %s.\n' "$1" "${2%.}" "${n%.}"; }

# render_line <entry> key=value...: one line of the catalogue (references/output.md), filled from the named values.
render_line() {
  local e="$1" kv k L_cause="" L_next="" L_what=""; shift
  for kv in "$@"; do
    k="${kv%%=*}"; case "$k" in "" | *[!a-z_]*) continue ;; esac
    local "L_$k"; printf -v "L_$k" '%s' "${kv#*=}"
  done
  case "$e" in
    booted) printf 'Booted %s%s in %s: %s\n' "${L_team:-}" "${L_issue:+ on $L_issue}" "${L_repo:-}" "${L_agents:-}" ;;
    moved) printf 'Moved %s: %s → %s\n' "${L_team:-}" "${L_from:--}" "${L_to:-}" ;;
    retire_ask) printf 'Retire %s? Outcome %s. Unpushed: %s. Kept: %s. Reply yes to retire.\n' "${L_team:-}" "${L_outcome:-Abandoned}" "${L_unpushed:-none}" "${L_kept:-none}" ;;
    retired) printf 'Retired %s (%s): PRs %s. %s%s%s\n' "${L_team:-}" "${L_outcome:-Abandoned}" "${L_prs:-none}" \
      "$([ -n "${L_archived:-}" ] && printf 'Archived to %s.' "$L_archived" || printf 'Nothing archived.')" \
      "${L_kept:+ Kept: $L_kept.}" "${L_issue_state:+ Issue → $L_issue_state.}" ;;
    parked) printf 'Parked %s: slot free, worktrees and claim kept.\n' "${L_team:-}" ;;
    park_marked) printf 'Marked %s: it parks when its PR merges.\n' "${L_team:-}" ;;
    unparked) printf 'Unparked %s: %s back.\n' "${L_team:-}" "${L_agents:-}" ;;
    focused) printf 'Focused on %s: parked %s.%s\n' "${L_team:-}" "${L_parked:-none}" "${L_refused:+ Refused: $L_refused.}" ;;
    focus_marked) printf 'Focused on %s: %s park when their PRs merge.%s\n' "${L_team:-}" "${L_marked:-none}" "${L_refused:+ Refused: $L_refused.}" ;;
    focus_cleared) printf 'Focus cleared: unparked %s.%s\n' "${L_unparked:-none}" "${L_refused:+ Refused: $L_refused.}" ;;
    focus) printf 'Focus: %s.\n' "${L_team:-none}" ;;
    no_problems) printf 'No problems.\n' ;;
    other_machines) printf 'Other machines: %s.\n' "${L_list:-none}" ;;
    loop_unregistered) printf 'Loop: no Orchestrator registered, so wakes reach desktop notifications only. Run registry.sh orchestrator here in its pane.\n' ;;
    herdr_integration) printf 'herdr Claude integration: not current (run herdr integration install claude).\n' ;;
    respawned) printf 'Respawned %s (%s): %s.\n' "${L_name:-}" "${L_model:-default model}" "${L_state:-}" ;;
    restarted) printf 'Restarted %s (%s): %s.\n' "${L_name:-}" "${L_model:-default model}" "${L_state:-}" ;;
    told) printf 'Told %s: "%s" (%s)\n' "${L_name:-}" "${L_text:-}" "${L_how:-delivered}" ;;
    resolved) printf 'Resolved %s for %s: %s.\n' "${L_id:-}" "${L_name:-}" "${L_decision:-no note}" ;;
    prime) printf 'Fleet on %s: %s teams, %s open escalations, %s problems.\n' "${L_machine:-}" "${L_teams:-0}" "${L_escalations:-0}" "${L_problems:-0}" ;;
    loop) printf 'Fleet loop: %s. Last good tick %s. %s.\n' "${L_loaded:-not loaded}" "${L_when:-never}" "${L_health:-problem}" ;;
    env) printf 'Env %s: %s. Context fleet-%s.\n' "${L_team:-}" "${L_state:-Down}" "${L_team:-}" ;;
    claimed) printf 'Claimed %s for %s.\n' "${L_issue:-}" "${L_machine:-}" ;;
    took_over) printf 'Took over %s from %s (heartbeat %s).\n' "${L_issue:-}" "${L_machine:-}" "${L_age:-unknown}" ;;
    holder) if [ -n "${L_machine:-}" ]; then printf '%s: held by %s (heartbeat %s%s).\n' "${L_issue:-}" "$L_machine" "${L_age:-none}" "${L_lapsed:+, lapsed}"
            else printf '%s: held by nobody.\n' "${L_issue:-}"; fi ;;
    sandbox) printf 'Sandbox at %s: %s exited %s.%s\n' "${L_dir:-}" "${L_cmd:-}" "${L_code:-0}" "${L_kept:+ Kept.}" ;;
    disk) printf 'Disk: %s GB free (warn below %s).%s\n' "${L_free:-?}" "${L_warn:-?}" "${L_held:+ Fleet holds $L_held GB. Reclaimed ${L_reclaimed:-0} GB.}" ;;
    alert) printf 'Alert: %s. %s.\n' "${L_cause%.}" "${L_next%.}" ;;
    pr_ready) printf '✓ Ready to merge: %s%s. Tester signed %s = head, CI %s, mergeable.\n' "${L_pr:-}" "${L_issue:+ for $L_issue}" "${L_sha:-}" "${L_ci:-green}" ;;
    pr_merged) printf 'Merged %s. Next: %s.\n' "${L_pr:-}" "${L_next:-}" ;;
    pr_opened) printf 'PR opened: %s%s. %s.\n' "${L_pr:-}" "${L_issue:+ for $L_issue}" "${L_told:-Lead told to start the tester}" ;;
    event) printf '%s %s: %s. %s.\n' "${L_event:-}" "${L_name:-}" "${L_what%.}" "${L_next%.}" ;;
    claim_takeover) printf '%s taken over by %s. Stop or hand off %s.\n' "${L_issue:-}" "${L_machine:-}" "${L_team:-}" ;;
    slot_free) printf 'Slot free (%s of %s teams running). Pick the next issue and boot it.\n' "${L_live:-?}" "${L_target:-?}" ;;
    debrief) printf '%s (%s): %s\n' "${L_team:-}" "${L_outcome:-}" "${L_lessons:-}" ;;
    discovered) printf 'Discovered work: %s\n' "${L_work:-}" ;;
    report) printf 'Report: %s\n' "${L_path:-}" ;;
    no_prs) printf 'No PRs in the last %s.\n' "${L_since:-7d}" ;;
    redact) printf 'Redact check %s: %s matches.\n' "${L_range:-}" "${L_count:-0}" ;;
    no_envs) printf 'No team environments.\n' ;;
    nothing_to_debrief) printf 'Nothing to debrief.\n' ;;
    *) warn "render_line: no entry '$e'"; return 1 ;;
  esac
}

# team_issue <team>: the team's issue as a reply writes it (a link, or the bare key); empty when it has none.
team_issue() {
  local r; r="$("$FLEET_SCRIPTS/registry.sh" list --team "$1" | jq -r '[.[] | select((.issue // "") != "")] | first // {} | [(.issue // ""), (.issue_url // "")] | @tsv')"
  issue_link "${r%%$'\t'*}" "${r#*$'\t'}"
}

# render_notice <tick event JSON>: the reply to one wake (its entry under "Wakes" in references/output.md).
render_notice() {
  local e="$1" type team name url d o n opts=()
  type="$(jq -r .type <<<"$e")"; team="$(jq -r '.team // ""' <<<"$e")"; name="$(jq -r '.name // ""' <<<"$e")"; url="$(jq -r '.url // ""' <<<"$e")"
  case "$type" in
    pr_ready) render_line pr_ready pr="$(pr_link "$url")" issue="$(team_issue "$team")" sha="$(jq -r '.sha // ""' <<<"$e" | cut -c1-7)" ci="$(jq -r '.ci // "green"' <<<"$e")" ;;
    pr_merged) d="move $team to its next issue, or retire it"; [ -z "$(jq -r '.parks // ""' <<<"$e")" ] || d="$team parked"
      [ "$(jq -r '.parked // false' <<<"$e")" != true ] || d="unpark $team and move it to its next issue, or retire it"
      render_line pr_merged pr="$(pr_link "$url")" next="$d" ;;
    pr_conflicting) d="$(jq -r '.unpark_refused // ""' <<<"$e")"
      o="$(jq -r '.merged // ""' <<<"$e" | tr ',' '\n' | sed 's/^ *//' | while IFS= read -r u; do [ -z "$u" ] || pr_link "$u"; done | paste -sd, - | sed 's/,/, /g')"
      if [ -n "$d" ]; then n="Unpark refused ($d): unpark it when a slot frees, then tell its lead"
      else n="Lead told to bring it up to date with main and have the tester sign off again"; fi
      render_line event event=Conflicting name="$name" what="$(pr_link "$url") conflicts after $o" next="$n" ;;
    pr_opened) render_line pr_opened pr="$(pr_link "$url")" issue="$(team_issue "$team")" told="Lead not reached: tell it to start the tester" ;;
    dead) render_line event event=Dead name="$name" what="its agent is gone" next="Tick respawns it once in $(const_int RESPAWN_WINDOW_HOURS 6)h, then escalates P1" ;;
    failed) render_line event event=Failed name="$name" what="a restart or its brief did not arrive" next="Re-send its brief or re-boot the team" ;;
    stalled) render_line event event=Stalled name="$name" what="idle without its done step, nudged once" next="Ask it for its done step" ;;
    needs_input) d="$(jq -r '.detail // "API error"' <<<"$e")"
      if [ "$d" = "login expired" ]; then render_line event event="Needs input" name="$name" what="$d" next="Run /login in its pane"
      else render_line event event="Needs input" name="$name" what="$d" next="Look at its pane"; fi ;;
    brief_failed) render_line event event="Brief failed" name="$name" what="its brief never arrived, re-sent once" next="Look at its pane, then re-send or re-boot" ;;
    claim_takeover) render_line claim_takeover issue="$(team_issue "$team")" machine="$(jq -r '.holder // "another machine"' <<<"$e")" team="$team" ;;
    claim_released | claim_held_pr | claim_lapsed)
      n="$(jq -r '.issue // ""' <<<"$e")"; o="$(jq -r '.holder // "another machine"' <<<"$e")"; d="$(jq -r '.detail // ""' <<<"$e")"
      case "$type" in
        claim_released) render_line event event="Claim released" name="$n" what="$o stopped its heartbeat and has no open PR" next="The issue is free to pick" ;;
        claim_held_pr) render_line event event="Claim held" name="$n" what="$o stopped its heartbeat, but $(pr_link "$url") is open" next="It stays theirs while the PR is open" ;;
        claim_lapsed) render_line event event="Claim lapsed" name="$n" what="$o: $d" next="Left as it is" ;;
      esac ;;
    stale_version) d="$(jq -r '.to // "a newer version"' <<<"$e")"
      render_decision P2 "$name" "$team runs plugin $(jq -r '.from // "an older version"' <<<"$e") and $d is installed. Switch it to $d at its next issue?" \
        "yes, at its next issue" "no, retire it after this issue" ;;
    slot_free) render_line slot_free live="$(jq -r '.live // "?"' <<<"$e")" target="$(jq -r '.target // "?"' <<<"$e")" ;;
    weekly_summary) "$FLEET_SCRIPTS/metrics.sh" --since 7d 2>/dev/null ;;
    escalation)
      while IFS= read -r o; do [ -z "$o" ] || opts+=("$o"); done < <(jq -r '.options[]? // empty' <<<"$e")
      render_decision "$(jq -r .severity <<<"$e")" "$name" "$(jq -r .message <<<"$e")" ${opts[@]+"${opts[@]}"} ;;
    *) return 1 ;;
  esac
}

# WAKE_TYPES: the tick events that wake the Orchestrator (loop-tick.sh) and get a notice (tick.sh); each has an entry
# in references/output.md. An escalation wakes at any severity, pr_opened only when the lead could not be told.
WAKE_TYPES="pr_ready pr_merged pr_opened pr_conflicting dead failed stalled needs_input brief_failed claim_takeover claim_released claim_held_pr claim_lapsed stale_version slot_free weekly_summary escalation"
# WAKE_JQ: the jq filter that keeps the events that wake, with $wake bound to WAKE_TYPES (--arg wake "$WAKE_TYPES").
WAKE_JQ='select(type == "object") | select((.type as $t | $wake | split(" ") | index($t)) and (.type != "pr_opened" or .lead_told == false))'

# Notices: the wake replies tick renders for the Orchestrator. notices.log in the state dir holds one JSON line
# each, {at, text}; `status` prints the ones not shown yet, once, above its table (notices.shown counts them), so
# the answer to any wake is one `fleet status`. A short mkdir lock keeps an append and a show from crossing.
notices_file() { printf '%s\n' "$FLEET_STATE_DIR/notices.log"; }
notices_lock() { local i=0; until mkdir "$(notices_file).lock" 2>/dev/null; do i=$((i + 1)); [ "$i" -lt 50 ] || return 1; sleep 0.1; done; }
notices_unlock() { rmdir "$(notices_file).lock" 2>/dev/null || true; }
notice_add() { # notice_add <text>: one notice (it may span lines)
  local f; f="$(notices_file)"; mkdir -p "$(dirname "$f")"
  notices_lock || { warn "notices are locked; dropped one: $(printf '%s' "$1" | head -n 1)"; return 0; }
  jq -nc --arg at "${FLEET_NOW:-$(now)}" --arg t "$1" '{at: $at, text: $t}' >>"$f" 2>/dev/null || warn "cannot write $f"
  notices_unlock
}
notices_show() { # print the notices not shown yet, a blank line between two (reply), and mark them shown
  local f n s; f="$(notices_file)"
  [ -s "$f" ] || return 0
  notices_lock || return 0
  n="$(wc -l <"$f" | tr -d ' ')"; s="$(cat "$f.shown" 2>/dev/null || true)"
  case "$s" in "" | *[!0-9]*) s=0 ;; esac; [ "$s" -le "$n" ] || s=0
  [ "$s" -ge "$n" ] || tail -n +$((s + 1)) "$f" | jq -Rrn '[inputs | fromjson? | .text? // empty | select(type == "string" and . != "")] | join("\n\n")' 2>/dev/null
  # Once everything is shown, a long log starts over (nothing unshown is lost).
  if [ "$n" -gt 200 ]; then : >"$f"; n=0; fi
  printf '%s\n' "$n" >"$f.shown"
  notices_unlock
}
