#!/usr/bin/env bash
# Debrief: the read-only part of route H, the retired teams still in the live registry and their lessons.
#
#   debrief.sh
#
# One line per team with Retired rows that have an outcome:
#   <team> (<outcome>): <role>: <lesson>; <role>: lesson due
# (the outcomes of those rows, joined with / when they differ), then "Discovered work: <text> (<agent>); ..." for
# the work those agents filed, or "Nothing to debrief." (references/output.md). A "lesson due" is the Orchestrator's
# to write (registry.sh set <name> lessons="<text>", SKILL.md route H); once every row of a team has its lessons,
# `registry.sh archive` moves the team out of the live registry, and out of this list. This script writes nothing.
# Command: List the retired teams and their lessons, the ones still due marked · e.g. fleet debrief
set -euo pipefail
. "$(dirname "$0")/common.sh"
[ $# = 0 ] || die "usage: debrief.sh"

rows="$("$FLEET_SCRIPTS/registry.sh" list | jq -c '[.[] | select(.tier != "Orchestrator" and .status == "Retired" and (.outcome // "") != "")]')"
if [ "$(jq length <<<"$rows")" = 0 ]; then render_line nothing_to_debrief; exit 0; fi
while IFS=$'\t' read -r t o l; do
  render_line debrief team="$t" outcome="$o" lessons="$l"
done < <(jq -r 'group_by(.team)[] | [.[0].team, ([.[].outcome] | unique | join("/")),
  (sort_by(if .tier == "Lead" then 0 else 1 end) | map((.name | split("/")[1:] | join("/")) + ": "
    + (if (.lessons // "") == "" then "lesson due" else (.lessons | gsub("[\r\n\t]+"; " ")) end)) | join("; "))] | @tsv' <<<"$rows")
work="$(jq -r '[.[] | .name as $n | (.discovered // [])[] | "\(if type == "object" then .message else tostring end) (\($n))"] | join("; ")' <<<"$rows")"
[ -z "$work" ] || render_line discovered work="$work"
