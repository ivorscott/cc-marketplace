#!/usr/bin/env bash
# 4.2.17 (DEV-1108): herdr events wake the Orchestrator for a dead or blocked agent; tick stays the fallback. Sourced by run.sh
# after v4215.sh; it uses v413_agent and run.sh's own (ok, eq, check, REG, FLEET_*). No sleeps and no real timeouts: staleness is the
# mtime of events.alive (v4217_touch) against FLEET_NOW, the stream is fed on stdin or comes from an nc shim, and the
# snapshot is a herdr shim that answers `api snapshot` from a file. Generic names only.
v4217_wl() { cat "$FLEET_STATE_DIR/wakes.log" 2>/dev/null || true; }
v4217_state() { # v4217_state <name>: a fresh state root with two live agents, panes pxa-lead and pxa-builder
  qfresh "v4217$1"; rm -rf "${FLEET_STATE_DIR:?}"; mkdir -p "$FLEET_STATE_DIR"; export FLEET_INBOX="$FLEET_STATE_DIR/escalations.jsonl"
  v413_agent xa/lead Lead Working; v413_agent xa/builder Worker Working
}
v4217_touch() { # v4217_touch <file> <epoch>: set the file's mtime to that moment
  touch -t "$(date -r "$2" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$2" +%Y%m%d%H%M.%S)" "$1"
}
v4217_feed() { printf '%s\n' "$@" | "$SCRIPTS/events.sh" feed 2>>"$T/v4217.err"; }
v4217_ack='{"id":"fleet","result":{"subscribed":true}}'
v4217_exit() { printf '{"event":"pane.exited","data":{"pane_id":"%s"}}' "$1"; }
v4217_status() { printf '{"event":"pane.agent_status_changed","data":{"pane_id":"%s","agent_status":"%s"}}' "$1" "$2"; }
v4217_snap() { # v4217_snap <json>: herdr answers `api snapshot` with it (everything else goes to the suite's shim)
  mkdir -p "$T/v4217bin"; printf '%s' "$1" >"$T/v4217.snap"
  cat >"$T/v4217bin/herdr" <<S
#!/usr/bin/env bash
[ "\${3:-} \${4:-}" = "api snapshot" ] && { cat "$T/v4217.snap"; exit 0; }
exec "$T/bin/herdr" "\$@"
S
  chmod +x "$T/v4217bin/herdr"
}

v4217_events() {
  local now=2026-10-29T10:00:00Z ne
  export FLEET_NOW=$now; ne="$(jq -rn --arg t "$now" '$t | fromdateiso8601')"
  v4217_state ev
  v4217_feed "$v4217_ack" "$(v4217_exit pxa-builder)" >/dev/null
  eq "v4217 a pane.exited event is one dead wake line in the fixed template" "$(v4217_wl)" "fleet tick: dead xa xa/builder - - -"
  v4217_feed "$v4217_ack" "$(v4217_exit pxa-builder)" >/dev/null
  eq "v4217 the same exit again adds no second line" "$(v4217_wl | wc -l | tr -d ' ')" 1
  eq "v4217 a handled event refreshes events.alive" "$(test -f "$FLEET_STATE_DIR/events.alive" && echo yes)" yes
  v4217_feed "$v4217_ack" "$(v4217_status pxa-lead blocked)" >/dev/null
  eq "v4217 blocked is one input_pending line" "$(v4217_wl | tail -n 1)" "fleet tick: input_pending xa xa/lead - - -"
  v4217_feed "$v4217_ack" "$(v4217_status pxa-lead working)" "$(v4217_status pxa-lead blocked)" >/dev/null
  eq "v4217 blocked again after working is a new episode: a second line" "$(v4217_wl | grep -c input_pending)" 2
  v4217_feed "$v4217_ack" "$(v4217_status pxa-lead idle)" "$(v4217_status pxa-lead "done")" >/dev/null
  eq "v4217 idle and done wake nothing (Stalled stays tick's)" "$(v4217_wl | wc -l | tr -d ' ')" 3
  "$REG" set xa/builder status=Retired >/dev/null; "$REG" set xa/lead status=Parked >/dev/null
  rm -f "$FLEET_STATE_DIR/events.seen.json"
  v4217_feed "$v4217_ack" "$(v4217_exit pxa-builder)" "$(v4217_status pxa-lead blocked)" "$(v4217_exit pzzz)" >/dev/null
  eq "v4217 Retired, Parked and unknown panes wake nothing" "$(v4217_wl | wc -l | tr -d ' ')" 3
  v4217_state dn; "$REG" set xa/builder status=Done >/dev/null; "$REG" set xa/lead retiring=1 >/dev/null
  v4217_feed "$v4217_ack" "$(v4217_exit pxa-builder)" "$(v4217_exit pxa-lead)" >/dev/null
  eq "v4217 a Done row, and a row retire has marked retiring, wake nothing on pane exit" "$(v4217_wl | wc -l | tr -d ' ')" 0
  v4217_snap '{"result":{"panes":[{"pane_id":"pother","agent_status":"working"}]}}'
  PATH="$T/v4217bin:$PATH" v4217_feed "$v4217_ack" >/dev/null
  eq "v4217 nor does the reconcile after a lost stream" "$(v4217_wl | wc -l | tr -d ' ')" 0
  eq "v4217 retire.sh marks the rows retiring before it closes any pane or workspace" \
    "$(awk '/retiring=1/ && !m {m = NR} /hd (workspace|pane) close/ && !c {c = NR} END {print (m > 0 && c > m) ? "before" : "wrong"}' "$SCRIPTS/retire.sh")" before

  # no free text: only enumerated fields of the registry row reach wakes.log
  v4217_state ft
  v4217_feed "$v4217_ack" '{"event":"pane.exited","data":{"pane_id":"pxa-builder","message":"rm -rf $(evil) `x`","name":"evil/name"}}' >/dev/null
  eq "v4217 event free text never reaches wakes.log" "$(v4217_wl | grep -c 'evil\|rm -rf')" 0
  eq "v4217 every wake line matches the template" "$(v4217_wl | grep -Ec '^fleet tick: [a-z_]+ [A-Za-z0-9._:/@#-]+ [A-Za-z0-9._:/@#-]+ - - -$')" 1
  eq "v4217 wakes.log is mode 600" "$(stat -c %a "$FLEET_STATE_DIR/wakes.log" 2>/dev/null || stat -f %Lp "$FLEET_STATE_DIR/wakes.log")" 600

  # the rotation is the loop's: 500 lines, then wakes.log.1
  v4217_state rot
  seq 1 499 | sed 's/^/fleet tick: dead t n - - -/' >"$FLEET_STATE_DIR/wakes.log"
  v4217_feed "$v4217_ack" "$(v4217_exit pxa-builder)" "$(v4217_status pxa-lead blocked)" >/dev/null
  eq "v4217 past 500 lines the old file moves to wakes.log.1 and a new one starts" "$(wc -l <"$FLEET_STATE_DIR/wakes.log.1" | tr -d ' '):$(v4217_wl | wc -l | tr -d ' ')" "500:1"
  unset FLEET_NOW; : "$ne"
}

v4217_dedupe() {
  local now=2026-10-29T10:00:00Z ne ft="$T/v4217.tick" out
  export FLEET_NOW=$now; ne="$(jq -rn --arg t "$now" '$t | fromdateiso8601')"
  cat >"$ft" <<'S'
#!/usr/bin/env bash
echo '[{"type":"dead","team":"xa","name":"xa/builder","status":"Zombie"}]'
S
  chmod +x "$ft"
  v4217_state dd
  v4217_feed "$v4217_ack" "$(v4217_exit pxa-builder)" >/dev/null
  v4217_touch "$FLEET_STATE_DIR/events.alive" $((ne - 30))
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v4217 the subscriber woke it, then tick reports the same death: still one line" "$(v4217_wl | wc -l | tr -d ' ')" 1
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v4217 a later tick report of a new death is written (the dedupe is used up)" "$(v4217_wl | wc -l | tr -d ' ')" 2
  # a seen entry from long ago must not swallow a later report of a new death
  v4217_state old
  jq -nc --argjson at $((ne - 3000)) '{"xa/builder|dead": {pane: "pxa-builder", at: $at}}' >"$FLEET_STATE_DIR/events.seen.json"
  : >"$FLEET_STATE_DIR/events.alive"; v4217_touch "$FLEET_STATE_DIR/events.alive" $((ne - 30))
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v4217 a stale events.seen.json entry is ignored: tick's wake is written" "$(v4217_wl)" "fleet tick: dead xa xa/builder - - -"
  # a stale events.alive: tick writes the wake itself, as it always did
  v4217_state st
  v4217_feed "$v4217_ack" "$(v4217_exit pxa-builder)" >/dev/null
  out="$(v4217_wl)"
  v4217_touch "$FLEET_STATE_DIR/events.alive" $((ne - 300))
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v4217 a stale events.alive: tick writes its own dead line" "$(v4217_wl | wc -l | tr -d ' '):$(v4217_wl | tail -n 1)" "2:$out"
  # no subscriber at all
  v4217_state no; rm -f "$FLEET_STATE_DIR/events.alive" "$FLEET_STATE_DIR/events.seen.json"
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v4217 no subscriber: tick behaves as today, one dead line" "$(v4217_wl)" "fleet tick: dead xa xa/builder - - -"
  eq "v4217 and raises no events_down alert (it never ran)" "$(jq -r '(.alerts // {}) | has("events_down")' "$FLEET_STATE_DIR/loop.state.json")" false
  # it ran and went quiet while a team is booted: one alert
  : >"$FLEET_STATE_DIR/events.alive"; v4217_touch "$FLEET_STATE_DIR/events.alive" $((ne - 600))
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v4217 a subscriber that went quiet raises events_down once" "$(jq -r '(.alerts // {}) | has("events_down")' "$FLEET_STATE_DIR/loop.state.json")" true
  unset FLEET_NOW FLEET_TICK
}

v4217_lost() {
  v4217_state lo
  # the snapshot lists only the lead's pane, and it is blocked: the builder's pane is gone
  v4217_snap '{"result":{"workspaces":[{"tabs":[{"panes":[{"pane_id":"pxa-lead","agent_status":"blocked"}]}]}]}}'
  PATH="$T/v4217bin:$PATH" v4217_feed "$v4217_ack" '{"event":"events_lost"}' >/dev/null
  eq "v4217 events_lost: resubscribe's snapshot reconcile wakes the gone pane and the blocked one, once each" \
    "$(v4217_wl | sort | paste -sd, -)" "fleet tick: dead xa xa/builder - - -,fleet tick: input_pending xa xa/lead - - -"
  PATH="$T/v4217bin:$PATH" v4217_feed "$v4217_ack" 'not json at all' >/dev/null
  eq "v4217 a junk line is events_lost too, and the reconcile adds nothing the first did not" "$(v4217_wl | wc -l | tr -d ' ')" 2
  v4217_state eof
  v4217_snap '{"result":{"panes":[{"pane_id":"pxa-lead","agent_status":"working"},{"pane_id":"pxa-builder","agent_status":"idle"}]}}'
  PATH="$T/v4217bin:$PATH" v4217_feed "$v4217_ack" >/dev/null
  eq "v4217 EOF reconciles: every pane alive and not blocked wakes nothing" "$(v4217_wl | wc -l | tr -d ' ')" 0
  v4217_state odd
  v4217_snap '{"result":{"something":"else"}}'
  PATH="$T/v4217bin:$PATH" v4217_feed "$v4217_ack" >/dev/null
  eq "v4217 a snapshot with no pane records is not trusted: no mass deaths" "$(v4217_wl | wc -l | tr -d ' ')" 0
}

v4217_run() { # run: subscribe through an nc shim, read the stream, reconcile at EOF, no backoff sleep
  local nc="$T/v4217.nc"
  v4217_state rn
  cat >"$nc" <<S
#!/usr/bin/env bash
head -n 1 >"$T/v4217.sub"
printf '%s\n' '$v4217_ack' '{"event":"pane.exited","data":{"pane_id":"pxa-builder"}}'
S
  chmod +x "$nc"
  FLEET_NC="$nc" FLEET_EVENTS_ONCE=1 "$SCRIPTS/events.sh" run >/dev/null 2>>"$T/v4217.err"
  eq "v4217 run subscribes to both event types" "$(jq -r '[.method, (.params.subscriptions | map(.type) | join("+"))] | join(" ")' "$T/v4217.sub")" "events.subscribe pane.exited+pane.agent_status_changed"
  eq "v4217 run turns the streamed exit into the wake" "$(v4217_wl)" "fleet tick: dead xa xa/builder - - -"
  eq "v4217 without nc it says tick polling still works and exits 1" \
    "$(FLEET_NC=/nonexistent/nc "$SCRIPTS/events.sh" run 2>&1 >/dev/null; echo "rc=$?")" "fleet: warning: nc is not installed, so the event subscriber cannot run; tick polling still catches dead and blocked agents
rc=1"
}

v4217_connect() { # events.alive means connected: an nc that never acknowledges leaves it absent; backoff is capped and kept
  local nc="$T/v4217.nc0"
  v4217_state cn; export FLEET_NOW=2026-10-29T10:00:00Z
  printf '#!/usr/bin/env bash\nhead -n 1 >/dev/null\n' >"$nc"; chmod +x "$nc"
  FLEET_NC="$nc" FLEET_EVENTS_ONCE=1 "$SCRIPTS/events.sh" run >/dev/null 2>&1
  eq "v4217 nc exits without acknowledging the subscription: no events.alive" "$(test -f "$FLEET_STATE_DIR/events.alive" && echo yes || echo no)" no
  printf '#!/usr/bin/env bash\nhead -n 1 >/dev/null\necho %s\n' "'$v4217_ack'" >"$nc"
  FLEET_NC="$nc" FLEET_EVENTS_ONCE=1 "$SCRIPTS/events.sh" run >/dev/null 2>&1
  eq "v4217 once the subscription is acknowledged, events.alive exists" "$(test -f "$FLEET_STATE_DIR/events.alive" && echo yes || echo no)" yes
  eq "v4217 a connection that never subscribed doubles the pause (1, 2, 4 ... capped at 60)" \
    "$("$SCRIPTS/events.sh" backoff 1 0 | tr '\n' ' ')$("$SCRIPTS/events.sh" backoff 2 0 | tr '\n' ' ')$("$SCRIPTS/events.sh" backoff 40 0)" "2 4 60"
  eq "v4217 only an acknowledged connection starts over at 1" "$("$SCRIPTS/events.sh" backoff 32 1)" 1
  # tick and events_down take over: the file is absent or old, so tick polls and, once it had run, the alert fires
  rm -f "$FLEET_STATE_DIR/events.alive"; export FLEET_NC="$nc"
  eq "v4217 with no events.alive the subscriber counts as down" "$("$SCRIPTS/events.sh" status | cut -c1-30)" "Event subscriber: not running "
  unset FLEET_NOW FLEET_NC
}

v4217_status_line() {
  local ne; export FLEET_NOW=2026-10-29T10:00:00Z; ne="$(jq -rn --arg t "$FLEET_NOW" '$t | fromdateiso8601')"
  v4217_state sl; export FLEET_NC="$T/v4217.nc"
  eq "v4217 status: never run" "$("$SCRIPTS/events.sh" status)" "Event subscriber: not running (tick polls). Run fleet run start."
  : >"$FLEET_STATE_DIR/events.alive"; v4217_touch "$FLEET_STATE_DIR/events.alive" $((ne - 60))
  eq "v4217 status: up when events.alive is under 2 minutes old" "$("$SCRIPTS/events.sh" status)" "Event subscriber: up."
  v4217_touch "$FLEET_STATE_DIR/events.alive" $((ne - 121))
  eq "v4217 status: down when it is older" "$("$SCRIPTS/events.sh" status | cut -c1-39)" "Event subscriber: down (events.alive is"
  unset FLEET_NOW FLEET_NC
}

v4217_plist() { # v4217_plist <file>: the plist as JSON (python3's plistlib, so no macOS-only plutil is needed)
  python3 -I -c 'import json, plistlib, sys; print(json.dumps(plistlib.load(open(sys.argv[1], "rb"))))' "$1"
}
v4217_job() { # the launchd job: KeepAlive, its own launcher, installed next to the tick job
  local p="$T/v4217.plist" l j
  FLEET_LAUNCH_AGENTS="$T/la" "$SCRIPTS/schedule.sh" render-events >"$p"
  j="$(v4217_plist "$p" 2>/dev/null || true)"
  eq "v4217 the events plist is valid XML (it parses as a plist)" "$([ -n "$j" ] && echo yes)" yes
  eq "v4217 label is fleet.events, KeepAlive and RunAtLoad, no interval" \
    "$(jq -r '[.Label, .KeepAlive, .RunAtLoad, has("StartInterval")] | map(tostring) | join(":")' <<<"$j")" "fleet.events:true:true:false"
  eq "v4217 it runs the events launcher in the state dir" "$(jq -c .ProgramArguments <<<"$j")" "[\"/bin/bash\",\"$FLEET_STATE_DIR/bin/fleet-events\"]"
  l="$("$SCRIPTS/schedule.sh" launcher-events)"
  eq "v4217 the launcher's exec line runs events.sh with run as its own argument" "$(grep '^exec ' "$l")" 'exec /bin/bash "$p/skills/fleet/scripts/events.sh" run'
  eq "v4217 and it never names loop-tick" "$(grep -c 'loop-tick' "$l" || true)" 0
}

v4217_docs() {
  local R="$SCRIPTS/../README.md"
  eq "v4217 the README says how the event subscriber works" "$(grep -c '`fleet.events`' "$R")" 1
  check "v4217 events is internal in 5.0: not in the index, its help still prints" bash -c "! '$SCRIPTS/fleet' help | grep -q '^| \`events\`' && '$SCRIPTS/fleet' help events | grep -q 'fleet events status'"
}

v4217_smoke() { v4217_events; v4217_dedupe; v4217_lost; v4217_run; v4217_connect; v4217_status_line; v4217_job; v4217_docs; }
v4217_full() { v4217_smoke; }
