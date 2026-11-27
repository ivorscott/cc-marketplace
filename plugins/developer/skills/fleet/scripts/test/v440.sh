#!/usr/bin/env bash
# 4.4.0 cases: the tick core. Each part of the tick is a step; a step that fails ends only itself, and a loop that keeps
# failing wakes the Orchestrator (tick_failing) instead of stopping quietly.
# Sourced by run.sh (ok/eq/check, $SCRIPTS, $T, $REG) after v436.sh.

v440_state() { # v440_state <name>: a fresh state root with one lead
  export FLEET_STATE_DIR="$T/v440-$1" FLEET_REGISTRY="$T/v440-$1/fleet.json" FLEET_INBOX="$T/v440-$1/escalations.jsonl" FLEET_WORKTREES="$T/v440-$1/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; rm -f "$AS"/*; gcfg
  "$REG" add '{"name":"tc-a/lead","team":"tc-a","tier":"Lead","status":"Working","herdr_ref":"tc-a-lead","pane":"p1","issue":"PROJ-1"}' >/dev/null; echo working >"$AS/tc-a-lead"
}

v440_docker_down() { # an installed docker whose daemon does not answer is skipped, never the end of the tick
  v440_state docker
  local dk="$T/v440-docker-down" rc=0 err="$T/v440-docker.err"
  printf '#!/usr/bin/env bash\necho "Cannot connect to the Docker daemon" >&2; exit 1\n' >"$dk"; chmod +x "$dk"
  FLEET_DOCKER="$dk" FLEET_NOW=2026-11-27T18:31:00Z "$SCRIPTS/tick.sh" >/dev/null 2>"$err" || rc=$?
  eq "v440 tick: docker installed but not answering, the tick still ends 0 and writes its state" \
    "$rc:$(jq -e 'type == "object"' "$FLEET_STATE_DIR/tick.state.json" >/dev/null 2>&1 && echo state)" "0:state"
  eq "v440 tick: it says docker did not answer, and no step failed" \
    "$(grep -c 'did not answer; its prune is skipped' "$err"):$(grep -c 'tick step .* failed' "$err")" "1:0"
}

v440_step_fails() { # a failing step ends only itself; two ticks in a row raise one tick_failing; it comes back after a pass
  v440_state step
  local out err="$T/v440-step.err"
  n() { jq -rs '[.[] | arrays | .[] | select(.type == "tick_failing")] | length'; }
  out="$(FLEET_FAIL_STEP=disk FLEET_NOW=2026-11-27T19:00:00Z "$SCRIPTS/tick.sh" 2>"$err")"
  eq "v440 tick: a failed step is reported on stderr, the tick ends 0, the later steps still ran" \
    "$?:$(grep -c 'tick step disk failed' "$err"):$(jq -r '.step_fails.disk.count' "$FLEET_STATE_DIR/tick.state.json")" "0:1:1"
  eq "v440 tick: the failed command ended the step: nothing after it ran" "$(grep -c 'ran past a failed command' "$err")" 0
  eq "v440 tick: no tick_failing after one failure" "$(printf '%s' "$out" | n)" 0
  out="$(FLEET_FAIL_STEP=disk FLEET_NOW=2026-11-27T19:05:00Z "$SCRIPTS/tick.sh" 2>/dev/null)"
  eq "v440 tick: one tick_failing on the second failure in a row, naming the step" \
    "$(printf '%s' "$out" | n):$(printf '%s' "$out" | jq -r '[.[] | select(.type == "tick_failing")][0].name')" "1:disk"
  eq "v440 tick: the wake renders as a Loop failing notice" "$(grep -c 'Loop failing' "$FLEET_STATE_DIR/notices.log" 2>/dev/null)" 1
  out="$(FLEET_FAIL_STEP=disk FLEET_NOW=2026-11-27T19:10:00Z "$SCRIPTS/tick.sh" 2>/dev/null)"
  eq "v440 tick: not raised again while the same run of failures goes on" "$(printf '%s' "$out" | n)" 0
  FLEET_NOW=2026-11-27T19:15:00Z "$SCRIPTS/tick.sh" >/dev/null 2>&1
  eq "v440 tick: a pass clears the step's count" "$(jq -r '(.step_fails // {}) | has("disk")' "$FLEET_STATE_DIR/tick.state.json")" false
  FLEET_FAIL_STEP=disk FLEET_NOW=2026-11-27T19:20:00Z "$SCRIPTS/tick.sh" >/dev/null 2>&1
  out="$(FLEET_FAIL_STEP=disk FLEET_NOW=2026-11-27T19:25:00Z "$SCRIPTS/tick.sh" 2>/dev/null)"
  eq "v440 tick: a new run of failures raises it again" "$(printf '%s' "$out" | n)" 1
  out="$(FLEET_FAIL_STEP=escalations FLEET_NOW=2026-11-27T19:30:00Z "$SCRIPTS/tick.sh" 2>/dev/null)"
  eq "v440 tick: the hook is test-only: without FLEET_TEST it does nothing" \
    "$(FLEET_TEST='' FLEET_FAIL_STEP=disk bash -c ". '$SCRIPTS/common.sh'; [ \"\${FLEET_TEST:-}\" = 1 ] && echo test || echo live")" live
}

v440_loop_failing() { # loop-tick: two failed runs in a row wake once; a good run resets it
  v440_state loop
  local ft="$T/v440-ft" ok="$T/v440-ok" wl
  printf '#!/usr/bin/env bash\necho "jq: error: boom" >&2; exit 1\n' >"$ft"; printf '#!/usr/bin/env bash\necho "[]"\n' >"$ok"; chmod +x "$ft" "$ok"
  wl="$FLEET_STATE_DIR/wakes.log"
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v440 loop: one failed run wakes nobody" "$(grep -c 'tick_failing' "$wl" 2>/dev/null || true)" 0
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v440 loop: the second failed run in a row writes one tick_failing wake line, with no error text in it" \
    "$(grep -c '^fleet tick: tick_failing - tick - - -$' "$wl"):$(grep -c 'boom' "$wl")" "1:0"
  eq "v440 loop: the notice carries the error for fleet status" "$(grep -c 'Loop failing.*boom' "$FLEET_STATE_DIR/notices.log")" 1
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v440 loop: no second wake for the same run of failures" "$(grep -c 'tick_failing' "$wl")" 1
  FLEET_TICK="$ok" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1; FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v440 loop: after a good run, a new run of failures wakes again" "$(grep -c 'tick_failing' "$wl")" 2
}

v440_text() {
  eq "v440 text: tick_failing is a wake type" "$(bash -c ". '$SCRIPTS/common.sh'; printf '%s' \"\$WAKE_TYPES\"" | tr ' ' '\n' | grep -cx tick_failing)" 1
  eq "v440 text: every part of the tick runs as a step" "$(grep -c '^step [a-z_]* [a-z_]*$' "$SCRIPTS/tick.sh")" 29
  eq "v440 text: the plugin and the marketplace are at 4.4.0" "$(jq -r .version "$SCRIPTS/../../../.claude-plugin/plugin.json"):$(jq -r '.plugins[] | select(.name == "developer") | .version' "$SCRIPTS/../../../../../.claude-plugin/marketplace.json")" "4.4.0:4.4.0"
}

v440_smoke() { v440_docker_down; v440_step_fails; v440_loop_failing; v440_text; }
v440_full() { v440_smoke; }
