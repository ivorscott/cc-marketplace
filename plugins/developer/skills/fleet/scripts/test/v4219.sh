#!/usr/bin/env bash
# 4.2.19 (DEV-1112): a builder that idles while its planner has not finished is waiting, not Stalled. Sourced by run.sh
# after v4218.sh, whose helpers it uses (v4218_team, v4211_state, v4211_end, v420_tick, v420_evn) with run.sh's own
# (eq, REG, AS, HERDR_LOG, the herdr shim). Generic names only.
v4219_bst() { "$SCRIPTS/status.sh" "build-$1" --json 2>/dev/null | jq -r '.[] | select(.name == "build-'"$1"'/builder") | .status'; }
v4219_idle() { local t="$1" r; shift; for r in "$@"; do echo idle >"$AS/build-$t-$r"; done; } # v4219_idle <team> <role>...
v4219_nudges() { grep -c "^agent send-keys build-$1-builder" "$HERDR_LOG" || true; } # keys sent to the team's builder

v4219_planner_wait() {
  v4211_state pw
  export FLEET_FORCE=1 # several live teams on one repo
  local ev
  # the planner is working: the idle builder is waiting for the plan
  v4218_team pw1; "$REG" set build-pw1/planner status=Working >/dev/null; "$REG" set build-pw1/builder status=Working >/dev/null; v4219_idle pw1 planner builder
  eq "v4219 planner Working: the idle builder is Idle, not Stalled" "$(v4219_bst pw1)" Idle
  v420_tick 2026-10-20T10:05:00Z >/dev/null; ev="$(v420_tick 2026-10-20T10:10:00Z)"
  eq "v4219 and tick sends no nudge and raises no stalled event" "$(v4219_nudges pw1):$(v420_evn "$ev" stalled)" 0:0
  # the plan is done: the rule bites again
  "$REG" set build-pw1/planner status=Done >/dev/null; "$REG" set build-pw1/builder status=Working >/dev/null; v4219_idle pw1 builder
  eq "v4219 planner Done: the idle builder with no done step is Stalled" "$(v4219_bst pw1)" Stalled
  # nothing left to wait for
  v4218_team pw2; v4219_idle pw2 planner builder; "$REG" set build-pw2/planner status=Failed >/dev/null; "$REG" set build-pw2/builder status=Working >/dev/null
  eq "v4219 planner Failed: the builder is Stalled" "$(v4219_bst pw2)" Stalled
  "$REG" set build-pw2/planner status=Retired >/dev/null; "$REG" set build-pw2/builder status=Working >/dev/null
  eq "v4219 planner Retired: the builder is Stalled" "$(v4219_bst pw2)" Stalled
  # a team with no planner row
  "$REG" add '{"name":"build-pw3/builder","team":"build-pw3","repo":"'"$QD/repo-rv"'","tier":"Worker","status":"Working","herdr_ref":"build-pw3-builder","pane":"p"}' >/dev/null; v4219_idle pw3 builder
  eq "v4219 no planner row: the builder is Stalled as before" "$(v4219_bst pw3)" Stalled
  # only the builder is spared: the tester is not
  v4218_team pw4; "$REG" set build-pw4/planner status=Working >/dev/null; "$REG" set build-pw4/tester status=Working >/dev/null; v4219_idle pw4 planner tester
  eq "v4219 the tester is not spared while the planner works" "$("$SCRIPTS/status.sh" build-pw4 --json 2>/dev/null | jq -r '.[] | select(.name == "build-pw4/tester") | .status')" Stalled
  v4211_end
}

v4219_smoke() { v4219_planner_wait; }
v4219_full() { v4219_smoke; }
