#!/usr/bin/env bash
# Bring a finished team back to catch its PR up with the base branch after another PR merged ahead of it and now
# conflicts with it. tick.sh runs this on a conflict when the team is Parked or any of its agents is Done, Zombie or
# gone (a team whose agents are live is only told). Local teams only: a team another machine holds is that machine's.
#
#   catchup.sh <team> <pr-url> [<merged-by>]
#
# <merged-by> names the PR(s) merged ahead of it, for the lead's brief. A Parked team comes back through unpark.sh (the
# same max_teams and teams_per_repo checks, FLEET_FORCE=1 overrides); any other team that is not live is checked against
# the same caps. Then each agent that is Done or Zombie, or whose pane is gone, is started again in its own worktree
# with respawn.sh --revive, lead first (a live agent is left alone), and the lead gets a brief (tell.sh --brief) with the
# procedure: git fetch origin; git merge origin/main in the PR's branch (a merge commit, no history is rewritten);
# resolve the conflicts; run the repo's verify; a plain git push; the tester signs the new head off again. A conflict
# it cannot resolve is a P1 escalation. Nothing is charged to the respawn budget; tick.sh counts the rounds per PR
# (at most 2, then a P1 escalation instead of another round). It prints "Caught up <team>: ..." and logs
# `catchup` to the event log. Exit 1 with the reason on stderr when the team is not brought back (a cap is full, herdr
# does not answer), the team as it was.
# Command: Bring a finished team back to merge main into its conflicting PR · e.g. fleet catchup build-api https://github.com/acme/app-api/pull/12
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
[ -z "${FLEET_ROLE:-}" ] || die "catchup is the Orchestrator's; an agent (FLEET_ROLE=$FLEET_ROLE) may not run it"
registry="$FLEET_SCRIPTS/registry.sh"

usage="usage: catchup.sh <team> <pr-url> [<merged-by>]"
team="${1:?$usage}"; pr="${2:?$usage}"; by="${3:-}"
rows="$("$registry" list --team "$team" | jq -c '[.[] | select(.status != "Retired" and .tier != "Orchestrator")]')"
[ "$(jq length <<<"$rows")" != 0 ] || die "no team '$team' on this machine" "Run fleet status"
lead="$(jq -r '[.[] | select(.tier == "Lead") | .name] | first // ""' <<<"$rows")"
[ -n "$lead" ] || die "team '$team' has no lead row"

# What the lead must do, as the lead's brief puts it (no history is rewritten: a merge commit and a plain push).
procedure="$(
  printf 'PR %s conflicts with its base now' "$pr"
  if [ -n "$by" ]; then printf ' (%s merged ahead of it)' "$by"; fi
  printf '. Bring it up to date by merging, in your PR branch:\n1. git fetch origin\n2. git merge origin/main (a merge commit; no history is rewritten)\n'
  printf '3. resolve the conflicts, keeping both sides intent\n4. run the repo'"'"'s verify command and show its result\n5. a plain git push of your branch\n'
  printf '6. have the tester sign off the new head (registry.sh signoff) so the PR is ready again\n'
  printf 'Your builder and tester are started again in their worktrees for this. If a conflict cannot be resolved safely, escalate it P1 with the files in conflict and do not push a guess.\n'
)"
why="another PR merged ahead of $pr and it conflicts now; your team was finished and has been brought back to catch it up"
lead_respawned=false
parked="$(jq 'any(.[]; .status == "Parked")' <<<"$rows")"
if [ "$parked" = true ]; then
  [ "$(jq -r --arg l "$lead" '.[] | select(.name == $l) | .status' <<<"$rows")" != Parked ] || lead_respawned=true # its resume brief carries the procedure
  FLEET_RESUME_WHY="$why. What to do now: $procedure" "$FLEET_SCRIPTS/unpark.sh" "$team" >/dev/null 2>"$FLEET_STATE_DIR/catchup.step.err" ||
    die "$(grep -v '^fleet: warning:' "$FLEET_STATE_DIR/catchup.step.err" | head -n 1 | sed 's/^fleet: //')"
  rm -f "$FLEET_STATE_DIR/catchup.step.err"
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
        if "$FLEET_SCRIPTS/respawn.sh" "$name" --revive >/dev/null 2>"$FLEET_STATE_DIR/catchup.step.err"; then
          revived+=("${name#*/}"); [ "$tier" != Lead ] || lead_respawned=true
        else failed+=("$name"); warn "could not bring back $name: $(head -n 1 "$FLEET_STATE_DIR/catchup.step.err" 2>/dev/null)"; fi ;;
    esac
  done < <(jq -c --arg t "$tier" '.[] | select(.tier == $t)' <<<"$rows")
done
rm -f "$FLEET_STATE_DIR/catchup.step.err"
[ "${#failed[@]}" = 0 ] || die "${failed[*]} did not start; the catch-up of $pr is not done" "Run fleet respawn ${failed[0]}"

told=$lead_respawned
if ! $told; then
  # A lead that was still running: a brief when it is idle, else a plain message it takes after its turn.
  "$FLEET_SCRIPTS/tell.sh" "$lead" "$procedure" --brief >/dev/null 2>&1 && told=true
  $told || { "$FLEET_SCRIPTS/tell.sh" "$lead" "$(printf '%s' "$procedure" | tr '\n' ' ')" >/dev/null 2>&1 && told=true; }
fi
"$registry" set "$lead" status=Working >/dev/null 2>&1 || true
ev_log catchup team="$team" name="$lead" detail="$pr${by:+ after $by}"
herdr_meta "$team"
$told || die "$team is back but its lead did not take the brief" "Tell $lead to merge origin/main into $pr"
printf 'Caught up %s: %s back; lead told to merge main into %s.\n' "$team" "$( (IFS=,; printf '%s' "${revived[*]:-nothing needed}") | sed 's/,/, /g')" "$pr"
