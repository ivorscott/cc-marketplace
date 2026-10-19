#!/usr/bin/env bash
# Park a team: close its panes and keep everything else. A parked team holds no agent or team slot
# (max_agents, max_teams), and tick leaves it alone: no nudge, respawn, next or repo_without_team (it still
# covers its repo), and it never shows as Stalled or Zombie. unpark.sh brings it back.
#
#   park.sh <team> [--after-merge] [--reason park|after-merge|focus:<team>]
#
# Now (the default):
#   - refuses at once, changing nothing, when a worktree of the team has uncommitted edits, untracked source
#     files or unpushed commits (retire's rules, worktree-lib.sh), when herdr does not answer, or when a tick
#     holds tick.lock for longer than FLEET_LOCK_WAIT_SECS (30);
#   - closes the team's workspace (its panes), then sets every row that is not Retired to Parked in one
#     registry write (parked_at, parked_reason, parked_from = the status before);
#   - keeps the rows, worktrees, branches, plans, reports and the tracker claim (no tracker call: the
#     heartbeat goes on, so the claim does not lapse). Logs `parked`.
# --after-merge: marks the rows park_after_merge=<reason> and changes nothing else; the team keeps working,
#   and tick parks it when its PR is merged, instead of the Orchestrator running next.
# A team that is already parked is left as it is (exit 0). Fleet agents (FLEET_ROLE set) may not park.
# Prints {"team", "parked", "reason"} as JSON.
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"
[ -z "${FLEET_ROLE:-}" ] || die "park is the Orchestrator's command; a fleet agent may not park a team"

usage="usage: park.sh <team> [--after-merge] [--reason park|after-merge|focus:<team>]"
team="${1:?$usage}"; shift
after=false; reason=""
while [ $# -gt 0 ]; do
  case "$1" in
    --after-merge) after=true; shift ;;
    --reason) reason="${2:?--reason needs a value}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
if [ -z "$reason" ]; then if $after; then reason=after-merge; else reason=park; fi; fi
case "$reason" in park | after-merge | focus:?*) ;; *) die "--reason must be park, after-merge or focus:<team>" ;; esac

rows="$("$registry" list --team "$team" | jq -c '[.[] | select(.status != "Retired" and .tier != "Orchestrator")]')"
[ "$(printf '%s' "$rows" | jq length)" != 0 ] || die "no team '$team' with live rows"
if printf '%s' "$rows" | jq -e 'any(.[]; .status == "Parked")' >/dev/null; then
  warn "$team is already parked ($(printf '%s' "$rows" | jq -r '[.[] | .parked_reason // empty] | first // "park"'))"
  jq -cn --arg t "$team" --arg r "$(printf '%s' "$rows" | jq -r '[.[] | .parked_reason // empty] | first // "park"')" '{team: $t, parked: true, reason: $r}'
  exit 0
fi

if $after; then
  for n in $(printf '%s' "$rows" | jq -r '.[].name'); do "$registry" set "$n" park_after_merge="$reason" >/dev/null; done
  jq -cn --arg t "$team" --arg r "$reason" '{team: $t, parked: false, reason: $r, parks: "after merge"}'
  exit 0
fi

tick_lock_take || die "a tick is running (tick.lock); $team is not parked. Try again in a minute"
hd agent list >/dev/null 2>&1 || die "herdr does not answer; $team is not parked and its rows are unchanged"
# Read the rows again under the lock: a tick may have changed them while park waited.
rows="$("$registry" list --team "$team" | jq -c '[.[] | select(.status != "Retired" and .tier != "Orchestrator")]')"

. "$FLEET_SCRIPTS/worktree-lib.sh"
dirty=""
while IFS=$'\t' read -r name wt; do
  [ -d "$wt" ] || continue
  classify "$wt"
  what=""
  [ -z "$C_MODIFIED" ] || what="uncommitted edits"
  [ -z "$C_SOURCE" ] || what="${what:+$what, }untracked files ($(printf '%s\n' "$C_SOURCE" | head -n 3 | tr '\n' ' ' | sed 's/ $//'))"
  [ -z "$C_UNPUSHED" ] || what="${what:+$what, }$(printf '%s\n' "$C_UNPUSHED" | grep -c .) unpushed commit(s)"
  [ -z "$what" ] || dirty="${dirty:+$dirty; }$name: $what"
done < <(printf '%s' "$rows" | jq -r '.[] | select((.worktree // "") != "") | [.name, .worktree] | @tsv')
[ -z "$dirty" ] || die "$team is not parked: $dirty. Have the team commit and push first"

ws="$(printf '%s' "$rows" | jq -r '[.[].workspace | select(. != null and . != "")] | first // ""')"
if [ -n "$ws" ]; then
  hd workspace close "$ws" >/dev/null 2>&1 || die "could not close workspace $ws; $team is not parked and its rows are unchanged"
else
  for pane in $(printf '%s' "$rows" | jq -r '.[].pane // empty'); do
    hd pane close "$pane" >/dev/null 2>&1 || warn "could not close pane $pane"
  done
fi
"$registry" park "$team" "$reason" >/dev/null
ev_log parked team="$team" detail="$reason"
jq -cn --arg t "$team" --arg r "$reason" '{team: $t, parked: true, reason: $r}'
