#!/usr/bin/env bash
# Focus the fleet on one team by parking every other live team (park.sh, reason focus:<team>).
#
#   focus.sh <team> [--now]   the others park once their PR is merged (park --after-merge); --now parks them at
#                             once, and a team that cannot park now (a dirty worktree) is named and keeps working
#   focus.sh --clear          unparks only the teams this focus parked (unpark.sh; a full cap refuses that team,
#                             nothing queues) and drops the after-merge marks it set; teams parked otherwise stay
#   focus.sh                  the focus as JSON ({} when there is none)
#
# The focus lives in $FLEET_STATE_DIR/focus.json ({team, at}); status shows it on one line. One focus at a time:
# focusing on the same team again changes nothing, another team needs --clear first. Holds tick.lock while it
# works, like park and unpark. Logs focus_set and focus_cleared. Fleet agents (FLEET_ROLE set) may not focus.
# Exits 1 when a team could not be parked or unparked (the JSON's refused list says which and why).
set -euo pipefail
. "$(dirname "$0")/common.sh"
registry="$FLEET_SCRIPTS/registry.sh"
ff="$(focus_file)"

current() { if [ -f "$ff" ] && jq -e 'type == "object" and (.team | type == "string")' "$ff" >/dev/null 2>&1; then cat "$ff"; else printf '{}\n'; fi; }
if [ $# -eq 0 ]; then current | jq -c .; exit 0; fi
require_herdr
[ -z "${FLEET_ROLE:-}" ] || die "focus is the Orchestrator's command; a fleet agent may not focus the fleet"

clear=false; now_=false; team=""
while [ $# -gt 0 ]; do
  case "$1" in
    --clear) clear=true; shift ;;
    --now) now_=true; shift ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$team" ] || die "usage: focus.sh <team> [--now] | --clear"; team="$1"; shift ;;
  esac
done
cur="$(current | jq -r '.team // ""')"
refused="[]"
refuse() { refused="$(jq -cn --argjson r "$refused" --arg t "$1" --arg w "$2" '$r + [{team: $t, reason: $w}]')"; }
locked() { # take tick.lock and a temp file for the stderr of park and unpark; both go at exit
  tick_lock_take || return 1
  errf="$(mktemp "${TMPDIR:-/tmp}/fleet-focus.XXXXXX")"
  trap 'rm -rf "$FLEET_STATE_DIR/tick.lock" "$errf"' EXIT
}

if $clear; then
  [ -z "$team" ] && ! $now_ || die "usage: focus.sh --clear"
  if [ -z "$cur" ]; then warn "there is no focus to clear"; printf '{}\n'; exit 0; fi
  locked || die "a tick is running (tick.lock); the focus on $cur stays. Try again in a minute"
  rows="$("$registry" list | jq -c '[.[] | select(.status != "Retired" and .tier != "Orchestrator")]')"
  back=()
  for t in $(printf '%s' "$rows" | jq -r --arg r "focus:$cur" '[.[] | select(.status == "Parked" and .parked_reason == $r) | .team] | unique[]'); do
    if "$FLEET_SCRIPTS/unpark.sh" "$t" >/dev/null 2>"$errf"; then back+=("$t")
    else refuse "$t" "$(grep -v '^fleet: warning' "$errf" | head -n 1 | sed 's/^fleet: //')"; fi
  done
  for n in $(printf '%s' "$rows" | jq -r --arg r "focus:$cur" '.[] | select(.status != "Parked" and .park_after_merge == $r) | .name'); do
    "$registry" set "$n" park_after_merge= >/dev/null
  done
  rm -f "$ff"
  ev_log focus_cleared team="$cur" detail="${back[*]:+unparked: ${back[*]}}"
  jq -cn --arg t "$cur" --argjson r "$refused" --arg b "${back[*]:-}" \
    '{cleared: $t, unparked: ($b | split(" ") | map(select(. != ""))), refused: $r}'
  [ "$refused" = "[]" ] || exit 1
  exit 0
fi

[ -n "$team" ] || die "usage: focus.sh <team> [--now] | --clear"
rows="$("$registry" list | jq -c '[.[] | select(.status != "Retired" and .tier != "Orchestrator")]')"
printf '%s' "$rows" | jq -e --arg t "$team" 'any(.[]; .team == $t)' >/dev/null || die "no team '$team' with live rows"
if [ "$cur" = "$team" ]; then warn "the focus is already on $team"; current | jq -c .; exit 0; fi
[ -z "$cur" ] || die "the focus is on $cur; run focus.sh --clear first"
! printf '%s' "$rows" | jq -e --arg t "$team" 'any(.[]; .team == $t and .status == "Parked")' >/dev/null || die "$team is parked; unpark it before focusing on it"

locked || die "a tick is running (tick.lock); no focus set. Try again in a minute"
mode=(--after-merge); ! $now_ || mode=()
parked=()
# Every other team with an agent that is not Done or Parked; a team someone parked already is left alone.
for t in $(printf '%s' "$rows" | jq -r --arg t "$team" '[.[] | select(.team != $t and .status != "Done" and .status != "Parked") | .team] | unique[]'); do
  if "$FLEET_SCRIPTS/park.sh" "$t" --reason "focus:$team" ${mode[@]+"${mode[@]}"} >/dev/null 2>"$errf"; then parked+=("$t")
  else refuse "$t" "$(grep -v '^fleet: warning' "$errf" | head -n 1 | sed 's/^fleet: //')"; fi
done
jq -cn --arg t "$team" --arg at "${FLEET_NOW:-$(now)}" '{team: $t, at: $at}' >"$ff"
ev_log focus_set team="$team" detail="${parked[*]:+$($now_ && echo parked || echo parks after merge): ${parked[*]}}"
jq -cn --arg t "$team" --argjson now "$($now_ && echo true || echo false)" --arg p "${parked[*]:-}" --argjson r "$refused" \
  '{focus: $t, (if $now then "parked" else "parks_after_merge" end): ($p | split(" ") | map(select(. != ""))), refused: $r}'
[ "$refused" = "[]" ] || exit 1
