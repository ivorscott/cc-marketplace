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
