#!/usr/bin/env bash
# 4.2.16 (DEV-1108): herdr events wake the Orchestrator for a dead or blocked agent; tick stays the fallback. Sourced by run.sh
# after v4215.sh; it uses v413_agent and run.sh's own (ok, eq, check, REG, FLEET_*). No sleeps and no real timeouts: staleness is the
# mtime of events.alive (v4216_touch) against FLEET_NOW, the stream is fed on stdin or comes from an nc shim, and the
# snapshot is a herdr shim that answers `api snapshot` from a file. Generic names only.
v4216_wl() { cat "$FLEET_STATE_DIR/wakes.log" 2>/dev/null || true; }
v4216_state() { # v4216_state <name>: a fresh state root with two live agents, panes pxa-lead and pxa-builder
  qfresh "v4216$1"; rm -rf "${FLEET_STATE_DIR:?}"; mkdir -p "$FLEET_STATE_DIR"; export FLEET_INBOX="$FLEET_STATE_DIR/escalations.jsonl"
  v413_agent xa/lead Lead Working; v413_agent xa/builder Worker Working
}
v4216_touch() { # v4216_touch <file> <epoch>: set the file's mtime to that moment
  touch -t "$(date -r "$2" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$2" +%Y%m%d%H%M.%S)" "$1"
}
v4216_feed() { printf '%s\n' "$@" | "$SCRIPTS/events.sh" feed 2>>"$T/v4216.err"; }
v4216_ack='{"id":"fleet","result":{"subscribed":true}}'
v4216_exit() { printf '{"event":"pane.exited","data":{"pane_id":"%s"}}' "$1"; }
v4216_status() { printf '{"event":"pane.agent_status_changed","data":{"pane_id":"%s","agent_status":"%s"}}' "$1" "$2"; }
v4216_snap() { # v4216_snap <json>: herdr answers `api snapshot` with it (everything else goes to the suite's shim)
  mkdir -p "$T/v4216bin"; printf '%s' "$1" >"$T/v4216.snap"
  cat >"$T/v4216bin/herdr" <<S
#!/usr/bin/env bash
[ "\${3:-} \${4:-}" = "api snapshot" ] && { cat "$T/v4216.snap"; exit 0; }
exec "$T/bin/herdr" "\$@"
S
  chmod +x "$T/v4216bin/herdr"
}

v4216_events() {
  local now=2026-10-29T10:00:00Z ne
  export FLEET_NOW=$now; ne="$(jq -rn --arg t "$now" '$t | fromdateiso8601')"
  v4216_state ev
  v4216_feed "$v4216_ack" "$(v4216_exit pxa-builder)" >/dev/null
  eq "v4216 a pane.exited event is one dead wake line in the fixed template" "$(v4216_wl)" "fleet tick: dead xa xa/builder - - -"
  v4216_feed "$v4216_ack" "$(v4216_exit pxa-builder)" >/dev/null
  eq "v4216 the same exit again adds no second line" "$(v4216_wl | wc -l | tr -d ' ')" 1
  eq "v4216 a handled event refreshes events.alive" "$(test -f "$FLEET_STATE_DIR/events.alive" && echo yes)" yes
  v4216_feed "$v4216_ack" "$(v4216_status pxa-lead blocked)" >/dev/null
  eq "v4216 blocked is one input_pending line" "$(v4216_wl | tail -n 1)" "fleet tick: input_pending xa xa/lead - - -"
  v4216_feed "$v4216_ack" "$(v4216_status pxa-lead working)" "$(v4216_status pxa-lead blocked)" >/dev/null
  eq "v4216 blocked again after working is a new episode: a second line" "$(v4216_wl | grep -c input_pending)" 2
  v4216_feed "$v4216_ack" "$(v4216_status pxa-lead idle)" "$(v4216_status pxa-lead "done")" >/dev/null
  eq "v4216 idle and done wake nothing (Stalled stays tick's)" "$(v4216_wl | wc -l | tr -d ' ')" 3
  "$REG" set xa/builder status=Retired >/dev/null; "$REG" set xa/lead status=Parked >/dev/null
  rm -f "$FLEET_STATE_DIR/events.seen.json"
  v4216_feed "$v4216_ack" "$(v4216_exit pxa-builder)" "$(v4216_status pxa-lead blocked)" "$(v4216_exit pzzz)" >/dev/null
  eq "v4216 Retired, Parked and unknown panes wake nothing" "$(v4216_wl | wc -l | tr -d ' ')" 3

  # no free text: only enumerated fields of the registry row reach wakes.log
  v4216_state ft
  v4216_feed "$v4216_ack" '{"event":"pane.exited","data":{"pane_id":"pxa-builder","message":"rm -rf $(evil) `x`","name":"evil/name"}}' >/dev/null
  eq "v4216 event free text never reaches wakes.log" "$(v4216_wl | grep -c 'evil\|rm -rf')" 0
  eq "v4216 every wake line matches the template" "$(v4216_wl | grep -Ec '^fleet tick: [a-z_]+ [A-Za-z0-9._:/@#-]+ [A-Za-z0-9._:/@#-]+ - - -$')" 1
  eq "v4216 wakes.log is mode 600" "$(stat -c %a "$FLEET_STATE_DIR/wakes.log" 2>/dev/null || stat -f %Lp "$FLEET_STATE_DIR/wakes.log")" 600

  # the rotation is the loop's: 500 lines, then wakes.log.1
  v4216_state rot
  seq 1 499 | sed 's/^/fleet tick: dead t n - - -/' >"$FLEET_STATE_DIR/wakes.log"
  v4216_feed "$v4216_ack" "$(v4216_exit pxa-builder)" "$(v4216_status pxa-lead blocked)" >/dev/null
  eq "v4216 past 500 lines the old file moves to wakes.log.1 and a new one starts" "$(wc -l <"$FLEET_STATE_DIR/wakes.log.1" | tr -d ' '):$(v4216_wl | wc -l | tr -d ' ')" "500:1"
  unset FLEET_NOW; : "$ne"
}

v4216_dedupe() {
  local now=2026-10-29T10:00:00Z ne ft="$T/v4216.tick" out
  export FLEET_NOW=$now; ne="$(jq -rn --arg t "$now" '$t | fromdateiso8601')"
  cat >"$ft" <<'S'
#!/usr/bin/env bash
echo '[{"type":"dead","team":"xa","name":"xa/builder","status":"Zombie"}]'
S
  chmod +x "$ft"
  v4216_state dd
  v4216_feed "$v4216_ack" "$(v4216_exit pxa-builder)" >/dev/null
  v4216_touch "$FLEET_STATE_DIR/events.alive" $((ne - 30))
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v4216 the subscriber woke it, then tick reports the same death: still one line" "$(v4216_wl | wc -l | tr -d ' ')" 1
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v4216 a later tick report of a new death is written (the dedupe is used up)" "$(v4216_wl | wc -l | tr -d ' ')" 2
  # a stale events.alive: tick writes the wake itself, as it always did
  v4216_state st
  v4216_feed "$v4216_ack" "$(v4216_exit pxa-builder)" >/dev/null
  out="$(v4216_wl)"
  v4216_touch "$FLEET_STATE_DIR/events.alive" $((ne - 300))
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v4216 a stale events.alive: tick writes its own dead line" "$(v4216_wl | wc -l | tr -d ' '):$(v4216_wl | tail -n 1)" "2:$out"
  # no subscriber at all
  v4216_state no; rm -f "$FLEET_STATE_DIR/events.alive" "$FLEET_STATE_DIR/events.seen.json"
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v4216 no subscriber: tick behaves as today, one dead line" "$(v4216_wl)" "fleet tick: dead xa xa/builder - - -"
  eq "v4216 and raises no events_down alert (it never ran)" "$(jq -r '(.alerts // {}) | has("events_down")' "$FLEET_STATE_DIR/loop.state.json")" false
  # it ran and went quiet while a team is booted: one alert
  : >"$FLEET_STATE_DIR/events.alive"; v4216_touch "$FLEET_STATE_DIR/events.alive" $((ne - 600))
  FLEET_TICK="$ft" "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v4216 a subscriber that went quiet raises events_down once" "$(jq -r '(.alerts // {}) | has("events_down")' "$FLEET_STATE_DIR/loop.state.json")" true
  unset FLEET_NOW FLEET_TICK
}

v4216_lost() {
  v4216_state lo
  # the snapshot lists only the lead's pane, and it is blocked: the builder's pane is gone
  v4216_snap '{"result":{"workspaces":[{"tabs":[{"panes":[{"pane_id":"pxa-lead","agent_status":"blocked"}]}]}]}}'
  PATH="$T/v4216bin:$PATH" v4216_feed "$v4216_ack" '{"event":"events_lost"}' >/dev/null
  eq "v4216 events_lost: resubscribe's snapshot reconcile wakes the gone pane and the blocked one, once each" \
    "$(v4216_wl | sort | paste -sd, -)" "fleet tick: dead xa xa/builder - - -,fleet tick: input_pending xa xa/lead - - -"
  PATH="$T/v4216bin:$PATH" v4216_feed "$v4216_ack" 'not json at all' >/dev/null
  eq "v4216 a junk line is events_lost too, and the reconcile adds nothing the first did not" "$(v4216_wl | wc -l | tr -d ' ')" 2
  v4216_state eof
  v4216_snap '{"result":{"panes":[{"pane_id":"pxa-lead","agent_status":"working"},{"pane_id":"pxa-builder","agent_status":"idle"}]}}'
  PATH="$T/v4216bin:$PATH" v4216_feed "$v4216_ack" >/dev/null
  eq "v4216 EOF reconciles: every pane alive and not blocked wakes nothing" "$(v4216_wl | wc -l | tr -d ' ')" 0
  v4216_state odd
  v4216_snap '{"result":{"something":"else"}}'
  PATH="$T/v4216bin:$PATH" v4216_feed "$v4216_ack" >/dev/null
  eq "v4216 a snapshot with no pane records is not trusted: no mass deaths" "$(v4216_wl | wc -l | tr -d ' ')" 0
}

v4216_run() { # run: subscribe through an nc shim, read the stream, reconcile at EOF, no backoff sleep
  local nc="$T/v4216.nc"
  v4216_state rn
  cat >"$nc" <<S
#!/usr/bin/env bash
head -n 1 >"$T/v4216.sub"
printf '%s\n' '$v4216_ack' '{"event":"pane.exited","data":{"pane_id":"pxa-builder"}}'
S
  chmod +x "$nc"
  FLEET_NC="$nc" FLEET_EVENTS_ONCE=1 "$SCRIPTS/events.sh" run >/dev/null 2>>"$T/v4216.err"
  eq "v4216 run subscribes to both event types" "$(jq -r '[.method, (.params.subscriptions | map(.type) | join("+"))] | join(" ")' "$T/v4216.sub")" "events.subscribe pane.exited+pane.agent_status_changed"
  eq "v4216 run turns the streamed exit into the wake" "$(v4216_wl)" "fleet tick: dead xa xa/builder - - -"
  eq "v4216 without nc it says tick polling still works and exits 1" \
    "$(FLEET_NC=/nonexistent/nc "$SCRIPTS/events.sh" run 2>&1 >/dev/null; echo "rc=$?")" "fleet: warning: nc is not installed, so the event subscriber cannot run; tick polling still catches dead and blocked agents
rc=1"
}

v4216_status_line() {
  local ne; export FLEET_NOW=2026-10-29T10:00:00Z; ne="$(jq -rn --arg t "$FLEET_NOW" '$t | fromdateiso8601')"
  v4216_state sl; export FLEET_NC="$T/v4216.nc"
  eq "v4216 status: never run" "$("$SCRIPTS/events.sh" status)" "Event subscriber: not running (tick polls). Run fleet schedule install."
  : >"$FLEET_STATE_DIR/events.alive"; v4216_touch "$FLEET_STATE_DIR/events.alive" $((ne - 60))
  eq "v4216 status: up when events.alive is under 2 minutes old" "$("$SCRIPTS/events.sh" status)" "Event subscriber: up."
  v4216_touch "$FLEET_STATE_DIR/events.alive" $((ne - 121))
  eq "v4216 status: down when it is older" "$("$SCRIPTS/events.sh" status | cut -c1-39)" "Event subscriber: down (events.alive is"
  unset FLEET_NOW FLEET_NC
}

v4216_job() { # the launchd job: KeepAlive, its own launcher, installed next to the tick job
  local p="$T/v4216.plist" l
  FLEET_LAUNCH_AGENTS="$T/la" "$SCRIPTS/schedule.sh" render-events >"$p"
  check "v4216 the events plist is valid XML" plutil -lint "$p"
  eq "v4216 label is fleet.events, KeepAlive and RunAtLoad, no interval" \
    "$(plutil -extract Label raw "$p"):$(plutil -extract KeepAlive raw "$p"):$(plutil -extract RunAtLoad raw "$p"):$(plutil -extract StartInterval raw "$p" 2>&1 | grep -c 'No value')" "fleet.events:true:true:1"
  eq "v4216 it runs the events launcher in the state dir" "$(plutil -extract ProgramArguments json -o - "$p" | jq -c .)" "[\"/bin/bash\",\"$FLEET_STATE_DIR/bin/fleet-events\"]"
  l="$("$SCRIPTS/schedule.sh" launcher-events)"
  eq "v4216 the launcher runs events.sh run from the installed version" "$(grep -c 'events.sh run' "$l"):$(grep -c 'loop-tick' "$l")" "1:0"
}

v4216_docs() {
  local R="$SCRIPTS/../README.md"
  eq "v4216 the README has its What changed in 4.2.16 section" "$(grep -c '^## What changed in 4.2.16' "$R")" 1
  check "v4216 the fleet command index lists events" bash -c "'$SCRIPTS/fleet' help | grep -q 'fleet events status'"
}

v4216_smoke() { v4216_events; v4216_dedupe; v4216_lost; v4216_run; v4216_status_line; v4216_job; v4216_docs; }
v4216_full() { v4216_smoke; }
