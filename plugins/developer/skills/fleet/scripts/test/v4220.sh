#!/usr/bin/env bash
# 4.2.20 (DEV-1114): fleet run start prints its rules from an unquoted heredoc; a backticked `fleet watch` in the text ran
# as a command substitution ("fleet: command not found", or spliced output when fleet is on PATH). Sourced by run.sh after
# v420.sh (v420_state, REG, SCRIPTS, eq). Generic names only.
v4220_run_start() {
  v420_state rs19; export TZ=UTC DF_GB=100; unset HERDR_PANE_ID
  "$REG" add '{"name":"orchestrator","team":"orchestrator","tier":"Orchestrator","status":"Working","herdr_ref":"om","pane":"pom"}' >/dev/null
  printf '2\nparent DEV-9\n\n\nallow\n\n20\n\n07:30\n10:00\n' >"$T/v4220-answers"
  FLEET_RUN_ANSWERS="$T/v4220-answers" "$SCRIPTS/run.sh" init >/dev/null 2>&1
  local bin="$T/v4220-bin" out rc
  rm -rf "$bin"; mkdir -p "$bin"
  # a `fleet` on PATH that prints a marker: if the text still runs it, the marker is spliced into the rules
  printf '#!/usr/bin/env bash\necho "# Monitor stops SPLICED"\n' >"$bin/fleet"; chmod +x "$bin/fleet"
  out="$(PATH="$bin:$PATH" FLEET_NOW=2026-10-29T08:00:00Z "$SCRIPTS/run.sh" start </dev/null 2>&1)"; rc=$?
  eq "v4220 run start: exit 0 with a fleet on PATH, and no spliced output in the rules" "$rc:$(grep -c 'SPLICED' <<<"$out" || true)" "0:0"
  out="$(FLEET_NOW=2026-10-29T08:00:00Z "$SCRIPTS/run.sh" start </dev/null 2>&1)"; rc=$?
  eq "v4220 run start: no 'command not found' when fleet is not on PATH" "$rc:$(grep -c 'command not found' <<<"$out" || true)" "0:0"
  eq "v4220 run start: the rules name the script by its directory path" "$(grep -c "run $SCRIPTS/fleet run watch, start Monitor" <<<"$out" || true)" 1
  unset TZ DF_GB
}
v4220_smoke() { v4220_run_start; }
v4220_full() { v4220_smoke; }
