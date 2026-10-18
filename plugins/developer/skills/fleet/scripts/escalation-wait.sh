#!/usr/bin/env bash
# Wait for new escalations. The Orchestrator arms this in the background during a loop; it
# exits as soon as a new line lands in the escalation inbox, so its exit wakes the session.
#
#   escalation-wait.sh [--timeout SECONDS] [--every SECONDS] [--from-start]
#
# Prints each new inbox line (JSON: at, name, team, severity, message) and exits 0. With nothing
# new by --timeout (default 1500) it prints nothing and exits 0; re-arm it on every tick.
# A cursor file ($FLEET_STATE_DIR/escalations.cursor) holds how many inbox lines were already
# delivered, so an escalation filed between two arms is delivered by the next one, never lost.
# The first run starts at the current end of the inbox; --from-start replays all of it
# (and moves the cursor to the end).
set -euo pipefail
. "$(dirname "$0")/common.sh"

timeout=1500; every=5; from_start=false
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) timeout="${2:?--timeout needs seconds}"; shift 2 ;;
    --every) every="${2:?--every needs seconds}"; shift 2 ;;
    --from-start) from_start=true; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

cursor_file="$(dirname "$FLEET_INBOX")/escalations.cursor"
mkdir -p "$(dirname "$FLEET_INBOX")"
lines() { if [ -f "$FLEET_INBOX" ]; then wc -l <"$FLEET_INBOX" | tr -d ' '; else echo 0; fi; }

if $from_start; then cursor=0
elif [ -f "$cursor_file" ]; then cursor="$(cat "$cursor_file")"
else cursor="$(lines)"; printf '%s\n' "$cursor" >"$cursor_file"; fi
case "$cursor" in "" | *[!0-9]*) cursor=0 ;; esac

deadline=$((SECONDS + timeout))
while :; do
  total="$(lines)"
  if [ "$total" -gt "$cursor" ]; then
    tail -n +"$((cursor + 1))" "$FLEET_INBOX" | head -n "$((total - cursor))"
    printf '%s\n' "$total" >"$cursor_file"
    exit 0
  fi
  [ "$SECONDS" -lt "$deadline" ] || exit 0
  sleep "$every"
done
