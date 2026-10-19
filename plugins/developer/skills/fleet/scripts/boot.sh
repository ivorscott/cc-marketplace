#!/usr/bin/env bash
# Boot one team: workspace → worktrees → panes → agents → briefs → registry rows.
#
#   boot.sh [--issue ID --claimed-by KEY --labels a,b --scope 'repo: p1, p2' --peer-claim ...]
#           <template> <focus> <repo-dir> [task text...]
#
# <template> is a name from ../templates (build, race, review, research) or a path to a
# template JSON file. <focus> becomes the team name <template>-<focus>. The task text
# defaults to <focus>. Prints the booted team as JSON on stdout.
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
# max_agents and min_free_gb), FLEET_MACHINE (replaces this machine's key, see machine-id.sh),
# FLEET_LABEL_PREFIX (claim label prefix, default "fleet:").
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
need git
# Whether a key exists (nothing is read from it), then agents never get it: boot starts them from
# a shell that does not carry LINEAR_API_KEY.
have_key=0; "$FLEET_SCRIPTS/linear.sh" has-key >/dev/null 2>&1 && have_key=1
unset LINEAR_API_KEY

issue=""; claimed_by=""; labels=""; scope_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue) issue="${2:?--issue needs a value}"; shift 2 ;;
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
    if [ "$(cfg_int machines 1)" -gt 1 ]; then die "$issue: no Linear key and machines > 1 in config.toml, so claims cannot be checked. Not booting"; fi
    warn "no Linear key; booting $issue without checking claims (machines = 1)"
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

# Concurrency cap.
live="$("$registry" count-live)"; cap="$(max_agents)"
if [ "${FLEET_FORCE:-}" != "1" ] && [ $((live + 1 + nworkers)) -gt "$cap" ]; then
  die "booting $team needs $((1 + nworkers)) agents; $live live, max_agents=$cap (set FLEET_FORCE=1 or raise max_agents in $FLEET_CONFIG_DIR/config.toml)"
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

tool_allow="$(jq -cn --argjson t "$(config_list tracker_allow)" --argjson f "$(config_list forge_allow)" '$t + $f | unique')"

is_git=false; git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 && is_git=true

render() { # render <text> <name> <worktree> <workers>
  local s="$1"
  s="${s//\{\{team\}\}/$team}"; s="${s//\{\{task\}\}/$task}"; s="${s//\{\{repo\}\}/$repo}"
  s="${s//\{\{name\}\}/$2}"; s="${s//\{\{name_slug\}\}/${2//\//-}}"; s="${s//\{\{worktree\}\}/$3}"
  s="${s//\{\{workers\}\}/$4}"; s="${s//\{\{registry\}\}/$registry}"; s="${s//\{\{scripts\}\}/$FLEET_SCRIPTS}"
  printf '%s' "$s"
}

claude_args() { # claude_args <model> <tier> <worktree> <allow-json>
  local settings extra="${4:-[]}" herdr_allow='["Bash(herdr agent get:*)", "Bash(herdr agent read:*)", "Bash(herdr agent list:*)", "Bash(herdr agent wait:*)"]'
  # Leads drive their own workers; fleet-bash-guard.sh holds them to their own team.
  [ "$2" != "Lead" ] || herdr_allow='["Bash(herdr agent get:*)", "Bash(herdr agent read:*)", "Bash(herdr agent list:*)", "Bash(herdr agent wait:*)", "Bash(herdr agent prompt:*)", "Bash(herdr agent send-keys:*)"]'
  extra="${extra//\{\{scripts\}\}/$FLEET_SCRIPTS}"
  extra="${extra//\{\{team\}\}/$team}"; extra="${extra//\{\{worktree\}\}/$3}"
  settings="$(jq -cn --arg r "$registry" --argjson extra "$extra" --argjson tools "$tool_allow" --argjson h "$herdr_allow" \
    '{permissions: {allow: (["Bash(\($r):*)"] + $h + $extra + $tools | unique)}}')"
  printf '%s\0' --settings "$settings"
  [ -n "$1" ] && printf '%s\0' --model "$1"
  [ "$2" = "Lead" ] && printf '%s\0' --agent developer:lead
  printf '%s\0' --permission-mode "$(permission_mode)"
  # --session-id pins the transcript file name, so the row can record where the agent's
  # transcript is (tell.sh and next.sh read it). boot sets session_id just before each start.
  [ -z "${session_id:-}" ] || printf '%s\0' --session-id "$session_id"
}

# Answer Claude's folder-trust dialog, but only for directories this boot owns or was
# given (the repo and our worktrees). The default option is "No, exit", so read the
# cursor position before pressing Enter.
answer_trust() { # answer_trust <agent>
  local i screen
  for i in 1 2 3 4; do
    screen="$(hd agent read "$1" --source visible 2>/dev/null || true)"
    case "$screen" in *"trust this folder"*) ;; *) return 0 ;; esac
    if printf '%s' "$screen" | grep -q '❯ *Yes, I trust this folder'; then
      hd agent send-keys "$1" enter >/dev/null; sleep 1; return 0
    fi
    hd agent send-keys "$1" down >/dev/null; sleep 0.3
  done
  return 1
}

alive() { # the pane runs something other than its shell (gotcha: idle can mean "exited")
  hd pane process-info --pane "$1" 2>/dev/null |
    jq -e '.result.process_info | .foreground_process_group_id != .shell_pid' >/dev/null
}

start_agent_once() { # start_agent_once <agent> <kind> <pane> <model> <tier> <worktree> <allow-json> → prints status
  local agent="$1" kind="$2" pane="$3" args=() out code tries=0
  # herdr starts the canonical `claude` executable, so `env -u` cannot prefix it. The pane's shell
  # drops the Linear key first, so the harness and every Bash call it makes start without it.
  [ "$kind" != "claude" ] || hd pane run "$pane" 'unset LINEAR_API_KEY' >/dev/null 2>&1 || true
  if [ "$kind" = "claude" ]; then
    while IFS= read -r -d '' a; do args+=("$a"); done < <(claude_args "$4" "$5" "$6" "${7:-[]}")
  fi
  # A fresh pane isn't "an available shell" until its shell has finished starting up
  # (rc files, prompt hooks), which can take several seconds in a git worktree. Retry
  # agent_pane_busy for up to 30s instead of failing the agent as a Zombie.
  while :; do
    out="$(hd agent start "$agent" --kind "$kind" --pane "$pane" --timeout 60000 -- ${args[@]+"${args[@]}"} 2>&1 || true)"
    code="$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null || true)"
    [ "$code" = "agent_pane_busy" ] && [ $((tries += 1)) -le 30 ] || break
    sleep 1
  done
  if [ "$code" = "agent_not_ready" ]; then
    answer_trust "$agent" || true
  elif [ -n "$code" ]; then
    warn "agent start $agent: $out"; printf 'Zombie'; return 0
  fi
  hd agent wait "$agent" --until idle --timeout 30000 >/dev/null 2>&1 || true
  if ! alive "$pane"; then printf 'Zombie'; return 0; fi
  case "$(hd agent get "$agent" 2>/dev/null | jq -r '.result.agent.agent_status // "unknown"')" in
    blocked) printf 'Needs input' ;;
    *) printf 'Working' ;;
  esac
}

# The start command can be eaten by a shell that is still starting up: an oh-my-zsh update
# prompt reads the first key typed, so `claude` arrives as `laude`. That key is gone once
# consumed, so a second try into the same pane works. Retry once before calling it a Zombie.
start_agent() { # same arguments as start_agent_once
  local status
  status="$(start_agent_once "$@")"
  if [ "$status" = "Zombie" ]; then
    warn "agent $1 did not start; retrying once"
    status="$(start_agent_once "$@")"
  fi
  printf '%s' "$status"
}

# 1. Workspace with the lead in its root pane.
lead_agent="$(agent_name "$team-lead")"
lead_name="$team/lead"
ws_json="$(hd workspace create --cwd "$repo" --label "$team" --no-focus \
  --env FLEET_ROLE=lead --env "FLEET_NAME=$lead_name" --env "FLEET_TEAM=$team" --env "FLEET_STATE_DIR=$FLEET_STATE_DIR" ${env_args[@]+"${env_args[@]}"})"
workspace="$(printf '%s' "$ws_json" | jq -r .result.workspace.workspace_id)"
lead_pane="$(printf '%s' "$ws_json" | jq -r .result.root_pane.pane_id)"
[ -n "$workspace" ] && [ "$workspace" != "null" ] || die "workspace create failed: $ws_json"

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
    cwd="$worktree"
  fi
  if [ -z "$prev" ]; then split=(--pane "$lead_pane" --direction right); else split=(--pane "$prev" --direction down); fi
  pane="$(hd pane split "${split[@]}" --cwd "$cwd" --no-focus \
    --env FLEET_ROLE=worker --env "FLEET_NAME=$name" --env "FLEET_TEAM=$team" \
    --env "FLEET_WORKTREE=$worktree" --env "FLEET_STATE_DIR=$FLEET_STATE_DIR" \
    ${env_args[@]+"${env_args[@]}"} | jq -r .result.pane.pane_id)"
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
    '{name: $name, team: $team, tier: $tier, template: $tpl, harness: $harness, model: $model, repo: $repo,
      machine: $m, status: $status, assignment: $task, herdr_ref: $ref, pane: $pane, workspace: $ws,
      cwd: $cwd, worktree: $wt, branch: $br, expertise_file: $ex}
    + (if $tr != "" then {transcript: $tr} else {} end)
    + (if $issue != "" then {issue: $issue, claimed_by: $cb} else {} end)
    + (if $scope != null then {scope: $scope} else {} end)'
}

# deliver <name> <brief>: tell.sh sends it and checks it arrived. An undelivered brief marks the
# row Failed (never Working) and boot exits non-zero once the team JSON is printed.
failed_agents=()
deliver() {
  "$FLEET_SCRIPTS/tell.sh" "$1" "$2" >/dev/null || { "$registry" set "$1" status=Failed >/dev/null; failed_agents+=("$1"); }
}

expertise_for() { local f="$repo/.claude/experts/$1.md"; [ -f "$f" ] && printf '%s' "$f" || true; }

# 3. Start workers, register them, send their briefs.
for i in $(seq 0 $((nworkers - 1))); do
  w="$(printf '%s' "$workers_json" | jq -c ".[$i]")"
  get() { printf '%s' "$w" | jq -r ".$1 // \"\""; }
  kind="$(get kind)"; kind="${kind:-claude}"
  if ! command -v "$kind" >/dev/null 2>&1; then warn "$kind not on PATH; $(get agent) falls back to claude"; kind=claude; fi
  allow="$(printf '%s' "$w" | jq -c '.allow // []')"
  session_id=""; row_transcript=""
  if [ "$kind" = "claude" ]; then
    session_id="$(new_uuid)"; row_transcript="$(transcript_dir_for "$(get cwd)")/$session_id.jsonl"
  fi
  status="$(start_agent "$(get agent)" "$kind" "$(get pane)" "$(get model)" Worker "$(get worktree)" "$allow")"
  ex="$(expertise_for "$(get role)")"
  "$registry" add "$(row "$(get name)" Worker "$(get agent)" "$(get pane)" "$kind" "$(get model)" "$status" "$(get cwd)" "$(get worktree)" "$(get branch)" "$ex")"
  if [ "$status" = "Working" ]; then
    brief="$(build_brief "$(get name)" "$ex" "$(render "$(get brief)" "$(get name)" "$(get worktree)" "$worker_agents")")"
    deliver "$(get name)" "$brief"
  fi
done

# 4. Start the lead last, so its brief can name live workers.
lead_kind="$(jq -r '.lead.kind // "claude"' "$tpl")"; lead_model="$(jq -r '.lead.model // ""' "$tpl")"
command -v "$lead_kind" >/dev/null 2>&1 || { warn "$lead_kind not on PATH; the lead falls back to claude"; lead_kind=claude; }
session_id=""; row_transcript=""
if [ "$lead_kind" = "claude" ]; then
  session_id="$(new_uuid)"; row_transcript="$(transcript_dir_for "$repo")/$session_id.jsonl"
fi
status="$(start_agent "$lead_agent" "$lead_kind" "$lead_pane" "$lead_model" Lead "" "$(jq -c '.lead.allow // []' "$tpl")")"
ex="$(expertise_for lead)"
"$registry" add "$(row "$lead_name" Lead "$lead_agent" "$lead_pane" "$lead_kind" "$lead_model" "$status" "$repo" "" "" "$ex")"
if [ "$status" = "Working" ]; then
  brief="$(build_brief "$lead_name" "$ex" "$(render "$(jq -r .lead.brief "$tpl")" "$lead_name" "" "$worker_agents")")"
  deliver "$lead_name" "$brief"
fi

"$registry" list --team "$team" |
  jq --arg ws "$workspace" --arg team "$team" '{team: $team, workspace: $ws, agents: [.[] | {name, herdr_ref, pane, status, worktree}]}'
if [ "${#failed_agents[@]}" -gt 0 ]; then
  warn "brief not delivered to: ${failed_agents[*]} (rows set to Failed)"
  exit 1
fi
