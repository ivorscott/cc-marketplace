#!/usr/bin/env bash
# Boot one team: workspace → worktrees → panes → agents → briefs → registry rows.
#
#   boot.sh <template> <focus> <repo-dir> [task text...]
#
# <template> is a name from ../templates (build, race, review, research) or a path to a
# template JSON file. <focus> becomes the team name <template>-<focus>. The task text
# defaults to <focus>. Prints the booted team as JSON on stdout.
#
# Env: FLEET_SESSION (named herdr session, for isolated runs), FLEET_FORCE=1 (ignore
# max_agents), FLEET_MACHINE (label stored in the registry, default "local").
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
need git

tpl="${1:?usage: boot.sh <template> <focus> <repo-dir> [task...]}"
focus="${2:?usage: boot.sh <template> <focus> <repo-dir> [task...]}"
repo="${3:?usage: boot.sh <template> <focus> <repo-dir> [task...]}"
shift 3
task="${*:-$focus}"

[ -f "$tpl" ] || tpl="$FLEET_SKILL_DIR/templates/$tpl.json"
[ -f "$tpl" ] || die "no template '$1' (have: $(cd "$FLEET_SKILL_DIR/templates" && ls | sed 's/\.json$//' | tr '\n' ' '))"
repo="$(cd "$repo" && pwd -P)" || die "no such directory: $3"

template="$(jq -r .name "$tpl")"
team="$(agent_name "$template-$focus")"
registry="$FLEET_SCRIPTS/registry.sh"
machine="${FLEET_MACHINE:-local}"
nworkers="$(jq '.workers | length' "$tpl")"
edits_ok="$(jq -r '.auto_answer.edits_in_worktree // false' "$tpl")"

# One team name, one live team.
[ "$("$registry" list --team "$team" --live | jq length)" = "0" ] || die "team $team is already live; retire it first"

# Concurrency cap.
live="$("$registry" count-live)"; cap="$(max_agents)"
if [ "${FLEET_FORCE:-}" != "1" ] && [ $((live + 1 + nworkers)) -gt "$cap" ]; then
  die "booting $team needs $((1 + nworkers)) agents; $live live, max_agents=$cap (set FLEET_FORCE=1 or raise max_agents in $FLEET_CONFIG_DIR/config.toml)"
fi

is_git=false; git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 && is_git=true

render() { # render <text> <name> <worktree> <workers>
  local s="$1"
  s="${s//\{\{team\}\}/$team}"; s="${s//\{\{task\}\}/$task}"; s="${s//\{\{repo\}\}/$repo}"
  s="${s//\{\{name\}\}/$2}"; s="${s//\{\{name_slug\}\}/${2//\//-}}"; s="${s//\{\{worktree\}\}/$3}"
  s="${s//\{\{workers\}\}/$4}"; s="${s//\{\{registry\}\}/$registry}"
  printf '%s' "$s"
}

contract() { # the done contract appended to every brief
  local name="$1" expertise="$2" x=""
  [ -n "$expertise" ] && x=" Before you start, read your expertise file $expertise and follow it."
  printf '%s' "

Fleet rules for $name.$x Stay on this one task. If you notice unrelated work, run \`$registry note $name discovered \"<what>\"\` instead of doing it. If you need a decision you cannot make, run \`$registry escalate $name P1 \"<question>\"\` and wait. If you stop to wait for instructions, first run \`$registry set $name status=Idle\`. Every commit carries the trailer \`Agent: $name\`. When your part is finished: push your branch if you have one, then run \`$registry done $name --outcome <Shipped|Partial|Failed> --summary \"<one line>\"\`, then stop. Going idle without that command marks you Stalled."
}

claude_args() { # claude_args <model> <tier> <worktree> <allow-json>
  local settings
  settings="$(jq -cn --arg r "$registry" --argjson extra "${4:-[]}" \
    '{permissions: {allow: (["Bash(\($r):*)", "Bash(herdr:*)"] + $extra)}}')"
  printf '%s\0' --settings "$settings"
  [ -n "$1" ] && printf '%s\0' --model "$1"
  [ "$2" = "Lead" ] && printf '%s\0' --agent developer:lead
  if [ -n "$3" ] && [ "$edits_ok" = "true" ]; then printf '%s\0' --permission-mode acceptEdits; fi
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

start_agent() { # start_agent <agent> <kind> <pane> <model> <tier> <worktree> <allow-json> → prints status
  local agent="$1" kind="$2" pane="$3" args=() out code
  if [ "$kind" = "claude" ]; then
    while IFS= read -r -d '' a; do args+=("$a"); done < <(claude_args "$4" "$5" "$6" "${7:-[]}")
  fi
  out="$(hd agent start "$agent" --kind "$kind" --pane "$pane" --timeout 60000 -- "${args[@]}" 2>&1 || true)"
  code="$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null || true)"
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

# 1. Workspace with the lead in its root pane.
lead_agent="$(agent_name "$team-lead")"
lead_name="$team/lead"
ws_json="$(hd workspace create --cwd "$repo" --label "$team" --no-focus \
  --env FLEET_ROLE=lead --env "FLEET_NAME=$lead_name" --env "FLEET_TEAM=$team" --env "FLEET_REGISTRY=$FLEET_REGISTRY")"
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
    --env "FLEET_WORKTREE=$worktree" --env "FLEET_REGISTRY=$FLEET_REGISTRY" | jq -r .result.pane.pane_id)"
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
    '{name: $name, team: $team, tier: $tier, template: $tpl, harness: $harness, model: $model, repo: $repo,
      machine: $m, status: $status, assignment: $task, herdr_ref: $ref, pane: $pane, workspace: $ws,
      cwd: $cwd, worktree: $wt, branch: $br, expertise_file: $ex}'
}

expertise_for() { local f="$repo/.claude/experts/$1.md"; [ -f "$f" ] && printf '%s' "$f" || true; }

# 3. Start workers, register them, send their briefs.
for i in $(seq 0 $((nworkers - 1))); do
  w="$(printf '%s' "$workers_json" | jq -c ".[$i]")"
  get() { printf '%s' "$w" | jq -r ".$1 // \"\""; }
  kind="$(get kind)"; kind="${kind:-claude}"
  if ! command -v "$kind" >/dev/null 2>&1; then warn "$kind not on PATH; $(get agent) falls back to claude"; kind=claude; fi
  allow="$(printf '%s' "$w" | jq -c '.allow // []')"
  status="$(start_agent "$(get agent)" "$kind" "$(get pane)" "$(get model)" Worker "$(get worktree)" "$allow")"
  ex="$(expertise_for "$(get role)")"
  "$registry" add "$(row "$(get name)" Worker "$(get agent)" "$(get pane)" "$kind" "$(get model)" "$status" "$(get cwd)" "$(get worktree)" "$(get branch)" "$ex")"
  if [ "$status" = "Working" ]; then
    brief="$(render "$(get brief)" "$(get name)" "$(get worktree)" "$worker_agents")$(contract "$(get name)" "$ex")"
    hd agent prompt "$(get agent)" "$brief" >/dev/null 2>&1 || "$registry" set "$(get name)" status="Needs input"
  fi
done

# 4. Start the lead last, so its brief can name live workers.
lead_kind="$(jq -r '.lead.kind // "claude"' "$tpl")"; lead_model="$(jq -r '.lead.model // ""' "$tpl")"
command -v "$lead_kind" >/dev/null 2>&1 || { warn "$lead_kind not on PATH; the lead falls back to claude"; lead_kind=claude; }
status="$(start_agent "$lead_agent" "$lead_kind" "$lead_pane" "$lead_model" Lead "" "$(jq -c '.lead.allow // []' "$tpl")")"
ex="$(expertise_for lead)"
"$registry" add "$(row "$lead_name" Lead "$lead_agent" "$lead_pane" "$lead_kind" "$lead_model" "$status" "$repo" "" "" "$ex")"
if [ "$status" = "Working" ]; then
  brief="$(render "$(jq -r .lead.brief "$tpl")" "$lead_name" "" "$worker_agents")$(contract "$lead_name" "$ex")"
  hd agent prompt "$lead_agent" "$brief" >/dev/null 2>&1 || "$registry" set "$lead_name" status="Needs input"
fi

"$registry" list --team "$team" |
  jq --arg ws "$workspace" --arg team "$team" '{team: $team, workspace: $ws, agents: [.[] | {name, herdr_ref, pane, status, worktree}]}'
