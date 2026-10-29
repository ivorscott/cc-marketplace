#!/usr/bin/env bash
# 4.1.3, bugs 10 and 11: retire --outcome wins over the rows' outcome, and retire never touches an issue or claim
# another machine holds. Sourced by v413.sh.
v413_retire_db() { # v413_retire_db <label on DEV-1: fleet:peera | fleet:test | none>: a fake Linear with DEV-1 in progress
  local lab="$1" kf="linear_api""_key" ids='[]'
  export LINEAR_STUB_KEY=KEYFIXTURE-v413 LINEAR_DB="$FLEET_STATE_DIR/linear.json" LINEAR_LOG="$FLEET_STATE_DIR/linear.log" FLEET_CURL="$HERE/linear-stub.sh"
  : >"$LINEAR_LOG"
  case "$lab" in fleet:peera) ids='["L1"]' ;; fleet:test) ids='["L2"]' ;; esac
  jq -n --argjson ids "$ids" '{team: "T1", states: {Done: "S3", Todo: "S2"}, next: 100, labels: [{id: "L0", name: "fleet", description: "", parent: null},
      {id: "L1", name: "fleet:peera", description: "heartbeat=2026-10-29T09:55:00Z", parent: {id: "L0", name: "fleet"}},
      {id: "L2", name: "fleet:test", description: "heartbeat=2026-10-29T09:55:00Z", parent: {id: "L0", name: "fleet"}}],
    issues: [{id: "I1", identifier: "DEV-1", team: {id: "T1"}, state: {id: "S1", name: "In Progress"}, labelIds: $ids, comments: []}]}' >"$LINEAR_DB"
  printf 'KEYFIXTURE-v413\n' >"$FLEET_CONFIG_DIR/$kf"; chmod 600 "$FLEET_CONFIG_DIR/$kf"; gcfg 'linear_writes = "on"'
}
v413_retire_team() { # v413_retire_team <team> [outcome]: a Done lead and builder on DEV-1
  v413_agent "$1/lead" Lead Done "outcome=${2:-}"; v413_agent "$1/builder" Worker Done "outcome=${2:-}"
}

v413_retire() {
  local o
  v413_state ret; export FLEET_NOW=2026-10-29T10:00:00Z
  # bug 10: an explicit --outcome is what the rows get, whatever they reported
  v413_retire_db none
  v413_retire_team rt-a Shipped
  o="$("$SCRIPTS/retire.sh" rt-a --outcome Partial 2>/dev/null | head -n 1)"
  eq "v413-10 retire: --outcome Partial over rows that reported Shipped: the line and every row say Partial" \
    "$(printf '%s' "$o" | grep -c '(Partial)'):$("$REG" list | jq -r '[.[] | select(.team == "rt-a") | .outcome] | unique | join(",")')" "1:Partial"
  eq "v413-10 retire: and the issue is not moved to Done" "$(grep -c '^mutation IssueUpdate' "$LINEAR_LOG")" 0
  v413_retire_team rt-b Shipped
  o="$("$SCRIPTS/retire.sh" rt-b 2>/dev/null | head -n 1)"
  eq "v413-10 retire: with no --outcome the rows' own outcome still shows" "$(printf '%s' "$o" | grep -c '(Shipped)')" 1
  # bug 11: another machine's issue and claim are left alone, whatever the outcome
  local out
  for out in Shipped Partial Abandoned Failed none; do
    v413_retire_db fleet:peera; v413_retire_team "rt-$out" "$([ "$out" = none ] || echo "$out")"
    if [ "$out" = none ]; then "$SCRIPTS/retire.sh" "rt-$out" >/dev/null 2>"$T/v413.err"
    else "$SCRIPTS/retire.sh" "rt-$out" --outcome "$out" >/dev/null 2>"$T/v413.err"; fi
    eq "v413-11 retire: ($out) an issue another machine holds is not moved and its label stays" \
      "$(grep -c '^mutation' "$LINEAR_LOG"):$(jq -r '.issues[0].labelIds | join(",")' "$LINEAR_DB"):$(jq -r '.issues[0].state.name' "$LINEAR_DB"):$(grep -c 'left DEV-1 alone: fleet:peera holds it' "$T/v413.err")" "0:L1:In Progress:$([ "$out" = Partial ] && echo 0 || echo 1)"
  done
  v413_retire_db fleet:test; v413_retire_team rt-own Shipped
  "$SCRIPTS/retire.sh" rt-own --outcome Shipped >/dev/null 2>&1
  eq "v413-11 retire: an issue this machine holds still moves" "$(jq -r '.issues[0].state.name' "$LINEAR_DB")" "Done"
  v413_retire_db none; jq '.issues[0].identifier = "DEV-2"' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"; v413_retire_team rt-unread Shipped
  "$SCRIPTS/retire.sh" rt-unread --outcome Shipped >/dev/null 2>"$T/v413.err"
  eq "v413-11 retire: a holder that cannot be read leaves the issue alone, with a warning" "$(grep -c '^mutation' "$LINEAR_LOG"):$(grep -c 'left DEV-1 alone: could not tell who holds it' "$T/v413.err")" "0:1"
  gcfg; v413_nolinear; unset FLEET_NOW
}

# ---- 8: a message to a finished team brings it back ---------------------------------------------------------------
v413_revive_team() { # v413_revive_team <team> <status> <pr number>: lead, builder, tester with the PR, herdr knows none of them
  local r
  for r in lead builder tester; do
    "$REG" add "$(jq -cn --arg t "$1" --arg r "$r" --arg st "$2" --arg repo "$QD/repo-rv" --arg u "https://github.com/acme/app-api/pull/$3" '{name: ($t + "/" + $r), team: $t, tier: (if $r == "lead" then "Lead" else "Worker" end),
      template: "build", harness: "claude", status: $st, herdr_ref: ($t + "-" + $r), pane: ("p" + $t + $r), workspace: "w", repo: $repo, cwd: $repo, assignment: "task", issue: "DEV-1", pr: $u}')" >/dev/null
    echo gone >"$AS/$1-$r"
  done
}
v413_revive() {
  qfresh v413rv; export FLEET_STATE_DIR="$QD/state.v413rv" FLEET_REGISTRY="$QD/state.v413rv/fleet.json" FLEET_INBOX="$QD/state.v413rv/escalations.jsonl" FLEET_WORKTREES="$QD/state.v413rv/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; rm -f "$AS"/*; git init -q -b main "$QD/repo-rv" 2>/dev/null
  export FLEET_GH="$QD/gh-shim" PROMPT_SEQ=1; gcfg "teams_per_repo = 9" "max_teams = 9"
  local o rc b
  qpr app-api 80 fleet/dev-1-x main 2026-10-29T08:00:00Z '["a.go"]' x
  v413_revive_team rv-a Done 80; "$REG" signoff rv-a/tester https://github.com/acme/app-api/pull/80 aaaaaaa80 >/dev/null
  o="$("$SCRIPTS/tell.sh" rv-a/lead "please answer the review comment" 2>&1)"; rc=$?
  b="$("$REG" get rv-a/lead | jq -r .last_brief)"
  eq "v413-8 tell: a message to a Done team with an open PR brings it back" \
    "$rc:$(printf '%s' "$o" | grep -c '(revived)$'):$("$REG" get rv-a/lead | jq -r .status):$("$REG" get rv-a/builder | jq -r .status):$("$REG" get rv-a/tester | jq -r .status)" "0:1:Working:Idle:Idle"
  eq "v413-8 tell: the lead's brief holds the message, and the PR, branch and sign-off are unchanged" \
    "$(grep -c 'please answer the review comment' "$b"):$("$REG" get rv-a/builder | jq -r .pr):$("$REG" get rv-a/tester | jq -r .signoff.sha)" "1:https://github.com/acme/app-api/pull/80:aaaaaaa80"
  eq "v413-8 tell: nothing was booted or retired" "$(jq -s '[.[] | select(.type == "boot" or .type == "retired")] | length' "$FLEET_STATE_DIR/events.jsonl" 2>/dev/null || echo 0)" 0
  # a message for a worker goes to the lead
  v413_revive_team rv-b Done 80
  "$SCRIPTS/tell.sh" rv-b/builder "check the build" >/dev/null 2>&1
  eq "v413-8 tell: a message for a worker revives the team and goes to the lead, naming the role" \
    "$(grep -c '(meant for builder) check the build' "$("$REG" get rv-b/lead | jq -r .last_brief)")" 1
  # a bare team name, and a parked team
  v413_revive_team rv-c Parked 80
  o="$("$SCRIPTS/tell.sh" rv-c "back to work" 2>&1)"; rc=$?
  eq "v413-8 tell: a bare team name revives a parked team the same way" "$rc:$(printf '%s' "$o" | grep -c '(revived)$'):$("$REG" list --team rv-c | jq -r '[.[].status] | unique | join(",")')" "0:1:Idle,Working"
  # a merged PR is refused and the rows are left as they were
  qpr app-api 81 fleet/dev-2-x main 2026-10-29T08:00:00Z '["b.go"]' x; jq '.state = "MERGED"' "$QGHD/app-api-81.json" >"$QD/m.json" && mv "$QD/m.json" "$QGHD/app-api-81.json"
  v413_revive_team rv-d Done 81
  o="$("$SCRIPTS/tell.sh" rv-d/lead "one more thing" 2>&1)"; rc=$?
  eq "v413-8 tell: a merged PR is refused with what to do instead, and the rows stay Done" \
    "$rc:$(printf '%s' "$o" | grep -c 'Boot a new team, or move the team on'):$("$REG" list --team rv-d | jq -r '[.[].status] | unique | join(",")')" "1:1:Done"
  unset PROMPT_SEQ FLEET_GH; gcfg
}

# ---- 12: slot_free only when a slot is usable -----------------------------------------------------------------------
v413_slots() {
  v413_state slot; export FLEET_NOW=2026-10-29T10:00:00Z
  git init -q -b main "$T/v413-slot-repo" 2>/dev/null
  local ra="$T/v413-slot-repo" evc_
  evc_() { printf '%s' "$1" | jq -s '[.[][]? | select(.type == "slot_free")] | length'; }
  "$REG" add '{"name":"orchestrator","team":"orchestrator","tier":"Orchestrator","status":"Working","herdr_ref":"o2","pane":"po2"}' >/dev/null
  "$REG" set orchestrator target_teams=3 >/dev/null
  "$REG" add "$(jq -cn --arg r "$ra" '{name: "sl-a/lead", team: "sl-a", tier: "Lead", status: "Working", herdr_ref: "sl-a-lead", pane: "psla", repo: $r, issue: "DEV-1"}')" >/dev/null
  v413_retire_db none
  gcfg 'linear_writes = "on"' "repos = [\"$ra\"]" "teams_per_repo = 1" "max_teams = 9"
  jq '.issues += [{id: "I2", identifier: "DEV-2", team: {id: "T1"}, state: {id: "S0", name: "Todo"}, labelIds: [], comments: []}]' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  tk() { FLEET_NOW="$1" "$SCRIPTS/tick.sh" 2>/dev/null; }
  eq "v413-12 slots: every repo busy (teams_per_repo 1), several ticks, no slot_free" "$(evc_ "$(tk 2026-10-29T10:00:00Z)")$(evc_ "$(tk 2026-10-29T10:01:00Z)")" "00"
  "$REG" retire sl-a >/dev/null; "$REG" add "$(jq -cn --arg r "$ra" '{name: "sl-b/lead", team: "sl-b", tier: "Lead", status: "Working", herdr_ref: "sl-b-lead", pane: "pslb", repo: $r, issue: "DEV-1"}')" >/dev/null
  "$REG" park sl-b park >/dev/null
  # a free repo and a candidate (DEV-2 is Todo; DEV-1 is held by a local team's row)
  s1="$(tk 2026-10-29T10:02:00Z)"; s2="$(tk 2026-10-29T10:03:00Z)"
  eq "v413-12 slots: a free repo with a candidate fires exactly once, not on the next tick" "$(evc_ "$s1"):$(evc_ "$s2")" "1:0"
  # every candidate blocked: none
  "$REG" retire sl-b >/dev/null; "$REG" set orchestrator target_teams=4 >/dev/null
  jq '.issues[1].blocked_by = ["DEV-1"] | .issues[0].blocked_by = ["DEV-2"]' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  jq 'del(.cand_cache)' "$FLEET_STATE_DIR/tick.state.json" >"$FLEET_STATE_DIR/t.t" && mv "$FLEET_STATE_DIR/t.t" "$FLEET_STATE_DIR/tick.state.json"
  eq "v413-12 slots: only a blocked or claimed candidate: none" "$(evc_ "$(tk 2026-10-29T10:20:00Z)")" 0
  v413_nolinear
  eq "v413-12 slots: with no Linear key it fires on the target and the repos alone, and says so" \
    "$(tk 2026-10-29T10:40:00Z | jq -s -r '[.[][]? | select(.type == "slot_free") | .detail] | first // ""')" "0 live < target 4; no Linear key, candidates not checked"
  gcfg; unset FLEET_NOW
}

# ---- 9: unsent text in the input box ----------------------------------------------------------------------------------
v413_input_box() {
  v413_state inb; export FLEET_NOW=2026-10-29T10:00:00Z
  v413_agent ib-a/lead Lead Idle herdr_ref=ib-lead; v413_agent ib-a/builder Worker Idle herdr_ref=ib-b
  local box=$'earlier output\n────────\n❯ yes go ahead and merge\n────────\n  ? for shortcuts' o
  # tell clears a pre-filled box first, then delivers only its message
  printf '%s\n' "$box" >"$AS/ib-lead.read"; : >"$HERDR_LOG"
  o="$("$SCRIPTS/tell.sh" ib-a/lead "check the build" 2>&1)"
  eq "v413-9 tell: text in the box is cleared with ctrl+u before the message is typed" \
    "$(grep -n 'agent send-keys ib-lead ctrl+u\|agent prompt ib-lead check the build' "$HERDR_LOG" | cut -d: -f2- | sed 's/ \{1,\}/ /g' | paste -sd'|' -):$(told "$o")" \
    "agent send-keys ib-lead ctrl+u|agent prompt ib-lead check the build:true"
  printf '%s\n' $'earlier output\n────────\n❯ \n────────' >"$AS/ib-lead.read"; : >"$HERDR_LOG"; "$SCRIPTS/tell.sh" ib-a/lead "second" >/dev/null 2>&1
  eq "v413-9 tell: an empty box gets no key" "$(grep -c 'send-keys' "$HERDR_LOG")" 0
  printf '%s\n' "$box" >"$AS/ib-lead.read"; echo blocked >"$AS/ib-lead"; : >"$HERDR_LOG"; "$SCRIPTS/tell.sh" ib-a/lead "third" >/dev/null 2>&1
  eq "v413-9 tell: a blocked agent (a dialog) is sent no key" "$(grep -c 'send-keys' "$HERDR_LOG")" 0
  rm -f "$AS/ib-lead"; printf '%s\n' "$box" >"$AS/ib-lead.read"; : >"$HERDR_LOG"
  SEND_KEYS_FAIL=ctrl+u "$SCRIPTS/tell.sh" ib-a/lead "fourth" >/dev/null 2>"$T/ib.err"; rc=$?
  eq "v413-9 tell: when herdr refuses ctrl+u nothing is typed, and no other key is tried" "$rc:$(grep -c 'agent prompt' "$HERDR_LOG"):$(grep -c 'send-keys' "$HERDR_LOG"):$(grep -c 'agent send-keys ib-lead ctrl+u' "$HERDR_LOG")" "1:0:1:1"
  # tick records the text, raises it once per text, clears it when the box is empty; status shows it
  printf '%s\n' "$box" >"$AS/ib-lead.read"; rm -f "$AS/ib-lead" "$AS/ib-b"; : >"$HERDR_LOG"
  t1="$("$SCRIPTS/tick.sh" 2>/dev/null)"; t2="$("$SCRIPTS/tick.sh" 2>/dev/null)"
  eq "v413-9 tick: the unsent text is on the row and raised once" \
    "$("$REG" get ib-a/lead | jq -r .input_flag):$(printf '%s' "$t1" | jq -s '[.[][]? | select(.type == "input_pending")] | length'):$(printf '%s' "$t2" | jq -s '[.[][]? | select(.type == "input_pending")] | length')" "yes go ahead and merge:1:0"
  eq "v413-9 tick: nothing was sent or cleared" "$(grep -c 'send-keys\|agent prompt' "$HERDR_LOG")" 0
  eq "v413-9 status: the Needs you cell says it" "$(bash -c '. "$1/common.sh"; render_table' _ "$SCRIPTS" | grep '^| ib-a ' | grep -c "unsent text in lead's input box")" 1
  eq "v413-9 wake: the notice says it was not typed by the owner" \
    "$(bash -c '. "$1/common.sh"; render_notice "$2"' _ "$SCRIPTS" '{"type":"input_pending","team":"ib-a","name":"ib-a/lead","detail":"yes go ahead"}')" \
    "Unsent text in ib-a/lead's input box: \"yes go ahead\". It was not typed by the owner; clear it before answering."
  printf '%s\n' $'x\n────────\n❯ \n────────' >"$AS/ib-lead.read"; "$SCRIPTS/tick.sh" >/dev/null 2>&1
  eq "v413-9 tick: an empty box clears the field" "$("$REG" get ib-a/lead | jq -r '.input_flag // ""')" ""
  # the settings file and the pane env
  v413_agent ib-a/tester Worker Idle
  eq "v413-9 settings: promptSuggestionEnabled is false in the --settings file" \
    "$(bash -c '. "$1/common.sh"; registry=x; tool_allow="[]"; . "$1/agent-lib.sh"; f="$(claude_args "" Worker /tmp "[]" | tr "\0" "\n" | sed -n 2p)"; jq -r .promptSuggestionEnabled "$f"' _ "$SCRIPTS")" "false"
  eq "v413-9 pane env: boot and respawn pass CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0 for the lead and the workers" \
    "$(grep -c 'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=0' "$SCRIPTS/boot.sh" "$SCRIPTS/respawn.sh" | paste -sd, - | sed 's#[^:,]*:##g')" "2,2"
  unset FLEET_NOW
}
