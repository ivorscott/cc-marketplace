#!/usr/bin/env bash
# Focus on one team: park every other live team, so the user's attention and the slots go to it.
#
#   focus.sh <team> [--now]     park the other live teams after their PRs merge (--now: right away)
#   focus.sh --clear            drop the focus and unpark only the teams focus parked (focus:<team>)
#   focus.sh                    show the focus: "Focus: <team>." or "Focus: none."
#
# It prints "Focused on <team>: parked <teams>." (--now), "Focused on <team>: <teams> park when their PRs merge."
# or "Focus cleared: unparked <teams>.", then the team table (references/output.md). A team that cannot be parked
# (uncommitted work, herdr down) or unparked (the caps are full) is named after "Refused:" and stays as it was; the
# others go through, a warning names each refusal and its reason, and focus.sh exits 1. The focus is one line under the status table.
# Command: Park every other team so one team gets the slots · e.g. fleet focus build-api --now
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
[ -z "${FLEET_ROLE:-}" ] || die "focus is the Orchestrator's; an agent (FLEET_ROLE=$FLEET_ROLE) may not run it"
registry="$FLEET_SCRIPTS/registry.sh"
ffile="$FLEET_STATE_DIR/focus"

if [ $# -eq 0 ]; then
  if [ -f "$ffile" ]; then render_line focus team="$(cat "$ffile")"; else render_line focus; fi
  exit 0
fi
commas() { local IFS=,; printf '%s' "$*" | sed 's/,/, /g'; } # commas <word...>: "a, b, c"
# move <park|unpark> <team> [args]: park or unpark one team; a refusal is warned with its reason and kept in refused.
move() {
  local verb="$1" t="$2" e; shift 2
  if e="$("$FLEET_SCRIPTS/$verb.sh" "$t" "$@" 2>&1 >/dev/null)"; then done_list+=("$t"); return 0; fi
  refused+=("$t"); e="$(printf '%s\n' "$e" | grep -v '^fleet: warning:' | head -n 1)"; e="${e#fleet: }"
  warn "could not $verb $t (${e%:})"
}
arg="$1"; shift
done_list=(); refused=()

if [ "$arg" = "--clear" ]; then
  [ -f "$ffile" ] || die "no focus is set"
  ft="$(cat "$ffile")"
  rm -f "$ffile"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    move unpark "$t"
  done < <("$registry" list --parked | jq -r '[.[] | select((.parked_reason // "") | startswith("focus:")) | .team] | unique[]')
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    "$registry" park-mark "$t" - >/dev/null
  done < <("$registry" list | jq -r '[.[] | select((.park_after_merge // "") | startswith("focus:")) | .team] | unique[]')
  ev_log focus_cleared team="$ft"
  reply "$(render_line focus_cleared unparked="$(commas ${done_list[@]+"${done_list[@]}"})" refused="$(commas ${refused[@]+"${refused[@]}"})")" "$(render_table)"
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
  move park "$t" "${pargs[@]}"
done < <("$registry" list --live | jq -r --arg f "$team" '[.[] | select(.tier != "Orchestrator" and .team != $f) | .team] | unique[]')
ev_log focus_set team="$team" detail="$([ "$now_flag" = 1 ] && echo now || echo after-merge)"
if [ "$now_flag" = 1 ]; then line="$(render_line focused team="$team" parked="$(commas ${done_list[@]+"${done_list[@]}"})" refused="$(commas ${refused[@]+"${refused[@]}"})")"
else line="$(render_line focus_marked team="$team" marked="$(commas ${done_list[@]+"${done_list[@]}"})" refused="$(commas ${refused[@]+"${refused[@]}"})")"; fi
reply "$line" "$(render_table)"
[ "${#refused[@]}" = 0 ] || exit 1
