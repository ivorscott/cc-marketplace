#!/usr/bin/env bash
# Bring a parked team back: respawn each of its rows with the shared resume brief (respawn.sh), lead first.
#
#   unpark.sh <team>
#
# Nothing is charged to the respawn budget. It refuses at once, with the team still Parked, when the team
# is not Parked, when max_teams live teams already run, or when another live team works the same repo
# (FLEET_FORCE=1 overrides the last two). A row that does not start stays Parked; run unpark.sh again for it.
# Command: Bring a parked team back · e.g. fleet unpark build-api
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
[ -z "${FLEET_ROLE:-}" ] || die "unpark is the Orchestrator's; an agent (FLEET_ROLE=$FLEET_ROLE) may not run it"
registry="$FLEET_SCRIPTS/registry.sh"

team="${1:?usage: unpark.sh <team>}"
rows="$("$registry" list --team "$team" --parked)"
[ "$(printf '%s' "$rows" | jq length)" != 0 ] || die "team '$team' is not parked"

if [ "${FLEET_FORCE:-}" != 1 ]; then
  cap="$(max_teams)"; live="$(live_team_count "$team")"
  [ "$live" -lt "$cap" ] || die "not unparking $team: $live live team(s), max_teams=$cap; park or retire one first"
  repo="$(printf '%s' "$rows" | jq -r '[.[] | .repo // ""] | first // ""')"
  others="$(teams_on_repo "$repo" "$team")"
  if [ -n "$repo" ] && [ -n "$others" ] && [ "$(printf '%s\n' "$others" | grep -c .)" -ge "$(teams_per_repo)" ]; then
    die "not unparking $team: $(printf '%s' "$others" | paste -sd, -) live on $repo, teams_per_repo=$(teams_per_repo)"
  fi
fi
hd agent list >/dev/null 2>&1 || die "herdr is not answering; $team stays parked"

export FLEET_RESUME_WHY="you were parked and the user has brought you back; your panes were closed, nothing else was lost"
failed=()
for tier in Lead Worker; do
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if "$FLEET_SCRIPTS/respawn.sh" "$name" >/dev/null 2>"$FLEET_STATE_DIR/unpark.err"; then
      "$registry" set "$name" parked_at= parked_reason= park_after_merge= >/dev/null
      if [ "$tier" = Lead ]; then
        ws="$("$registry" get "$name" | jq -r '.workspace // ""')"
        for w in $("$registry" list --team "$team" --parked | jq -r '.[].name'); do
          [ -z "$ws" ] || "$registry" set "$w" workspace="$ws" >/dev/null
        done
      fi
    else
      failed+=("$name"); warn "could not bring back $name: $(head -n 1 "$FLEET_STATE_DIR/unpark.err" 2>/dev/null)"
    fi
  done < <(printf '%s' "$rows" | jq -r --arg t "$tier" '.[] | select(.tier == $t) | .name')
done
rm -f "$FLEET_STATE_DIR/unpark.err"
if [ "${#failed[@]}" -gt 0 ]; then
  jq -cn --arg t "$team" --arg f "${failed[*]}" '{team: $t, unparked: false, still_parked: ($f | split(" "))}'
  exit 1
fi
ev_log unparked team="$team"
jq -cn --arg t "$team" '{team: $t, unparked: true}'
