#!/usr/bin/env bash
# Unpark a parked team: start its agents again from their rows, with the resume brief respawn.sh sends (the
# role brief, assignment, last report, `git status` and `git log`, open escalations; one shared brief). Same
# roles, worktrees, branches, models and harnesses. No respawn budget is spent: that budget is tick's.
#
#   unpark.sh <team>
#
# Refuses at once, changing nothing, when the caps are full (max_agents, max_teams, teams_per_repo; see
# caps_check in common.sh; there is no queue), when herdr does not answer, or when a tick holds tick.lock
# longer than FLEET_LOCK_WAIT_SECS (30). Otherwise it opens a new workspace for the team (the lead in its root
# pane), respawns the workers (each in a pane split from the lead's) and then the lead, so the lead's brief
# names live workers. A row that was Done when parked comes back Done, told to wait for its lead.
# The claim was never released, so nothing is claimed again. Logs `unparked`.
# A row whose agent does not start stays Parked and unpark exits 1; running unpark again retries only those.
# A team that is not parked is left as it is (exit 0). Fleet agents (FLEET_ROLE set) may not unpark.
# Prints {"team", "unparked", "agents": [{name, status}]} as JSON.
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"
[ -z "${FLEET_ROLE:-}" ] || die "unpark is the Orchestrator's command; a fleet agent may not unpark a team"

team="${1:?usage: unpark.sh <team>}"; [ $# -le 1 ] || die "usage: unpark.sh <team>"
team_rows() { "$registry" list --team "$team" | jq -c '[.[] | select(.status != "Retired" and .tier != "Orchestrator")]'; }
rows="$(team_rows)"
[ "$(printf '%s' "$rows" | jq length)" != 0 ] || die "no team '$team' with live rows"
if ! printf '%s' "$rows" | jq -e 'any(.[]; .status == "Parked")' >/dev/null; then
  warn "$team is not parked"; jq -cn --arg t "$team" '{team: $t, unparked: false}'; exit 0
fi

tick_lock_take || die "a tick is running (tick.lock); $team stays parked. Try again in a minute"
hd agent list >/dev/null 2>&1 || die "herdr does not answer; $team stays parked"
rows="$(team_rows)"
lead="$(printf '%s' "$rows" | jq -r '[.[] | select(.tier == "Lead") | .name] | first // ""')"
[ -n "$lead" ] || die "$team has no lead row to unpark around"
repo="$(printf '%s' "$rows" | jq -r --arg l "$lead" '.[] | select(.name == $l) | .repo // ""')"
caps_check "$team" "$repo" "$(printf '%s' "$rows" | jq '[.[] | select(.status == "Parked" and .parked_from != "Done")] | length')"

# The workspace went with the panes at park: a new one, the lead in its root pane, the same env as boot gives it.
if [ "$(printf '%s' "$rows" | jq -r --arg l "$lead" '.[] | select(.name == $l) | .status')" = Parked ]; then
  env_args=(); [ -z "$(env_config "$repo")" ] || env_args=(--env "KUBECONFIG=$(env_dir "$team")/kubeconfig")
  ws_json="$(hd workspace create --cwd "$repo" --label "$team" --no-focus \
    --env FLEET_ROLE=lead --env "FLEET_NAME=$lead" --env "FLEET_TEAM=$team" --env "FLEET_REGISTRY=$FLEET_REGISTRY" ${env_args[@]+"${env_args[@]}"})" || ws_json=""
  ws="$(printf '%s' "$ws_json" | jq -r '.result.workspace.workspace_id // ""' 2>/dev/null || true)"
  lead_pane="$(printf '%s' "$ws_json" | jq -r '.result.root_pane.pane_id // ""' 2>/dev/null || true)"
  [ -n "$ws" ] && [ -n "$lead_pane" ] || die "workspace create failed for $team; it stays parked: $ws_json"
  for n in $(printf '%s' "$rows" | jq -r '.[].name'); do "$registry" set "$n" workspace="$ws" >/dev/null; done
  "$registry" set "$lead" pane="$lead_pane" >/dev/null
fi

failed=()
restore() { # restore <name>: respawn one Parked row, then clear its park fields (a Done row goes back to Done)
  local from
  from="$(printf '%s' "$rows" | jq -r --arg n "$1" '.[] | select(.name == $n) | .parked_from // ""')"
  if ! "$FLEET_SCRIPTS/respawn.sh" "$1" >/dev/null; then failed+=("$1"); return 0; fi
  if [ "$from" = Done ]; then "$registry" set "$1" status=Done >/dev/null; fi
  "$registry" set "$1" parked_at= parked_reason= parked_from= >/dev/null
}
for n in $(printf '%s' "$rows" | jq -r '.[] | select(.status == "Parked" and .tier != "Lead") | .name'); do restore "$n"; done
for n in $(printf '%s' "$rows" | jq -r '.[] | select(.status == "Parked" and .tier == "Lead") | .name'); do restore "$n"; done

ev_log unparked team="$team" detail="${failed[*]:+not started: ${failed[*]}}"
team_rows | jq --arg t "$team" --argjson ok "$([ "${#failed[@]}" = 0 ] && echo true || echo false)" \
  '{team: $t, unparked: $ok, agents: [.[] | {name, status}]}'
if [ "${#failed[@]}" -gt 0 ]; then
  warn "did not start: ${failed[*]} (still Parked; run unpark again)"
  exit 1
fi
