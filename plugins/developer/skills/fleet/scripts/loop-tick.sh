#!/usr/bin/env bash
# One scheduled tick, run by launchd (schedule.sh) with no model involved: tick.sh does the
# heartbeat and writes the event log; this script only decides whether the Orchestrator must hear
# about it.
#
#   loop-tick.sh
#
# Wake rule: only judgment events wake the Orchestrator: pr_ready, pr_merged, an escalation of
# severity P0 or P1, dead, claim_takeover, and respawned when it failed. Anything else (stalled,
# pr_opened, disk, weekly_summary, P2 escalations...) is already in the event log and waits for the
# Orchestrator's next look. A quiet tick, or one with no judgment event, wakes nobody and prints
# nothing. One wake per tick: all its judgment events in one message, sent with tell.sh to the
# Orchestrator's pane (the registry row `orchestrator`, else orchestrator_ref in config.toml).
# No live pane: a desktop notification (herdr notification show, else osascript) and an
# orchestrator_wake_missed event in the log.
# FLEET_TICK replaces tick.sh in tests.
# Overlapping ticks are tick.sh's tick lock; this script adds none.
# UNVERIFIED: that herdr reached from a launchd job finds the user's herdr server (DEV-368).
set -euo pipefail
. "$(dirname "$0")/common.sh"
# launchd is not a herdr pane; tick.sh needs to be told it may talk to herdr.
[ -n "${FLEET_SESSION:-}" ] || export HERDR_ENV=1

mkdir -p "$FLEET_STATE_DIR"
out="$("${FLEET_TICK:-$FLEET_SCRIPTS/tick.sh}" 2>>"$FLEET_STATE_DIR/loop.err" || true)"
[ -n "$out" ] || exit 0

# One plain line per judgment event.
lines="$(printf '%s' "$out" | jq -r 'if type == "array" then .[] else empty end
  | select(type == "object") | select(.type | IN("pr_ready", "pr_merged", "dead", "claim_takeover")
     )
  | (.name // .team // "") as $who
  | (if .type == "pr_ready" then "PR ready: \($who) \(.url // "")"
     elif .type == "pr_merged" then "PR merged: \($who) \(.url // "")"
     elif .type == "dead" then "\($who) died"
     else "claim on \(.issue // "an issue") was taken over by \(.holder // "another machine")" end)' 2>/dev/null || true)"
extra="$(printf '%s' "$out" | jq -r 'if type == "array" then .[] else empty end | select(type == "object")
  | select((.type == "escalation" and (.severity | IN("P0", "P1"))) or (.type == "respawned" and .status == "Failed"))
  | (.name // "") as $who
  | (if .type == "escalation" then "\(.severity) from \($who): \(.message // "")" else "\($who) could not be respawned" end)' 2>/dev/null || true)"
lines="$(printf '%s\n%s\n' "$lines" "$extra" | sed '/^$/d')"
[ -n "$lines" ] || exit 0

n="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"
msg="Fleet loop: $n thing(s) need you. $(printf '%s\n' "$lines" | paste -sd ';' - | sed 's/;/; /g')"

target="$("$FLEET_SCRIPTS/registry.sh" get orchestrator 2>/dev/null | jq -r '.herdr_ref // ""' 2>/dev/null || true)"
[ -n "$target" ] || target="$(cfg_str orchestrator_ref "")"
if [ -n "$target" ] && "$FLEET_SCRIPTS/tell.sh" "$target" "$msg" >/dev/null 2>&1; then exit 0; fi

# No live pane to tell: a notification instead, and a record that the wake was missed.
body="${msg:0:300}"
if command -v herdr >/dev/null 2>&1 && hd notification show "Fleet needs you" --body "$body" --sound done >/dev/null 2>&1; then :
elif command -v osascript >/dev/null 2>&1; then
  osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "Fleet needs you"' -e 'end run' "$body" >/dev/null 2>&1 || true
fi
ev_log orchestrator_wake_missed team= name=orchestrator detail="$n events; no live Orchestrator pane"
