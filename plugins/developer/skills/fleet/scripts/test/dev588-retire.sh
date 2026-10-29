#!/usr/bin/env bash
# DEV-588 (4.1.3), bugs 10 and 11: retire --outcome wins over the rows' outcome, and retire never touches an issue or claim
# another machine holds. Sourced by dev588.sh.
d588_retire_db() { # d588_retire_db <label on DEV-1: fleet:peera | fleet:test | none>: a fake Linear with DEV-1 in progress
  local lab="$1" kf="linear_api""_key" ids='[]'
  export LINEAR_STUB_KEY=KEYFIXTURE-d588 LINEAR_DB="$FLEET_STATE_DIR/linear.json" LINEAR_LOG="$FLEET_STATE_DIR/linear.log" FLEET_CURL="$HERE/linear-stub.sh"
  : >"$LINEAR_LOG"
  case "$lab" in fleet:peera) ids='["L1"]' ;; fleet:test) ids='["L2"]' ;; esac
  jq -n --argjson ids "$ids" '{team: "T1", states: {Done: "S3", Todo: "S2"}, next: 100, labels: [{id: "L0", name: "fleet", description: "", parent: null},
      {id: "L1", name: "fleet:peera", description: "heartbeat=2026-10-29T09:55:00Z", parent: {id: "L0", name: "fleet"}},
      {id: "L2", name: "fleet:test", description: "heartbeat=2026-10-29T09:55:00Z", parent: {id: "L0", name: "fleet"}}],
    issues: [{id: "I1", identifier: "DEV-1", team: {id: "T1"}, state: {id: "S1", name: "In Progress"}, labelIds: $ids, comments: []}]}' >"$LINEAR_DB"
  printf 'KEYFIXTURE-d588\n' >"$FLEET_CONFIG_DIR/$kf"; chmod 600 "$FLEET_CONFIG_DIR/$kf"; gcfg 'linear_writes = "on"'
}
d588_retire_team() { # d588_retire_team <team> [outcome]: a Done lead and builder on DEV-1
  d588_agent "$1/lead" Lead Done "outcome=${2:-}"; d588_agent "$1/builder" Worker Done "outcome=${2:-}"
}

d588_retire() {
  local o
  d588_state ret; export FLEET_NOW=2026-10-29T10:00:00Z
  # bug 10: an explicit --outcome is what the rows get, whatever they reported
  d588_retire_db none
  d588_retire_team rt-a Shipped
  o="$("$SCRIPTS/retire.sh" rt-a --outcome Partial 2>/dev/null | head -n 1)"
  eq "dev588-10 retire: --outcome Partial over rows that reported Shipped: the line and every row say Partial" \
    "$(printf '%s' "$o" | grep -c '(Partial)'):$("$REG" list | jq -r '[.[] | select(.team == "rt-a") | .outcome] | unique | join(",")')" "1:Partial"
  eq "dev588-10 retire: and the issue is not moved to Done" "$(grep -c '^mutation IssueUpdate' "$LINEAR_LOG")" 0
  d588_retire_team rt-b Shipped
  o="$("$SCRIPTS/retire.sh" rt-b 2>/dev/null | head -n 1)"
  eq "dev588-10 retire: with no --outcome the rows' own outcome still shows" "$(printf '%s' "$o" | grep -c '(Shipped)')" 1
  # bug 11: another machine's issue and claim are left alone, whatever the outcome
  local out
  for out in Shipped Partial Abandoned Failed none; do
    d588_retire_db fleet:peera; d588_retire_team "rt-$out" "$([ "$out" = none ] || echo "$out")"
    if [ "$out" = none ]; then "$SCRIPTS/retire.sh" "rt-$out" >/dev/null 2>"$T/d588.err"
    else "$SCRIPTS/retire.sh" "rt-$out" --outcome "$out" >/dev/null 2>"$T/d588.err"; fi
    eq "dev588-11 retire: ($out) an issue another machine holds is not moved and its label stays" \
      "$(grep -c '^mutation' "$LINEAR_LOG"):$(jq -r '.issues[0].labelIds | join(",")' "$LINEAR_DB"):$(jq -r '.issues[0].state.name' "$LINEAR_DB"):$(grep -c 'left DEV-1 alone: fleet:peera holds it' "$T/d588.err")" "0:L1:In Progress:$([ "$out" = Partial ] && echo 0 || echo 1)"
  done
  d588_retire_db fleet:test; d588_retire_team rt-own Shipped
  "$SCRIPTS/retire.sh" rt-own --outcome Shipped >/dev/null 2>&1
  eq "dev588-11 retire: an issue this machine holds still moves" "$(jq -r '.issues[0].state.name' "$LINEAR_DB")" "Done"
  d588_retire_db none; jq '.issues[0].identifier = "DEV-2"' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"; d588_retire_team rt-unread Shipped
  "$SCRIPTS/retire.sh" rt-unread --outcome Shipped >/dev/null 2>"$T/d588.err"
  eq "dev588-11 retire: a holder that cannot be read leaves the issue alone, with a warning" "$(grep -c '^mutation' "$LINEAR_LOG"):$(grep -c 'left DEV-1 alone: could not tell who holds it' "$T/d588.err")" "0:1"
  gcfg; d588_nolinear; unset FLEET_NOW
}

# ---- 8: a message to a finished team brings it back ---------------------------------------------------------------
d588_revive_team() { # d588_revive_team <team> <status> <pr number>: lead, builder, tester with the PR, herdr knows none of them
  local r
  for r in lead builder tester; do
    "$REG" add "$(jq -cn --arg t "$1" --arg r "$r" --arg st "$2" --arg repo "$QD/repo-rv" --arg u "https://github.com/acme/app-api/pull/$3" '{name: ($t + "/" + $r), team: $t, tier: (if $r == "lead" then "Lead" else "Worker" end),
      template: "build", harness: "claude", status: $st, herdr_ref: ($t + "-" + $r), pane: ("p" + $t + $r), workspace: "w", repo: $repo, cwd: $repo, assignment: "task", issue: "DEV-1", pr: $u}')" >/dev/null
    echo gone >"$AS/$1-$r"
  done
}
d588_revive() {
  qfresh d588rv; export FLEET_STATE_DIR="$QD/state.d588rv" FLEET_REGISTRY="$QD/state.d588rv/fleet.json" FLEET_INBOX="$QD/state.d588rv/escalations.jsonl" FLEET_WORKTREES="$QD/state.d588rv/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; rm -f "$AS"/*; git init -q -b main "$QD/repo-rv" 2>/dev/null
  export FLEET_GH="$QD/gh-shim" PROMPT_SEQ=1; gcfg "teams_per_repo = 9" "max_teams = 9"
  local o rc b
  qpr app-api 80 fleet/dev-1-x main 2026-10-29T08:00:00Z '["a.go"]' x
  d588_revive_team rv-a Done 80; "$REG" signoff rv-a/tester https://github.com/acme/app-api/pull/80 aaaaaaa80 >/dev/null
  o="$("$SCRIPTS/tell.sh" rv-a/lead "please answer the review comment" 2>&1)"; rc=$?
  b="$("$REG" get rv-a/lead | jq -r .last_brief)"
  eq "dev588-8 tell: a message to a Done team with an open PR brings it back" \
    "$rc:$(printf '%s' "$o" | grep -c '(revived)$'):$("$REG" get rv-a/lead | jq -r .status):$("$REG" get rv-a/builder | jq -r .status):$("$REG" get rv-a/tester | jq -r .status)" "0:1:Working:Idle:Idle"
  eq "dev588-8 tell: the lead's brief holds the message, and the PR, branch and sign-off are unchanged" \
    "$(grep -c 'please answer the review comment' "$b"):$("$REG" get rv-a/builder | jq -r .pr):$("$REG" get rv-a/tester | jq -r .signoff.sha)" "1:https://github.com/acme/app-api/pull/80:aaaaaaa80"
  eq "dev588-8 tell: nothing was booted or retired" "$(jq -s '[.[] | select(.type == "boot" or .type == "retired")] | length' "$FLEET_STATE_DIR/events.jsonl" 2>/dev/null || echo 0)" 0
  # a message for a worker goes to the lead
  d588_revive_team rv-b Done 80
  "$SCRIPTS/tell.sh" rv-b/builder "check the build" >/dev/null 2>&1
  eq "dev588-8 tell: a message for a worker revives the team and goes to the lead, naming the role" \
    "$(grep -c '(meant for builder) check the build' "$("$REG" get rv-b/lead | jq -r .last_brief)")" 1
  # a bare team name, and a parked team
  d588_revive_team rv-c Parked 80
  o="$("$SCRIPTS/tell.sh" rv-c "back to work" 2>&1)"; rc=$?
  eq "dev588-8 tell: a bare team name revives a parked team the same way" "$rc:$(printf '%s' "$o" | grep -c '(revived)$'):$("$REG" list --team rv-c | jq -r '[.[].status] | unique | join(",")')" "0:1:Idle,Working"
  # a merged PR is refused and the rows are left as they were
  qpr app-api 81 fleet/dev-2-x main 2026-10-29T08:00:00Z '["b.go"]' x; jq '.state = "MERGED"' "$QGHD/app-api-81.json" >"$QD/m.json" && mv "$QD/m.json" "$QGHD/app-api-81.json"
  d588_revive_team rv-d Done 81
  o="$("$SCRIPTS/tell.sh" rv-d/lead "one more thing" 2>&1)"; rc=$?
  eq "dev588-8 tell: a merged PR is refused with what to do instead, and the rows stay Done" \
    "$rc:$(printf '%s' "$o" | grep -c 'Boot a new team, or move the team on'):$("$REG" list --team rv-d | jq -r '[.[].status] | unique | join(",")')" "1:1:Done"
  unset PROMPT_SEQ FLEET_GH; gcfg
}

# ---- 12: slot_free only when a slot is usable -----------------------------------------------------------------------
d588_slots() {
  d588_state slot; export FLEET_NOW=2026-10-29T10:00:00Z
  git init -q -b main "$T/d588-slot-repo" 2>/dev/null
  local ra="$T/d588-slot-repo" evc_
  evc_() { printf '%s' "$1" | jq -s '[.[][]? | select(.type == "slot_free")] | length'; }
  "$REG" add '{"name":"orchestrator","team":"orchestrator","tier":"Orchestrator","status":"Working","herdr_ref":"o2","pane":"po2"}' >/dev/null
  "$REG" set orchestrator target_teams=3 >/dev/null
  "$REG" add "$(jq -cn --arg r "$ra" '{name: "sl-a/lead", team: "sl-a", tier: "Lead", status: "Working", herdr_ref: "sl-a-lead", pane: "psla", repo: $r, issue: "DEV-1"}')" >/dev/null
  d588_retire_db none
  gcfg 'linear_writes = "on"' "repos = [\"$ra\"]" "teams_per_repo = 1" "max_teams = 9"
  jq '.issues += [{id: "I2", identifier: "DEV-2", team: {id: "T1"}, state: {id: "S0", name: "Todo"}, labelIds: [], comments: []}]' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  tk() { FLEET_NOW="$1" "$SCRIPTS/tick.sh" 2>/dev/null; }
  eq "dev588-12 slots: every repo busy (teams_per_repo 1), several ticks, no slot_free" "$(evc_ "$(tk 2026-10-29T10:00:00Z)")$(evc_ "$(tk 2026-10-29T10:01:00Z)")" "00"
  "$REG" retire sl-a >/dev/null; "$REG" add "$(jq -cn --arg r "$ra" '{name: "sl-b/lead", team: "sl-b", tier: "Lead", status: "Working", herdr_ref: "sl-b-lead", pane: "pslb", repo: $r, issue: "DEV-1"}')" >/dev/null
  "$REG" park sl-b park >/dev/null
  # a free repo and a candidate (DEV-2 is Todo; DEV-1 is held by a local team's row)
  s1="$(tk 2026-10-29T10:02:00Z)"; s2="$(tk 2026-10-29T10:03:00Z)"
  eq "dev588-12 slots: a free repo with a candidate fires exactly once, not on the next tick" "$(evc_ "$s1"):$(evc_ "$s2")" "1:0"
  # every candidate blocked: none
  "$REG" retire sl-b >/dev/null; "$REG" set orchestrator target_teams=4 >/dev/null
  jq '.issues[1].blocked_by = ["DEV-1"] | .issues[0].blocked_by = ["DEV-2"]' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  jq 'del(.cand_cache)' "$FLEET_STATE_DIR/tick.state.json" >"$FLEET_STATE_DIR/t.t" && mv "$FLEET_STATE_DIR/t.t" "$FLEET_STATE_DIR/tick.state.json"
  eq "dev588-12 slots: only a blocked or claimed candidate: none" "$(evc_ "$(tk 2026-10-29T10:20:00Z)")" 0
  d588_nolinear
  eq "dev588-12 slots: with no Linear key it fires on the target and the repos alone, and says so" \
    "$(tk 2026-10-29T10:40:00Z | jq -s -r '[.[][]? | select(.type == "slot_free") | .detail] | first // ""')" "0 live < target 4; no Linear key, candidates not checked"
  gcfg; unset FLEET_NOW
}
