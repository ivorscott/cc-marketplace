#!/usr/bin/env bash
# Bring a finished, parked or exited team back, in its own worktrees, and give its lead one thing to do. catchup.sh (a
# PR that conflicts now) and tell.sh (a message to a team that is not running) use it. Local teams only.
#
#   revive.sh <team> --text TEXT [--why WHY] [--event NAME] [--pr URL]
#
# A Parked team comes back through unpark.sh (the max_teams and teams_per_repo checks; FLEET_FORCE=1 overrides); any other
# team that is not live is checked against the same caps. Then each agent that is Done or Zombie, or whose pane is gone,
# is started again with respawn.sh --revive, lead first (a live agent is left alone; a worker comes back Idle, the lead
# Working). The lead's resume brief carries TEXT ("What to do now: ..."), so it gets no second brief; a lead that was
# still running is given TEXT by tell.sh (a brief when idle, else a message). Nothing but the rows' status changes: the PR,
# branch, worktrees and sign-off history stay. Nothing is charged to the respawn budget. Logs `revived` (or --event) and
# prints "Revived <team>: <roles> back." Exit 1 with the reason on stderr when the team does not come back (a cap is full,
# herdr does not answer, an agent did not start) or the lead did not take the text; --pr names the PR in the log line.
# Command: Bring a finished or parked team back with something to do · e.g. fleet revive build-api --text "the PR needs a review reply"
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
[ -z "${FLEET_ROLE:-}" ] || die "revive is the Orchestrator's; an agent (FLEET_ROLE=$FLEET_ROLE) may not run it"
registry="$FLEET_SCRIPTS/registry.sh"

usage="usage: revive.sh <team> --text TEXT [--why WHY] [--event NAME] [--pr URL]"
team="${1:?$usage}"; shift
procedure=""; why="your team was finished and has been brought back"; evname=revived; pr=""
while [ $# -gt 0 ]; do
  case "$1" in
    --text) procedure="${2:?--text needs text}"; shift 2 ;;
    --why) why="${2:?--why needs text}"; shift 2 ;;
    --event) evname="${2:?--event needs a name}"; shift 2 ;;
    --pr) pr="${2:?--pr needs a URL}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
[ -n "$procedure" ] || die "$usage"
rows="$("$registry" list --team "$team" | jq -c '[.[] | select(.status != "Retired" and .tier != "Orchestrator")]')"
[ "$(jq length <<<"$rows")" != 0 ] || die "no team '$team' on this machine" "Run fleet status"
lead="$(jq -r '[.[] | select(.tier == "Lead") | .name] | first // ""' <<<"$rows")"
[ -n "$lead" ] || die "team '$team' has no lead row"
lead_respawned=false
parked="$(jq 'any(.[]; .status == "Parked")' <<<"$rows")"
if [ "$parked" = true ]; then
  [ "$(jq -r --arg l "$lead" '.[] | select(.name == $l) | .status' <<<"$rows")" != Parked ] || lead_respawned=true # its resume brief carries the procedure
  FLEET_RESUME_WHY="$why. What to do now: $procedure" "$FLEET_SCRIPTS/unpark.sh" "$team" >/dev/null 2>"$FLEET_STATE_DIR/revive.step.err" ||
    die "$(grep -v '^fleet: warning:' "$FLEET_STATE_DIR/revive.step.err" | head -n 1 | sed 's/^fleet: //')"
  rm -f "$FLEET_STATE_DIR/revive.step.err"
  rows="$("$registry" list --team "$team" | jq -c '[.[] | select(.status != "Retired" and .tier != "Orchestrator")]')"
elif [ "${FLEET_FORCE:-}" != 1 ]; then
  cap_t="$(max_teams)"; live="$(live_team_count "$team")"
  [ "$live" -lt "$cap_t" ] || die "not bringing $team back: $live live team(s), max_teams=$cap_t; park or retire one first"
  repo="$(jq -r '[.[] | .repo // ""] | first // ""' <<<"$rows")"; others="$(teams_on_repo "$repo" "$team")"
  if [ -n "$repo" ] && [ -n "$others" ] && [ "$(printf '%s\n' "$others" | grep -c .)" -ge "$(teams_per_repo)" ]; then
    die "not bringing $team back: $(printf '%s' "$others" | paste -sd, -) live on $repo, teams_per_repo=$(teams_per_repo)"
  fi
fi
hd agent list >/dev/null 2>&1 || die "herdr is not answering; $team stays as it is"

# An agent is alive when herdr knows it and its pane is not back at the shell.
alive() { # alive <row JSON>
  local ref pane
  ref="$(jq -r '.herdr_ref // ""' <<<"$1")"; pane="$(jq -r '.pane // ""' <<<"$1")"
  [ -n "$ref" ] || return 1
  [ "$(hd agent get "$ref" 2>/dev/null | jq -r '.result.agent.agent_status // "gone"' 2>/dev/null || echo gone)" != gone ] || return 1
  [ -z "$pane" ] || hd pane process-info --pane "$pane" 2>/dev/null | jq -e '.result.process_info | .foreground_process_group_id != .shell_pid' >/dev/null 2>&1
}

revived=(); failed=()
for tier in Lead Worker; do
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    name="$(jq -r .name <<<"$r")"; st="$(jq -r .status <<<"$r")"
    if alive "$r"; then
      # Still running: its row only has to stop saying Done.
      if [ "$st" = Done ]; then
        "$registry" set "$name" status="$([ "$tier" = Lead ] && echo Working || echo Idle)" outcome= summary= done_at= >/dev/null
      fi
      continue
    fi
    case "$st" in
      Done | Zombie | Working | Idle | Stalled | Failed | "Needs input" | Booting)
        # The lead's resume brief carries the procedure, so it needs no second brief (the first one keeps it busy).
        if [ "$tier" = Lead ]; then export FLEET_RESUME_WHY="$why. What to do now: $procedure"; else export FLEET_RESUME_WHY="$why"; fi
        if "$FLEET_SCRIPTS/respawn.sh" "$name" --revive >/dev/null 2>"$FLEET_STATE_DIR/revive.step.err"; then
          revived+=("${name#*/}"); [ "$tier" != Lead ] || lead_respawned=true
        else failed+=("$name"); warn "could not bring back $name: $(head -n 1 "$FLEET_STATE_DIR/revive.step.err" 2>/dev/null)"; fi ;;
    esac
  done < <(jq -c --arg t "$tier" '.[] | select(.tier == $t)' <<<"$rows")
done
rm -f "$FLEET_STATE_DIR/revive.step.err"
[ "${#failed[@]}" = 0 ] || die "${failed[*]} did not start; $team is not brought back" "Run fleet respawn ${failed[0]}"

told=$lead_respawned
if ! $told; then
  # A lead that was still running: a brief when it is idle, else a plain message it takes after its turn.
  "$FLEET_SCRIPTS/tell.sh" "$lead" "$procedure" --brief >/dev/null 2>&1 && told=true
  $told || { "$FLEET_SCRIPTS/tell.sh" "$lead" "$(printf '%s' "$procedure" | tr '\n' ' ')" >/dev/null 2>&1 && told=true; }
fi
"$registry" set "$lead" status=Working >/dev/null 2>&1 || true
# A worker comes back Idle (the lead hands it work); the next status reads herdr's word for it.
for w in $(jq -r '.[] | select(.tier == "Worker") | .name' <<<"$rows"); do
  case "$("$registry" get "$w" | jq -r .status)" in Working | Booting) "$registry" set "$w" status=Idle >/dev/null 2>&1 || true ;; esac
done
ev_log "$evname" team="$team" name="$lead" detail="${pr:-$why}"
herdr_meta "$team"
$told || die "$team is back but its lead did not take the text" "Tell $lead again"
printf 'Revived %s: %s back.\n' "$team" "$( (IFS=,; printf '%s' "${revived[*]:-nothing needed}") | sed 's/,/, /g')"
