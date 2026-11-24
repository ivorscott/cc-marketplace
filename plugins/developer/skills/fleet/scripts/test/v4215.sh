#!/usr/bin/env bash
# 4.2.15 (DEV-1117): a lead held in a long turn while a message queues behind it. Sourced by run.sh after v4211.sh, whose
# helpers it uses (v4211_state, v4211_end, v4211_row) with v413_agent, v420_tick, v420_evn and run.sh's own (ok, eq, REG, AS,
# HERDR_LOG, the herdr shim). Generic names only.
v4215_nudges() { grep -c "stop waiting and read its report" "$HERDR_LOG" || true; } # how often the lead was nudged

v4215_lead_waiting() {
  v4211_state lw
  local ev
  export FLEET_LEAD_QUEUE_MINS=1
  v413_agent lw-a/lead Lead Working; v413_agent lw-a/tester Worker Idle; echo working >"$AS/lw-a-lead"
  "$REG" set lw-a/lead queued_at=2026-10-29T10:00:00Z >/dev/null
  ev="$(v420_tick 2026-10-29T10:05:00Z)"
  eq "v4215 no tester sign-off: no lead_waiting and no nudge" "$(v420_evn "$ev" lead_waiting):$(v4215_nudges)" "0:0"
  "$REG" signoff lw-a/tester https://github.com/acme/app-api/pull/1 aaaaaaa1 >/dev/null
  ev="$(v420_tick 2026-10-29T10:06:00Z)"
  eq "v4215 queued past the limit with the tester signed off: one lead_waiting and one nudge" "$(v420_evn "$ev" lead_waiting):$(v4215_nudges)" "1:1"
  ev="$(v420_tick 2026-10-29T10:12:00Z)"
  eq "v4215 a second tick repeats neither" "$(v420_evn "$ev" lead_waiting):$(v4215_nudges)" "0:1"
  echo idle >"$AS/lw-a-lead"
  v420_tick 2026-10-29T10:13:00Z >/dev/null
  eq "v4215 the lead no longer working clears queued_at" "$(v4211_row lw-a/lead '.queued_at // ""')" ""
  v4211_end; unset FLEET_LEAD_QUEUE_MINS
}

v4215_brief() {
  local f="$SCRIPTS/../templates/build.json"
  eq "v4215 the lead brief says never --wait on a prompt and has no prompt --wait" \
    "$(jq -r '.. | strings' "$f" | grep -c 'never `--wait`'):$(jq -r '.. | strings' "$f" | grep -c 'prompt [^`]*--wait')" "1:0"
}

v4215_smoke() { v4215_brief; v4215_lead_waiting; }
v4215_full() { v4215_smoke; }
