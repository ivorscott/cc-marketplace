#!/usr/bin/env bash
# Print the Monitor command that follows the fleet's wakes, for the Orchestrator to (re)arm after a Monitor expires.
#
#   watch.sh [--here]
#
# It prints exactly two lines: the command, `tail -n 0 -F <wakes.log>`, then a `#` comment line about the Monitor's
# 30-minute cap. Start Monitor with the first line and end the turn with no text: a re-arm is not news. With --here it
# first registers this pane as the Orchestrator (registry.sh orchestrator here), the once-per-session step; without it
# nothing is written. The wakes.log is the one the loop appends to (loop-tick.sh), in the state directory.
# Command: Print the wake Monitor command to (re)arm · e.g. fleet watch
set -euo pipefail
. "$(dirname "$0")/common.sh"

here=false
while [ $# -gt 0 ]; do
  case "$1" in
    --here) here=true; shift ;;
    *) die "unknown option: $1" "usage: watch.sh [--here]" ;;
  esac
done
if $here; then "$FLEET_SCRIPTS/registry.sh" orchestrator here >/dev/null; fi
wl="$FLEET_STATE_DIR/wakes.log"
[ -e "$wl" ] || (umask 077; mkdir -p "$FLEET_STATE_DIR" && touch "$wl")
printf 'tail -n 0 -F %s\n' "$wl"
printf '# Monitor stops after at most 30 minutes (timeout_ms 1800000): run fleet watch again when it expires.\n'
