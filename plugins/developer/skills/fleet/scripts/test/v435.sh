#!/usr/bin/env bash
# 4.3.5 cases (DEV-1259): a lead never waits on or polls a worker, and tick frees a lead that does (one Escape).
# Sourced by run.sh (ok/eq/check, $SCRIPTS, $T) after v4215.sh, whose helpers it uses (v4211_state, v4211_end, v4211_row,
# v413_agent, v420_tick, v420_evn, v4215_nudges) with run.sh's REG, AS and HERDR_LOG. Generic names only.

v435_guard() {
  local BG="$SCRIPTS/../../../hooks/fleet-bash-guard.sh" gs="$T/v435-gstate" r
  mkdir -p "$gs"; printf '{"agents":[{"team":"build-gt","herdr_ref":"w","status":"Idle"}]}\n' >"$gs/fleet.json"
  g() { # g <role> <command>: allow or deny
    r="$(jq -nc --arg c "$2" '{tool_name: "Bash", tool_input: {command: $c}}' | env -u FLEET_CONFIG_DIR -u XDG_CONFIG_HOME FLEET_STATE_DIR="$gs" FLEET_ROLE="$1" FLEET_TEAM=build-gt /bin/bash "$BG" | jq -r '.hookSpecificOutput.permissionDecision // "allow"')"
    printf '%s\n' "${r:-allow}"
  }
  eq "v435 guard: a lead's herdr agent wait is denied" "$(g lead 'herdr agent wait w --until idle')" deny
  eq "v435 guard: a lead's herdr agent wait behind --session is denied" "$(g lead 'herdr --session s agent wait w --until idle')" deny
  eq "v435 guard: a lead's worker prompt with --wait is denied" "$(g lead 'herdr agent prompt w x --wait')" deny
  eq "v435 guard: a lead's sleep is denied" "$(g lead 'sleep 5')" deny
  eq "v435 guard: a lead's poll loop is denied" "$(g lead 'while true; do herdr agent get w; sleep 30; done')" deny
  eq "v435 guard: a lead's timeout around herdr is denied" "$(g lead 'timeout 60 herdr agent get w')" deny
  eq "v435 guard: a lead's single herdr agent get is allowed" "$(g lead 'herdr agent get w')" allow
  eq "v435 guard: a lead's herdr agent read is allowed" "$(g lead 'herdr agent read w --lines 20')" allow
  eq "v435 guard: a lead's plain worker prompt is allowed" "$(g lead 'herdr agent prompt w x')" allow
  eq "v435 guard: a lead's ordinary command is allowed" "$(g lead 'git status')" allow
  eq "v435 guard: a worker's sleep and agent wait are not touched by the lead rule" "$(g builder 'sleep 1'):$(g builder 'herdr agent wait w --until idle')" allow:allow
  eq "v435 guard: the deny text says to end the turn" "$(jq -nc '{tool_name: "Bash", tool_input: {command: "sleep 5"}}' | env FLEET_STATE_DIR="$gs" FLEET_ROLE=lead FLEET_TEAM=build-gt /bin/bash "$BG" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -c 'End your turn')" 1
}

v435_tick() {
  v4211_state ew
  local ev
  esc() { grep -c "^agent send-keys ew-a-lead escape" "$HERDR_LOG" || true; }
  export FLEET_LEAD_QUEUE_MINS=1
  v413_agent ew-a/lead Lead Working; v413_agent ew-a/tester Worker Idle; echo working >"$AS/ew-a-lead"
  "$REG" set ew-a/lead queued_at=2026-10-29T10:00:00Z >/dev/null
  ev="$(v420_tick 2026-10-29T10:05:00Z)"
  eq "v435 no tester sign-off: no nudge and no Escape" "$(v420_evn "$ev" lead_waiting):$(v4215_nudges):$(esc)" "0:0:0"
  "$REG" signoff ew-a/tester https://github.com/acme/app-api/pull/1 aaaaaaa1 >/dev/null
  ev="$(v420_tick 2026-10-29T10:06:00Z)"
  eq "v435 stage 1: one nudge, no Escape, and the nudge keeps queued_at" "$(v420_evn "$ev" lead_waiting):$(v4215_nudges):$(esc):$(v4211_row ew-a/lead '.queued_at // ""')" "1:1:0:2026-10-29T10:00:00Z"
  ev="$(v420_tick 2026-10-29T10:12:00Z)"
  eq "v435 stage 2: a later tick with the lead still working sends one Escape and the message again" "$(v420_evn "$ev" lead_waiting):$(v4215_nudges):$(esc)" "1:2:1"
  eq "v435 stage 2 records escaped_at" "$([ -n "$(v4211_row ew-a/lead '.escaped_at // ""')" ] && echo set)" set
  ev="$(v420_tick 2026-10-29T10:18:00Z)"
  eq "v435 stage 3: a third tick sends neither another Escape nor another message" "$(v420_evn "$ev" lead_waiting):$(v4215_nudges):$(esc)" "0:2:1"
  echo idle >"$AS/ew-a-lead"
  v420_tick 2026-10-29T10:19:00Z >/dev/null
  eq "v435 a lead that went idle resets all four fields" "$(v4211_row ew-a/lead '[.queued_at, .waiting_nudged_at, .waiting_nudged_epoch, .escaped_at] | map(. // "") | join("|")')" "|||"
  v4211_end; unset FLEET_LEAD_QUEUE_MINS
}

v435_text() {
  local f="$SCRIPTS/../templates/build.json" l="$SCRIPTS/../../../agents/lead.md" a="$SCRIPTS/agent-lib.sh"
  eq "v435 text: the lead brief has no instruction to wait (agent wait or --wait)" "$(jq -r '.. | strings' "$f" | grep -c 'herdr agent wait <\|prompt/read/wait\|--until idle')" 0
  eq "v435 text: lead.md has no agent wait and no prompt --wait" "$(grep -c 'agent wait <\|prompt <worker> "<text>" --wait' "$l")" 0
  eq "v435 text: no role's herdr allow-list carries agent wait" "$(grep -c 'herdr agent wait' "$a")" 0
}

v435_smoke() { v435_guard; v435_tick; v435_text; }
v435_full() { v435_smoke; }
