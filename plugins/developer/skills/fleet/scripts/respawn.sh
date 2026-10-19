#!/usr/bin/env bash
# Respawn a dead agent (a Zombie row) from its registry row: same role, worktree, branch, model and
# harness, in its own workspace. tick.sh runs this, within a budget (respawn_max = 1 per
# respawn_window_hours = 6 per agent, config.toml); a Done or Retired row is never respawned.
#
#   respawn.sh <team/role>
#
# The resume brief is `build_brief --resume`: the role brief, the assignment, the last report file,
# `git status` and `git log` of its branch, its open escalations and the old pane's last lines (read
# BEFORE the new agent starts). A lead also gets the plan path and the team's rows. The brief is
# sent through tell.sh --brief, so a brief that does not arrive marks the row Failed. The row gets a
# new session id, so its `transcript` path changes (the old one is kept in the row's `transcripts` list). Logs `respawned` to the event log.
#
# If the row's pane is gone, a new pane is split from the lead's pane in the same workspace.
# UNVERIFIED against real herdr: that `herdr agent start <same name>` is accepted for an agent whose
# pane died (DEV-368).
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"

name="${1:?usage: respawn.sh <team/role>}"
row="$("$registry" get "$name")" || exit 1
get() { printf '%s' "$row" | jq -r ".$1 // \"\""; }
status="$(get status)"
case "$status" in Done | Retired) die "$name is $status; not respawning it" ;; esac

team="$(get team)"; tier="$(get tier)"; agent="$(get herdr_ref)"; pane="$(get pane)"; split_new=0
new_ws=""; cwd="$(get cwd)"; worktree="$(get worktree)"; model="$(get model)"; kind="$(get harness)"; kind="${kind:-claude}"
template="$(get template)"; repo="$(get repo)"; task="$(get assignment)"; ex="$(get expertise_file)"
role="${name#*/}"
tpl="$FLEET_SKILL_DIR/templates/$template.json"
[ -f "$tpl" ] || die "no template '$template' for $name"
tool_allow="$(jq -cn --argjson t "$(config_list tracker_allow)" --argjson f "$(config_list forge_allow)" '$t + $f | unique')"
. "$FLEET_SCRIPTS/agent-lib.sh"

if [ "$tier" = "Lead" ]; then
  allow="$(jq -c '.lead.allow // []' "$tpl")"; brief_tpl="$(jq -r '.lead.brief' "$tpl")"
else
  allow="$(jq -c --arg r "$role" '[.workers[] | select(.role == $r)][0].allow // []' "$tpl")"
  brief_tpl="$(jq -r --arg r "$role" '[.workers[] | select(.role == $r)][0].brief // ""' "$tpl")"
fi
workers="$("$registry" list --team "$team" | jq -r '[.[] | select(.tier == "Worker") | .herdr_ref] | join(", ")')"

# The resume brief first: the old pane's lines are gone once the new agent starts.
brief="$(build_brief --resume "$name" "$ex" "$(render "$brief_tpl" "$name" "$worktree" "$workers")")"

# The pane: reuse the row's, or open a new one. A lead whose pane is gone (a parked team) gets a new workspace,
# as boot makes it; any other agent is split from the lead's pane in the team's workspace.
if ! hd pane process-info --pane "$pane" >/dev/null 2>&1; then
  env_args=(); [ -z "$(env_config "$repo")" ] || env_args=(--env "KUBECONFIG=$(env_dir "$team")/kubeconfig")
  if [ "$tier" = "Lead" ]; then
    ws_json="$(hd workspace create --cwd "${cwd:-$repo}" --label "$team" --no-focus \
      --env FLEET_ROLE=lead --env "FLEET_NAME=$name" --env "FLEET_TEAM=$team" --env "FLEET_STATE_DIR=$FLEET_STATE_DIR" ${env_args[@]+"${env_args[@]}"})" ||
      die "could not open a workspace for $name"
    pane="$(printf '%s' "$ws_json" | jq -r .result.root_pane.pane_id)"; new_ws="$(printf '%s' "$ws_json" | jq -r .result.workspace.workspace_id)"
  else
    lead_pane="$("$registry" list --team "$team" | jq -r '[.[] | select(.tier == "Lead") | .pane] | first // ""')"
    [ -n "$lead_pane" ] || die "$name's pane is gone and the team has no lead pane to split from"
    pane="$(hd pane split --pane "$lead_pane" --direction down --cwd "${cwd:-$repo}" --no-focus \
      --env "FLEET_ROLE=$(printf '%s' "$tier" | tr 'A-Z' 'a-z')" --env "FLEET_NAME=$name" --env "FLEET_TEAM=$team" \
      --env "FLEET_WORKTREE=$worktree" --env "FLEET_STATE_DIR=$FLEET_STATE_DIR" ${env_args[@]+"${env_args[@]}"} | jq -r .result.pane.pane_id)"
  fi
  [ -n "$pane" ] && [ "$pane" != null ] || die "could not open a new pane for $name"
  split_new=1
fi

session_id=""; transcript=""
if [ "$kind" = claude ]; then
  session_id="$(new_uuid)"; transcript="$(transcript_dir_for "${cwd:-$repo}")/$session_id.jsonl"
fi
new_status="$(start_agent "$agent" "$kind" "$pane" "$model" "$tier" "$worktree" "$allow")"
if [ "$new_status" = Zombie ]; then
  # A pane this run split is closed, not left behind; the row keeps its old pane and the next attempt splits again.
  if [ "$split_new" = 1 ]; then hd pane close "$pane" >/dev/null 2>&1 || warn "could not close pane $pane"; fi
  die "$name did not start again; row stays Zombie"
fi
set_args=(status="$new_status" pane="$pane")
[ -z "$new_ws" ] || [ "$new_ws" = null ] || set_args+=(workspace="$new_ws")
if [ -n "$transcript" ]; then
  old_t="$(get transcript)"; [ -z "$old_t" ] || "$registry" append "$name" transcripts "$old_t" >/dev/null
  set_args+=(transcript="$transcript")
fi
"$registry" set "$name" "${set_args[@]}" >/dev/null
ev_log respawned team="$team" name="$name" detail="new pane $pane"

if [ "$new_status" = Working ]; then
  "$FLEET_SCRIPTS/tell.sh" "$name" "$brief" --brief >/dev/null || { "$registry" set "$name" status=Failed >/dev/null; die "the resume brief did not reach $name; row set to Failed"; }
fi
jq -cn --arg n "$name" --arg s "$new_status" '{respawned: $n, status: $s}'
