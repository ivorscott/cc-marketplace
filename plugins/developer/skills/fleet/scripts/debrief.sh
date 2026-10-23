#!/usr/bin/env bash
# Debrief: the read-only part of route H, the retired teams whose lessons are still to be written.
#
#   debrief.sh
#
# One line per team with a Retired row that has an outcome and no lessons:
#   <team> (<outcome>): lessons due from <role>, <role>
# (the outcomes of those rows, joined with / when they differ), then "Discovered work: <text> (<agent>); ..." for the
# work those agents filed, or "Nothing to debrief." when no team is waiting. The lessons are the Orchestrator's to
# write (registry.sh set <name> lessons="<text>", SKILL.md route H); a row with lessons is done, and
# `registry.sh archive` moves it out of the live registry. This script writes nothing.
# Command: List the retired teams whose lessons are still to be written · e.g. fleet debrief
set -euo pipefail
. "$(dirname "$0")/common.sh"
[ $# = 0 ] || die "usage: debrief.sh"

rows="$("$FLEET_SCRIPTS/registry.sh" list | jq -c '[.[] | select(.tier != "Orchestrator" and .status == "Retired" and (.outcome // "") != "" and (.lessons // "") == "")]')"
if [ "$(jq length <<<"$rows")" = 0 ]; then echo "Nothing to debrief."; exit 0; fi
jq -r 'group_by(.team)[] | "\(.[0].team) (\([.[].outcome] | unique | join("/"))): lessons due from \([.[].name | split("/")[1:] | join("/")] | join(", "))"' <<<"$rows"
jq -r '[.[] | .name as $n | (.discovered // [])[] | "\(if type == "object" then .message else tostring end) (\($n))"]
  | if length > 0 then "Discovered work: " + join("; ") else empty end' <<<"$rows"
