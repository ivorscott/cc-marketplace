#!/usr/bin/env bash
# Prime: the read-only part of route G, to pick the fleet up again after a compaction or in a new session.
#
#   prime.sh
#
# One line, "Fleet on <machine>: <n> teams, <n> open escalations, <n> problems.", then the status output (the team
# table, parked teams, the focus, the open escalations). Teams are those with a row not yet Retired; problems are the
# agents status.sh flags (Stalled, Zombie, Needs input, or an open escalation). <machine> is machine_name from
# config.toml, else this machine's label. It writes nothing but what status.sh writes back (each agent's health).
# Command: Pick the fleet up again after a compaction or in a new session · e.g. fleet prime
set -euo pipefail
. "$(dirname "$0")/common.sh"
registry="$FLEET_SCRIPTS/registry.sh"
[ $# = 0 ] || die "usage: prime.sh"

st="$("$FLEET_SCRIPTS/status.sh")" # first, so the counts below see the health it just wrote
teams="$("$registry" list | jq '[.[] | select(.tier != "Orchestrator" and .status != "Retired") | .team] | unique | length')"
esc="$("$registry" escalations --open --not-retired | jq length)"
probs="$("$registry" list --problems | jq '[.[] | select(.tier != "Orchestrator")] | length')"
who="$(cfg_str machine_name '')"; [ -n "$who" ] || who="$(machine_label)"
render_line prime machine="$who" teams="$teams" escalations="$esc" problems="$probs"
[ -z "$st" ] || printf '%s\n' "$st"
