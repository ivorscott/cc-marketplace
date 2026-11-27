#!/usr/bin/env bash
# 4.3.5 cases (DEV-1259): a lead never waits on or polls a worker, and tick frees a lead that does (one Escape).
# Sourced by run.sh (ok/eq/check, $SCRIPTS, $T) after v4215.sh. The tick Escape cases live in v4215.sh (one shared sandbox).

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

v435_text() {
  local f="$SCRIPTS/../templates/build.json" l="$SCRIPTS/../../../agents/lead.md" a="$SCRIPTS/agent-lib.sh"
  eq "v435 text: the lead brief has no instruction to wait (agent wait or --wait)" "$(jq -r '.. | strings' "$f" | grep -c 'herdr agent wait <\|prompt/read/wait\|--until idle')" 0
  eq "v435 text: lead.md has no agent wait and no prompt --wait" "$(grep -c 'agent wait <\|prompt <worker> "<text>" --wait' "$l")" 0
  eq "v435 text: the build lead brief, house.md and lead.md each carry the escalate-before-idle rule" \
    "$(jq -r '.. | strings' "$f" | grep -c 'filed with escalate before you stop or go Idle'):$(grep -c 'filed with escalate before a lead stops or goes Idle' "$SCRIPTS/../rules/house.md"):$(grep -c 'filed with escalate before you stop or go Idle' "$l")" "1:1:1"
  eq "v435 text: the brief and lead.md name what the guard denies, and neither says it denies repeated agent get" \
    "$(jq -r '.. | strings' "$f" | grep -c 'guard denies `agent wait`, `prompt --wait`, `sleep`, `timeout` and `watch`'):$(grep -c 'guard denies `agent wait`' "$l"):$(jq -r '.. | strings' "$f" | grep -c 'guard denies[^)]*agent get')" "1:1:0"
  eq "v435 text: no role's herdr allow-list carries agent wait" "$(grep -c 'herdr agent wait' "$a")" 0
}

v435_smoke() { v435_guard; v435_text; }
v435_full() { v435_smoke; }
