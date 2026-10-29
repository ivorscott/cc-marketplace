#!/usr/bin/env bash
# Boot one team: workspace → worktrees → panes → registry rows (Idle) → agents → briefs.
#
#   boot.sh [--issue ID --claimed-by KEY --labels a,b --scope 'repo: p1, p2' --peer-claim ...]
#           <template> <focus> <repo-dir> [task text...]
#
# <template> is a name from ../templates (build, review, research) or a path to a
# template JSON file. <focus> becomes the team name <template>-<focus>. The task text
# defaults to <focus>. Prints "Booted <team> on <issue> in <repo>: lead ✓ ..." (✗ with the reason for an agent
# that did not start or whose brief did not arrive), then the team table (references/output.md).
#
# A boot that fails or is interrupted (INT, TERM) after it created something undoes what this run made: it closes the
# workspace, removes the worktrees and fleet/<team>/* branches it made and retires its rows (Abandoned), so the same
# name boots again. Before anything is created, it refuses a name with leftovers of an earlier boot (fleet/<team>/*
# branches in the repo, or a $FLEET_WORKTREES/<team> directory), naming `retire.sh <team>`.
#
# Every Claude agent also gets the tracker_allow and forge_allow lists from config.toml, so
# reading tickets (Linear, Jira, ...) and pull/merge requests (gh, glab, ...) never blocks
# and no template names a particular tool.
#
# If the repo declares a team environment (.claude/fleet-env.json), every agent in the
# team, lead included, starts with KUBECONFIG pointing at the team's own kubeconfig, even
# before its cluster exists (see env.sh). Boot itself never creates a cluster.
#
# Boot refuses when free disk is below min_free_gb in config.toml (default 40; 0 disables),
# so a full disk never hangs Docker mid-run.
#
# Claims (see SKILL.md, "Claim"): boot never calls a tracker. The Orchestrator claims the issue
# first (linear.sh claim) and passes the result in.
#   --issue ID           the tracker issue this team works on
#   --issue-url URL      the issue's full URL: briefs carry the exact "Fixes <URL>" line for the PR body
#   --issue-title TEXT   the issue's title, from the search that picked it: the team table's Issue cell shows it
#   --claimed-by KEY     the machine key (or label) that holds the claim
#   --labels a,b,c       the issue's labels, as just re-read; any <label_prefix>* label that
#                        is not this machine's is another machine's claim
#   --scope 'repo: p1, p2'  declared file scope (repo defaults to the repo-dir name; no paths = whole repo)
# Boot refuses an issue claimed by another machine (FLEET_FORCE=1 does not bypass it), and warns
# when the declared scope overlaps a live team on this machine in the same repo. (Scope of other
# machines' claims is no longer known: the label plus the heartbeat is the lock.) A takeover is
# done with linear.sh takeover before boot; afterwards the label on the issue is this machine's.
# With --issue and no Linear key boot proceeds with a warning, unless config.toml says
# machines > 1, where it refuses: claims cannot be checked.
#
# Env: FLEET_SESSION (named herdr session, for isolated runs), FLEET_FORCE=1 (ignore
# max_teams and min_free_gb), FLEET_MACHINE (replaces this machine's key, see machine-id.sh),
# FLEET_LABEL_PREFIX (claim label prefix, default "fleet:").
# Command: Boot a team on a task or an issue · e.g. fleet boot build export ~/code/api "add CSV invoice export"
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
need git
config_warn_unknown
# Whether a key exists (nothing is read from it), then agents never get it: boot starts them from
# a shell that does not carry LINEAR_API_KEY.
have_key=0; "$FLEET_SCRIPTS/linear.sh" has-key >/dev/null 2>&1 && have_key=1
# linear_writes = off counts as no key here: claims cannot be made, so with several machines there is no lock.
claims_why="no Linear key"; if [ "$have_key" = 1 ] && [ "$(linear_writes)" = off ]; then have_key=0; claims_why="linear_writes = off"; fi
unset LINEAR_API_KEY

issue=""; claimed_by=""; labels=""; scope_arg=""; issue_url=""; issue_title=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="${2:?--issue needs a value}"; shift 2 ;;
    --issue-url) issue_url="${2:?--issue-url needs a value}"; shift 2 ;;
    --issue-title) issue_title="${2:?--issue-title needs a value}"; shift 2 ;;
    --claimed-by) claimed_by="${2:?--claimed-by needs a value}"; shift 2 ;;
    --labels) labels="${2:?--labels needs a value}"; shift 2 ;;
    --scope) scope_arg="${2:?--scope needs a value}"; shift 2 ;;
    -*) die "unknown option: $1" ;;
    *) break ;;
  esac
done

tpl="${1:?usage: boot.sh [options] <template> <focus> <repo-dir> [task...]}"
focus="${2:?usage: boot.sh [options] <template> <focus> <repo-dir> [task...]}"
repo="${3:?usage: boot.sh [options] <template> <focus> <repo-dir> [task...]}"
shift 3
task="${*:-$focus}"

[ -f "$tpl" ] || tpl="$FLEET_SKILL_DIR/templates/$tpl.json"
[ -f "$tpl" ] || die "no template '$1' (have: $(cd "$FLEET_SKILL_DIR/templates" && ls | sed 's/\.json$//' | tr '\n' ' '))"
repo="$(cd "$repo" && pwd -P)" || die "no such directory: $3"

template="$(jq -r .name "$tpl")"
team="$(agent_name "$template-$focus")"
registry="$FLEET_SCRIPTS/registry.sh"
machine="$(machine_key)"
nworkers="$(jq '.workers | length' "$tpl")"

# One team name, one live team.
[ "$("$registry" list --team "$team" --live | jq length)" = "0" ] || die "team $team is already live; retire it first"
# Leftovers of an earlier boot of this name (an interrupted one, or a retire that kept work) are never reused.
left="$(git -C "$repo" for-each-ref --format='%(refname:short)' "refs/heads/fleet/$team/" 2>/dev/null | paste -sd' ' -)" || left=""
[ ! -d "$FLEET_WORKTREES/$team" ] || left="$left${left:+ }$FLEET_WORKTREES/$team"
[ -z "$left" ] || die "$team has leftovers of an earlier boot ($left)" "Run fleet retire $team first: it removes what is clean and names the rest"

# Claim: refuse an issue another machine holds, warn about overlapping scope.
trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }
parse_scope() { # parse_scope <'repo: p1, p2'> → {repo, paths[]}; the repo defaults to the repo-dir name
  local s="$1" r p
  case "$s" in *:*) r="${s%%:*}"; p="${s#*:}" ;; *) r="$s"; p="" ;; esac
  r="$(trim "$r")"; [ -n "$r" ] || r="$(basename "$repo")"
  jq -cn --arg r "$r" --arg p "$p" '{repo: $r, paths: ($p | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)))}'
}
prefix="$(label_prefix)"; my_label="$(machine_label)"; legacy_label="$(cfg_str machine_legacy_label '')"
is_mine() { [ "$1" = "$my_label" ] || { [ -n "$legacy_label" ] && [ "$1" = "$legacy_label" ]; }; }
claim_label() { case "$1" in "$prefix"*) printf '%s' "$1" ;; *) printf '%s%s' "$prefix" "$1" ;; esac; }
if [ -n "$issue" ]; then
  if [ -n "$claimed_by" ]; then
    holder="$(claim_label "$claimed_by")"
    is_mine "$holder" || die "$issue is claimed by $holder; this machine is $my_label. Not booting"
    claimed_by="${holder#"$prefix"}"
  fi
  if [ -n "$prefix" ]; then
    IFS=',' read -r -a label_list <<<"$labels"
    for l in ${label_list[@]+"${label_list[@]}"}; do
      l="$(trim "$l")"
      case "$l" in "$prefix"*) is_mine "$l" || die "$issue is claimed by $l; this machine is $my_label. Not booting" ;; esac
    done
  fi
  if [ "$have_key" != 1 ]; then
    if [ "$(cfg_int machines 1)" -gt 1 ]; then die "$issue: $claims_why and machines > 1 in config.toml, so claims cannot be checked. Not booting"; fi
    warn "$claims_why; booting $issue without checking claims (machines = 1)"
  fi
fi
scope_json=null
if [ -n "$scope_arg" ]; then
  scope_json="$(parse_scope "$scope_arg")"
  others="$("$registry" list --live | jq -c --arg team "$team" --arg p "$prefix" \
    '[.[] | select(.team != $team and .scope != null) | {team, label: ($p + (.machine // "local")), scope}] | unique_by(.team)')"
  printf '%s' "$others" | jq -r --arg team "$team" --arg me "$my_label" --argjson mine "$scope_json" '
    def segs: split("/") | map(select(length > 0));
    def pre($a; $b): ($a | segs) as $x | ($b | segs) as $y | ([($x | length), ($y | length)] | min) as $k | $x[0:$k] == $y[0:$k];
    ($mine.repo | ascii_downcase) as $repo
    | .[] | select((.scope.repo | ascii_downcase) == $repo) as $o
    | [$mine.paths[] as $p | select(($o.scope.paths | length) == 0 or any($o.scope.paths[]; pre($p; .))) | $p] as $hit
    | select(($mine.paths | length) == 0 or ($o.scope.paths | length) == 0 or ($hit | length) > 0)
    | "\($team) (\($me)) overlaps \($o.team) (\($o.label)) in \($mine.repo): \(if ($mine.paths | length) == 0 or ($hit | length) == 0 then "whole repo" else ($hit | join(", ")) end)"' |
    while IFS= read -r msg; do warn "$msg"; done
fi

# Concurrency cap: max_teams live teams (Parked teams do not count), and one team per repo.
cap="$(max_teams)"; live="$(live_team_count "$team")"
if [ "${FLEET_FORCE:-}" != "1" ]; then
  if [ "$live" -ge "$cap" ]; then
    die "booting $team would be live team number $((live + 1)); max_teams=$cap (park or retire one, set FLEET_FORCE=1, or raise max_teams in $FLEET_CONFIG_DIR/config.toml)"
  fi
  others="$(teams_on_repo "$repo" "$team")"
  if [ -n "$others" ] && [ "$(printf '%s\n' "$others" | grep -c .)" -ge "$(teams_per_repo)" ]; then
    die "booting $team: $(printf '%s' "$others" | paste -sd, -) already live on $repo, teams_per_repo=$(teams_per_repo) (park one, or set FLEET_FORCE=1)"
  fi
fi

# Disk floor.
floor="$(min_free_gb)"
if [ "${FLEET_FORCE:-}" != "1" ] && [ "$floor" -gt 0 ]; then
  if free="$(free_gb)"; then
    [ "$free" -ge "$floor" ] ||
      die "booting $team needs disk; $free GiB free, min_free_gb=$floor (set FLEET_FORCE=1 or lower min_free_gb in $FLEET_CONFIG_DIR/config.toml)"
  else
    warn "cannot read free disk; skipping the min_free_gb check"
  fi
fi

# Team environment: preset KUBECONFIG on every pane so agents can't reach the user's own clusters.
env_args=()
if [ -n "$(env_config "$repo")" ]; then
  mkdir -p "$(env_dir "$team")"
  env_args=(--env "KUBECONFIG=$(env_dir "$team")/kubeconfig")
fi
# One Terraform plugin cache for every pane, so each worktree does not download the providers again.
mkdir -p "$FLEET_STATE_DIR/tf-plugin-cache"; env_args+=(--env "TF_PLUGIN_CACHE_DIR=$FLEET_STATE_DIR/tf-plugin-cache")

tool_allow="$(jq -cn --argjson t "$(config_list tracker_allow)" --argjson f "$(config_list forge_allow)" '$t + $f | unique')"
# The permission mode: the template's own permission_mode, else config/FLEET_PERMISSION_MODE, else auto. A mode
# that turns permission checks off is refused here, before anything starts.
tpl_mode="$(jq -r '.permission_mode // empty' "$tpl")"
if [ -n "$tpl_mode" ]; then perm_mode="$(check_permission_mode "$tpl_mode")" || exit 1
else perm_mode="$(permission_mode)" || exit 1; fi
plugin_ver="$(plugin_version)"

is_git=false; git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 && is_git=true
# The planner writes its plan to <repo>/.fleet/plan/<team>.md, the one place it may write. .fleet/ stays out of git
# through the repo's own .git/info/exclude, added once; .gitignore is never touched, nor are the user's .spec/ and
# .plan/.
plan_file="$repo/.fleet/plan/$team.md"
! $is_git || git_exclude "$repo" '.fleet/'
mkdir -p "$(dirname "$plan_file")" 2>/dev/null || warn "could not create $(dirname "$plan_file")"

. "$FLEET_SCRIPTS/agent-lib.sh" # render, claude_args, start_agent (needs team, task, repo, registry, tool_allow)

# Agent state (tell's delivery check, status's health) comes from herdr's Claude integration: boot goes on without
# it, saying so once. Its first herdr call, after every refusal.
herdr_integration_ok || warn "herdr's Claude integration is not current, so agent state may be wrong; run herdr integration install claude"

# Rollback: a boot that fails or is interrupted once it has created something undoes only what this run made (an
# EXIT trap, armed with the workspace and disarmed once the reply is printed): it closes the workspace, removes the
# worktrees and the fleet/<team>/* branches it made, and retires the rows it wrote with outcome Abandoned. The same
# name then boots again.
made_ws=""; made_wts=(); made_brs=(); made_rows=0; armed=0
rollback() {
  [ "$armed" = 1 ] || return 0
  armed=0; local x
  warn "boot of $team did not finish; undoing what it made"
  [ -z "$made_ws" ] || hd workspace close "$made_ws" >/dev/null 2>&1 || warn "could not close workspace $made_ws"
  for x in ${made_wts[@]+"${made_wts[@]}"}; do git -C "$repo" worktree remove --force "$x" >/dev/null 2>&1 || warn "could not remove worktree $x"; done
  for x in ${made_brs[@]+"${made_brs[@]}"}; do git -C "$repo" branch -D "$x" >/dev/null 2>&1 || warn "could not delete branch $x"; done
  rmdir "$FLEET_WORKTREES/$team" 2>/dev/null || true
  [ "$made_rows" = 0 ] || "$registry" retire "$team" --outcome Abandoned >/dev/null 2>&1 || warn "could not retire the rows of $team"
}
trap 'rollback; [ "$(cat "$(boot_marker "$team")" 2>/dev/null)" != "$$" ] || rm -f "$(boot_marker "$team")"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
# While this boot runs, status and tick leave the team's rows alone (common.sh, boot marker).
mkdir -p "$(dirname "$(boot_marker "$team")")" && echo "$$" >"$(boot_marker "$team")" || warn "could not write the boot marker for $team"

# 1. Workspace with the lead in its root pane.
lead_agent="$(agent_name "$team-lead")"
lead_name="$team/lead"
armed=1
ws_json="$(hd workspace create --cwd "$repo" --label "$team" --no-focus \
  --env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0 --env FLEET_ROLE=lead --env "FLEET_NAME=$lead_name" --env "FLEET_TEAM=$team" --env "FLEET_STATE_DIR=$FLEET_STATE_DIR" ${env_args[@]+"${env_args[@]}"})" || ws_json=""
workspace="$(printf '%s' "$ws_json" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null || true)"
lead_pane="$(printf '%s' "$ws_json" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null || true)"
[ -n "$workspace" ] || die "workspace create failed: $ws_json"
made_ws="$workspace"

# 2. Worker panes (first to the right of the lead, the rest stacked below it), worktrees.
workers_json="[]"; prev=""
for i in $(seq 0 $((nworkers - 1))); do
  w="$(jq -c ".workers[$i]" "$tpl")"
  role="$(printf '%s' "$w" | jq -r .role)"
  name="$team/$role"; agent="$(agent_name "$team-$role")"
  cwd="$repo"; worktree=""; branch=""
  if [ "$(printf '%s' "$w" | jq -r '.worktree // false')" = "true" ] && $is_git; then
    worktree="$FLEET_WORKTREES/$team/$role"; branch="fleet/$team/$role"
    mkdir -p "$(dirname "$worktree")"
    git -C "$repo" worktree add -q -b "$branch" "$worktree" >/dev/null 2>&1 || die "git worktree add failed for $worktree"
    made_wts+=("$worktree"); made_brs+=("$branch")
    # A force push with lease also has to include what the remote had when we last fetched (push.useForceIfIncludes).
    git -C "$worktree" config push.useForceIfIncludes true >/dev/null 2>&1 || warn "could not set push.useForceIfIncludes in $worktree"
    cwd="$worktree"
  fi
  if [ -z "$prev" ]; then split=(--pane "$lead_pane" --direction right); else split=(--pane "$prev" --direction down); fi
  plan_env=(); [ "$role" != planner ] || plan_env=(--env "FLEET_PLAN_DIR=$repo/.fleet") # the scope guard's planner fence
  pane="$(hd pane split "${split[@]}" --cwd "$cwd" --no-focus \
    --env CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0 --env FLEET_ROLE=worker --env "FLEET_NAME=$name" --env "FLEET_TEAM=$team" \
    --env "FLEET_WORKTREE=$worktree" --env "FLEET_STATE_DIR=$FLEET_STATE_DIR" ${plan_env[@]+"${plan_env[@]}"} \
    ${env_args[@]+"${env_args[@]}"} | jq -r '.result.pane.pane_id // empty')" || pane=""
  [ -n "$pane" ] || die "pane split failed for $name"
  prev="$pane"
  workers_json="$(printf '%s' "$workers_json" | jq -c --argjson w "$w" --arg n "$name" --arg a "$agent" \
    --arg p "$pane" --arg c "$cwd" --arg wt "$worktree" --arg b "$branch" \
    '. + [$w + {name: $n, agent: $a, pane: $p, cwd: $c, worktree: $wt, branch: $b}]')"
done
sleep 1
worker_agents="$(printf '%s' "$workers_json" | jq -r '[.[].agent] | join(", ")')"

row() { # row <name> <tier> <agent> <pane> <kind> <model> <status> <cwd> <worktree> <branch> <expertise>
  jq -cn --arg name "$1" --arg tier "$2" --arg ref "$3" --arg pane "$4" --arg harness "$5" --arg model "$6" \
    --arg status "$7" --arg cwd "$8" --arg wt "$9" --arg br "${10}" --arg ex "${11}" \
    --arg team "$team" --arg tpl "$template" --arg repo "$repo" --arg task "$task" --arg m "$machine" --arg ws "$workspace" \
    --arg tr "${row_transcript:-}" --arg issue "$issue" --arg cb "$claimed_by" --argjson scope "$scope_json" \
    --arg pv "$plugin_ver" --arg iu "$issue_url" --arg it "$issue_title" \
    '{name: $name, team: $team, tier: $tier, template: $tpl, harness: $harness, model: $model, repo: $repo,
      machine: $m, status: $status, assignment: $task, herdr_ref: $ref, pane: $pane, workspace: $ws,
      cwd: $cwd, worktree: $wt, branch: $br, expertise_file: $ex}
    + (if $tr != "" then {transcript: $tr} else {} end)
    + (if $pv != "" then {plugin_version: $pv} else {} end)
    + (if $iu != "" then {issue_url: $iu} else {} end)
    + (if $it != "" then {issue_title: $it} else {} end)
    + (if $issue != "" then {issue: $issue, claimed_by: $cb} else {} end)
    + (if $scope != null then {scope: $scope} else {} end)'
}

# deliver <name> <brief>: tell.sh sends it and checks it arrived. An undelivered brief marks the
# row Failed (never Working) and boot exits non-zero once the team JSON is printed.
failed_agents=()
deliver() {
  "$FLEET_SCRIPTS/tell.sh" "$1" "$2" --brief >/dev/null || { "$registry" set "$1" status=Failed >/dev/null; failed_agents+=("$1"); }
}

expertise_for() { local f="$repo/.claude/experts/$1.md"; [ -f "$f" ] && printf '%s' "$f" || true; }

# 3. Every row first, Idle (D8), so an interrupted boot never leaves an agent the registry does not know (the rollback
# retires them). Each row names its session's transcript before the agent starts.
for i in $(seq 0 $((nworkers - 1))); do
  w="$(printf '%s' "$workers_json" | jq -c ".[$i]")"
  get() { printf '%s' "$w" | jq -r ".$1 // \"\""; }
  kind="$(get kind)"; kind="${kind:-claude}"
  if ! command -v "$kind" >/dev/null 2>&1; then warn "$kind not on PATH; $(get agent) falls back to claude"; kind=claude; fi
  session_id=""; row_transcript=""
  if [ "$kind" = "claude" ]; then
    session_id="$(new_uuid)"; row_transcript="$(transcript_dir_for "$(get cwd)")/$session_id.jsonl"
  fi
  "$registry" add "$(row "$(get name)" Worker "$(get agent)" "$(get pane)" "$kind" "$(get model)" Idle "$(get cwd)" "$(get worktree)" "$(get branch)" "$(expertise_for "$(get role)")")" >/dev/null
  made_rows=1
  workers_json="$(printf '%s' "$workers_json" | jq -c --argjson i "$i" --arg k "$kind" --arg s "$session_id" '.[$i] += {kind: $k, session_id: $s}')"
done
lead_kind="$(jq -r '.lead.kind // "claude"' "$tpl")"; lead_model="$(jq -r '.lead.model // ""' "$tpl")"
command -v "$lead_kind" >/dev/null 2>&1 || { warn "$lead_kind not on PATH; the lead falls back to claude"; lead_kind=claude; }
lead_session=""; row_transcript=""
if [ "$lead_kind" = "claude" ]; then
  lead_session="$(new_uuid)"; row_transcript="$(transcript_dir_for "$repo")/$lead_session.jsonl"
fi
"$registry" add "$(row "$lead_name" Lead "$lead_agent" "$lead_pane" "$lead_kind" "$lead_model" Idle "$repo" "" "" "$(expertise_for lead)")" >/dev/null
made_rows=1

# 4. Start the workers (each row turns Working or Zombie) and send their briefs.
for i in $(seq 0 $((nworkers - 1))); do
  w="$(printf '%s' "$workers_json" | jq -c ".[$i]")"
  get() { printf '%s' "$w" | jq -r ".$1 // \"\""; }
  session_id="$(get session_id)"
  status="$(start_agent "$(get agent)" "$(get kind)" "$(get pane)" "$(get model)" Worker "$(get worktree)" "$(printf '%s' "$w" | jq -c '.allow // []')")"
  "$registry" set "$(get name)" status="$status" >/dev/null
  if [ "$status" = "Working" ]; then
    brief="$(build_brief "$(get name)" "$(expertise_for "$(get role)")" "$(render "$(get brief)" "$(get name)" "$(get worktree)" "$worker_agents")")"
    deliver "$(get name)" "$brief"
  fi
done

# 5. Start the lead last, so its brief can name live workers.
session_id="$lead_session"
status="$(start_agent "$lead_agent" "$lead_kind" "$lead_pane" "$lead_model" Lead "" "$(jq -c '.lead.allow // []' "$tpl")")"
"$registry" set "$lead_name" status="$status" >/dev/null
if [ "$status" = "Working" ]; then
  brief="$(build_brief "$lead_name" "$(expertise_for lead)" "$(render "$(jq -r .lead.brief "$tpl")" "$lead_name" "" "$worker_agents")")"
  deliver "$lead_name" "$brief"
fi

ev_log boot team="$team" issue="$issue" detail="template $template"
herdr_meta "$team" # the team on herdr's panel (best effort)
reply "$(render_line booted team="$team" issue="$(issue_link "$issue" "$issue_url" "$issue_title")" repo="$(basename "$repo")" agents="$(roles_line "$team")")" "$(render_table)"
armed=0 # booted: from here on a failed brief marks its row Failed, and nothing is rolled back
if [ "${#failed_agents[@]}" -gt 0 ]; then
  warn "brief not delivered to: ${failed_agents[*]} (rows set to Failed)"
  exit 1
fi
