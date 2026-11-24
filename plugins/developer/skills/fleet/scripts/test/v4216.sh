#!/usr/bin/env bash
# 4.2.16 (DEV-1107): herdr resumes its own sessions after a server restart, reboot or wake; tick waits one resume window
# before it respawns, and boot warns when the server's environment came from a Claude session. Sourced by run.sh after
# v4215.sh, whose neighbours' helpers it uses (v4211_state, v4211_end, v413_agent, v420_tick, v420_evn) with run.sh's own
# (eq, REG, AS, HERDR_LOG, the herdr, lsof and ps shims). Generic names only.
v4216_nstart() { grep -c "^agent start $1 " "$HERDR_LOG" || true; } # how often the agent was started
v4216_team() { # v4216_team <team>: a booted team, every row Idle, the server (pid 100) seen healthy at 10:00
  git -C "$QD/repo-rv" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m base 2>/dev/null || true
  "$SCRIPTS/boot.sh" build "$1" "$QD/repo-rv" "task" >/dev/null 2>"${V4216_ERR:-/dev/null}"
  local r; for r in lead planner builder tester; do "$REG" set "build-$1/$r" status=Idle >/dev/null; done
  rm -f "$FLEET_STATE_DIR/tick.state.json"; echo 100 >"$AS/server.pid"; v420_tick 2026-10-20T10:00:00Z >/dev/null; : >"$HERDR_LOG"
}
v4216_ts() { jq -r "$1" "$FLEET_STATE_DIR/tick.state.json"; }

v4216_restart() {
  v4211_state rs
  export FLEET_RESPAWN_MAX=1 FLEET_RESUME_WINDOW_SECS=120 FLEET_FORCE=1 # several live teams on one repo
  local ev
  # a new server pid: the agent is not back yet
  v4216_team rsr; echo 200 >"$AS/server.pid"; echo gone >"$AS/build-rsr-builder"
  v420_tick 2026-10-20T10:05:00Z >/dev/null; ev="$(v420_tick 2026-10-20T10:06:00Z)"
  eq "v4216 Zombie twice inside the resume window is not respawned" "$(v4216_nstart build-rsr-builder)" 0
  eq "v4216 and no dead event" "$(v420_evn "$ev" dead)" 0
  eq "v4216 and the respawn budget is unspent" "$(v4216_ts '.respawns // {}' | tr -d ' \n')" '{}'
  eq "v4216 tick records when it saw the restart" "$(v4216_ts '.restart_seen_at // ""')" 2026-10-20T10:05:00Z
  ev="$(v420_tick 2026-10-20T10:08:00Z)"
  eq "v4216 still Zombie after the window: respawned once, with the dead event" "$(v4216_nstart build-rsr-builder):$(v420_evn "$ev" dead)" 1:1
  # herdr resumes the agent inside the window
  v4216_team rsq; echo 300 >"$AS/server.pid"; echo gone >"$AS/build-rsq-builder"
  v420_tick 2026-10-20T10:05:00Z >/dev/null; echo working >"$AS/build-rsq-builder"
  v420_tick 2026-10-20T10:06:00Z >/dev/null; v420_tick 2026-10-20T10:09:00Z >/dev/null
  eq "v4216 an agent herdr resumed in the window is not respawned, and its row is Working" \
    "$(v4216_nstart build-rsq-builder):$("$REG" get build-rsq/builder | jq -r .status)" 0:Working
  # a reboot or wake: the same pid, but no tick for more than 2x tick_secs (300)
  v4216_team rss; echo gone >"$AS/build-rss-builder"
  v420_tick 2026-10-20T11:00:00Z >/dev/null; v420_tick 2026-10-20T11:01:00Z >/dev/null
  eq "v4216 a gap of more than 2x tick_secs counts as a restart: no respawn inside the window" "$(v4216_nstart build-rss-builder)" 0
  v420_tick 2026-10-20T11:03:00Z >/dev/null
  eq "v4216 and the gap case respawns after the window" "$(v4216_nstart build-rss-builder)" 1
  # no restart: the second Zombie tick respawns as before
  v4216_team rst; echo gone >"$AS/build-rst-builder"
  v420_tick 2026-10-20T10:01:00Z >/dev/null; v420_tick 2026-10-20T10:02:00Z >/dev/null
  eq "v4216 with no restart a Zombie is respawned on the second tick" "$(v4216_nstart build-rst-builder)" 1
  unset FLEET_RESPAWN_MAX FLEET_RESUME_WINDOW_SECS FLEET_FORCE; v4211_end
}

v4216_boot_warning() {
  v4211_state bw
  local msg='started inside a Claude session' w
  echo 100 >"$AS/server.pid"
  w="$(HERDR_SERVER_ENV='CLAUDECODE=1 LANG=C' "$SCRIPTS/boot.sh" build bw1 "$QD/repo-rv" "task" 2>&1 >/dev/null)"
  eq "v4216 boot warns when the herdr server was started inside a Claude session" "$(grep -c "$msg" <<<"$w" || true)" 1
  w="$("$SCRIPTS/boot.sh" build bw2 "$QD/repo-rv" "task" 2>&1 >/dev/null)"
  eq "v4216 boot is silent when the server environment is clean" "$(grep -c "$msg" <<<"$w" || true)" 0
  rm -f "$AS/server.pid"
  w="$(HERDR_SERVER_ENV='CLAUDECODE=1' "$SCRIPTS/boot.sh" build bw3 "$QD/repo-rv" "task" 2>&1 >/dev/null)"
  eq "v4216 boot is silent when the server pid cannot be read" "$(grep -c "$msg" <<<"$w" || true)" 0
  v4211_end
}

v4216_smoke() { v4216_restart; v4216_boot_warning; }
v4216_full() { v4216_smoke; }
