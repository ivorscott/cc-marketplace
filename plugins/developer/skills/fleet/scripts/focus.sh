#!/usr/bin/env bash
# Focus on one team: park every other live team, so the user's attention and the slots go to it.
#
#   focus.sh <team> [--now]     park the other live teams after their PRs merge (--now: right away)
#   focus.sh --clear            drop the focus and unpark only the teams focus parked (focus:<team>)
#   focus.sh                    show the focus as JSON ({} when there is none)
#
# The output lists "parked" (--now) or "marked" teams. A team that cannot be parked (uncommitted work, herdr down) or unparked (the caps are full) is named in the
# output's "refused" list and stays as it was; the others go through, and focus.sh exits 1. The focus is one line
# in the status.
# Command: Park every other team so one team gets the slots · e.g. fleet focus build-api --now
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
[ -z "${FLEET_ROLE:-}" ] || die "focus is the Orchestrator's; an agent (FLEET_ROLE=$FLEET_ROLE) may not run it"
registry="$FLEET_SCRIPTS/registry.sh"
ffile="$FLEET_STATE_DIR/focus"

if [ $# -eq 0 ]; then
  if [ -f "$ffile" ]; then jq -cn --arg t "$(cat "$ffile")" '{focus: $t}'; else echo '{}'; fi
  exit 0
fi
arg="$1"; shift
done_list=(); refused=()

if [ "$arg" = "--clear" ]; then
  [ -f "$ffile" ] || die "no focus is set"
  ft="$(cat "$ffile")"
  rm -f "$ffile"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if "$FLEET_SCRIPTS/unpark.sh" "$t" >/dev/null 2>&1; then done_list+=("$t"); else refused+=("$t"); fi
  done < <("$registry" list --parked | jq -r '[.[] | select((.parked_reason // "") | startswith("focus:")) | .team] | unique[]')
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    "$registry" park-mark "$t" - >/dev/null
  done < <("$registry" list | jq -r '[.[] | select((.park_after_merge // "") | startswith("focus:")) | .team] | unique[]')
  ev_log focus_cleared team="$ft"
  jq -cn --arg t "$ft" --arg d "${done_list[*]-}" --arg r "${refused[*]-}" '{focus_cleared: $t, unparked: ($d | split(" ") | map(select(. != ""))), refused: ($r | split(" ") | map(select(. != "")))}'
  [ "${#refused[@]}" = 0 ] || exit 1
  exit 0
fi

team="$arg"; now_flag=0
while [ $# -gt 0 ]; do
  case "$1" in --now) now_flag=1; shift ;; *) die "unknown option: $1" ;; esac
done
[ "$("$registry" list --team "$team" --live | jq length)" != 0 ] || die "team '$team' has no live rows (parked? unpark it first)"
[ ! -f "$ffile" ] || die "focus is already on $(cat "$ffile"); run focus.sh --clear first"

printf '%s\n' "$team" >"$ffile"
while IFS= read -r t; do
  [ -n "$t" ] || continue
  if [ "$now_flag" = 1 ]; then pargs=(--reason "focus:$team"); else pargs=(--after-merge --reason "focus:$team"); fi
  if "$FLEET_SCRIPTS/park.sh" "$t" "${pargs[@]}" >/dev/null 2>&1; then done_list+=("$t"); else refused+=("$t"); fi
done < <("$registry" list --live | jq -r --arg f "$team" '[.[] | select(.tier != "Orchestrator" and .team != $f) | .team] | unique[]')
ev_log focus_set team="$team" detail="$([ "$now_flag" = 1 ] && echo now || echo after-merge)"
key=marked; [ "$now_flag" = 1 ] && key=parked
jq -cn --arg t "$team" --argjson now "$now_flag" --arg k "$key" --arg d "${done_list[*]-}" --arg r "${refused[*]-}" \
  '{focus: $t, now: ($now == 1), ($k): ($d | split(" ") | map(select(. != ""))), refused: ($r | split(" ") | map(select(. != "")))}'
[ "${#refused[@]}" = 0 ] || exit 1
