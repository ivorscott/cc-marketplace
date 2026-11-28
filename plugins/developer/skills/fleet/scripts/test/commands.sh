#!/usr/bin/env bash
# The commands area: the dispatcher (help, the eleven commands, 4.x names, internal commands, errors) and one golden file
# per reply shape of a command and per wake notice (references/output.md). Sourced by run.sh after lib.sh, which gives it
# ok/eq/check, REG, SCRIPTS, T, the herdr shim, gfix, gcfg, gold, qfresh, qpr, qteam and q.

FL="$SCRIPTS/fleet"
OUT_MD="$SCRIPTS/../references/output.md"
ELEVEN="boot candidates claim decide help hold park retire run status tell"

cmd_state() { # cmd_state <name>: a fresh state root, no herdr agent state, no config
  export FLEET_STATE_DIR="$T/cmd-$1" FLEET_REGISTRY="$T/cmd-$1/fleet.json" FLEET_INBOX="$T/cmd-$1/escalations.jsonl" FLEET_WORKTREES="$T/cmd-$1/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; rm -f "$AS"/*; gcfg
}

cmd_linear() { # cmd_linear <extra issues json>: the fake Linear, DEV-1 In Progress claimed by this machine (fleet:test)
  export LINEAR_STUB_KEY=KEYFIXTURE-cmd LINEAR_DB="$FLEET_STATE_DIR/linear.json" LINEAR_LOG="$FLEET_STATE_DIR/linear.log" LINEAR_ARGV_LOG="$FLEET_STATE_DIR/linear.argv" FLEET_CURL="$HERE/linear-stub.sh"
  : >"$LINEAR_LOG"
  jq -n --argjson extra "${1:-[]}" '{team: "T1", states: {Done: "S3", Todo: "S2", Verify: "S4"}, next: 100,
    labels: [{id: "L0", name: "fleet", description: "", parent: null}, {id: "L2", name: "fleet:test", description: "heartbeat=2026-10-29T09:55:00Z", parent: {id: "L0", name: "fleet"}},
             {id: "R1", name: "role:backend", description: "", parent: null}],
    issues: ([{id: "I1", identifier: "DEV-1", team: {id: "T1"}, state: {id: "S1", name: "In Progress"}, labelIds: ["L2"], comments: []}] + $extra)}' >"$LINEAR_DB"
  printf 'KEYFIXTURE-cmd\n' >"$FLEET_CONFIG_DIR/linear_api""_key"; chmod 600 "$FLEET_CONFIG_DIR/linear_api""_key"; gcfg 'linear_writes = "on"'
}
cmd_linear_ids() { # cmd_linear_ids <ID>...: the fake Linear with those issues in Todo, each with a role label, no relations
  export LINEAR_STUB_KEY=KEYFIXTURE-cmd LINEAR_DB="$FLEET_STATE_DIR/linear.json" LINEAR_LOG="$FLEET_STATE_DIR/linear.log" LINEAR_ARGV_LOG="$FLEET_STATE_DIR/linear.argv" FLEET_CURL="$HERE/linear-stub.sh"
  : >"$LINEAR_LOG"
  printf '%s\n' "$@" | jq -R . | jq -s '{team: "T1", states: {Todo: "S2"}, next: 100, labels: [{id: "R1", name: "role:backend", description: "", parent: null}],
    issues: map({id: ("I" + sub("^[A-Z]+-"; "")), identifier: ., team: {id: "T1"}, state: {id: "S2", name: "Todo"}, labelIds: ["R1"], comments: [], title: ("title of " + .), priority: 3})}' >"$LINEAR_DB"
  printf 'KEYFIXTURE-cmd\n' >"$FLEET_CONFIG_DIR/linear_api""_key"; chmod 600 "$FLEET_CONFIG_DIR/linear_api""_key"
}
cmd_nolinear() { rm -f "$FLEET_CONFIG_DIR/linear_api""_key"; unset LINEAR_STUB_KEY LINEAR_DB LINEAR_LOG LINEAR_ARGV_LOG FLEET_CURL; gcfg; }

cmd_issue() { # cmd_issue <ID> <state> <label ids json> [extra json]: one issue of the fake tracker
  jq -nc --arg id "$1" --arg st "$2" --argjson l "$3" --argjson x "${4:-{\}}" \
    '{id: ("I" + ($id | sub("^[A-Za-z]+-"; ""))), identifier: $id, team: {id: "T1"}, state: {id: "S9", name: $st}, labelIds: $l, comments: [], title: ("title of " + $id), priority: 3} + $x'
}

commands_dispatcher() { # fleet help, the eleven, 4.x names, internal commands, unknown names
  cmd_state disp
  local cmds out rc bad c n w routes
  cmds="$("$FL" help | sed -n '3,$p' | cut -d'`' -f2)"
  eq "commands: help lists exactly the eleven" "$(printf '%s\n' "$cmds" | paste -sd' ' -)" "$ELEVEN"
  gold help "$("$FL" help)"
  check "commands: help <command> prints that script's header" diff <("$FL" help status) <(sed -n '2,/^set -euo/p' "$SCRIPTS/status.sh" | sed '$d' | sed 's/^# \{0,1\}//')
  check "commands: the README's Commands table is fleet help's output" diff <("$FL" help) <(awk '/^\| Command \| What it does \| Example \|$/ { on = 1 } on && !/^\|/ { exit } on' "$SCRIPTS/../README.md")
  routes="$(awk '/^## Step 0/ { on = 1; next } on && /^## / { exit } on' "$SCRIPTS/../SKILL.md" | grep -o '`/fleet [a-z][a-z-]*' | sed 's#`/fleet ##' | sort -u)"
  eq "commands: every SKILL.md Step 0 route is one of the eleven" "$(for r in $routes; do printf ' %s ' "$ELEVEN" | grep -q " $r " || echo "$r"; done | paste -sd' ' -)" ""
  bad=""
  for c in unpark:"park <team> --undo" unhold:"hold <PR> --off" holder:"claim <ISSUE> --who" takeover:"claim <ISSUE> --take" escalations:"decide" \
    resolve:"decide <team> <id> --answer" watch:"run watch" schedule:"run schedule" prime:"status" config:"run show" focus:"park <team>"; do
    n="${c%%:*}"; w="${c#*:}"; out="$("$FL" "$n" x 2>&1)"; rc=$?
    [ "$rc" = 2 ] && printf '%s' "$out" | grep -qF "Run fleet $w" || bad="$bad $n"
  done
  eq "commands: each renamed 4.x command exits 2 and names its 5.0 command" "$bad" ""
  bad=""; for n in branches debrief metrics slim; do out="$("$FL" "$n" 2>&1)"; rc=$?; [ "$rc" = 2 ] && printf '%s' "$out" | grep -q "is gone in 5.0: " || bad="$bad $n"; done
  eq "commands: each removed 4.x command exits 2 and says what replaced it" "$bad" ""
  eq "commands: an internal command still runs, unlisted, and its help still prints" \
    "$("$FL" overlap nope >/dev/null 2>&1; [ $? != 2 ] && echo ran):$("$FL" help env | grep -c 'test environment')" "ran:1"
  "$FL" bogus >"$T/cmd-u.out" 2>"$T/cmd-u.err"; rc=$?
  eq "commands: an unknown command exits 2, nothing on stdout, the list on stderr" "$rc:$(wc -c <"$T/cmd-u.out" | tr -d ' '):$(grep -c '^| `status` |' "$T/cmd-u.err")" "2:0:1"
  "$FL" ../registry list >/dev/null 2>&1; rc=$?; "$FL" common >/dev/null 2>&1
  eq "commands: a path and a library script are never run" "$rc:$?" "2:2"
  ln -sf "$FL" "$T/cmd-fleet-link"; eq "commands: a symlink to fleet finds its scripts" "$("$T/cmd-fleet-link" help | sed -n 3p | cut -d'`' -f2)" boot
  eq "commands: fleet status prints what status.sh prints, arguments passed through" \
    "$("$FL" status --json | jq -c '[.[].name] | sort')" "$("$SCRIPTS/status.sh" --json | jq -c '[.[].name] | sort')"
}

commands_decide() { # decide: the recommended option taken, the list, the owner's answer
  cmd_state decide; export FLEET_NOW=2026-10-29T10:00:00Z
  cmd_linear
  "$REG" add '{"name":"dc-a/lead","team":"dc-a","tier":"Lead","status":"Working","herdr_ref":"dc-a-lead","pane":"p1","issue":"DEV-1"}' >/dev/null; echo working >"$AS/dc-a-lead"
  "$REG" escalate dc-a/lead P1 "which database?" "use postgres" sqlite >/dev/null 2>&1
  local id out
  id="$("$REG" escalations --open | jq -r '[.[] | select(.parked != true)][0].id')"
  gold decide "$("$SCRIPTS/decide.sh" dc-a "$id" 2>&1)"
  eq "commands: decide resolves it and tells the lead" "$("$REG" escalations --open | jq length):$(grep -c 'use postgres' "$HERDR_LOG")" "0:1"
  "$REG" escalate dc-a/lead P2 "rename the flag?" yes no >/dev/null 2>&1
  id="$("$REG" escalations --open | jq -r '.[0].id')"
  eq "commands: decide with no arguments lists the open question" "$("$FL" decide | grep -c "^| $id | P2 | dc-a/lead | rename the flag? |")" 1
  : >"$HERDR_LOG"; out="$("$FL" decide dc-a "$id" --answer "keep it" 2>&1)"
  gold decide-answer "$(printf '%s\n' "$out" | sed "s#$id#<id>#")"
  eq "commands: decide --answer tells the lead, then closes it" "$(grep -c 'The owner answered your question' "$HERDR_LOG"):$("$REG" escalations --open | jq length)" "1:0"
  "$FL" decide dc-a "$id" --answer again >/dev/null 2>&1
  eq "commands: an answer to a closed question is refused" "$?" 1
  cmd_nolinear; unset FLEET_NOW
}

commands_run() { # run show and run watch
  cmd_state run
  local C="$FLEET_CONFIG_DIR/config.toml"
  printf '# my notes\nlabel_prefix = "fleet:"\n' >"$C"
  printf '3\nanything\ncritical-path\nwhole-first\nask\n10\n15\n10\n08:00\nnever\n' >"$T/cmd-run-answers"
  FLEET_RUN_ANSWERS="$T/cmd-run-answers" "$SCRIPTS/run.sh" init >/dev/null 2>&1
  gold run "$("$FL" run show)"
  gold watch "$("$FL" run watch | sed "s#$FLEET_STATE_DIR#<state>#")"
  gcfg
}

commands_candidates() { # candidates: only bootable work, the rest with a reason
  cmd_state cands; export FLEET_NOW=2026-10-29T10:00:00Z
  "$REG" add '{"name":"cd-a/lead","team":"cd-a","tier":"Lead","status":"Working","herdr_ref":"cd-a-lead","pane":"p1","issue":"DEV-1"}' >/dev/null
  cmd_linear "[$(cmd_issue DEV-10 Todo '["R1"]' '{"priority":2}'),$(cmd_issue DEV-11 Verify '["R1"]'),$(cmd_issue DEV-12 Duplicate '["R1"]'),$(cmd_issue DEV-13 Todo '[]'),
    $(cmd_issue ACME-5 Todo '["R1"]'),$(cmd_issue DEV-14 'In Progress' '["R1","L2"]'),$(cmd_issue DEV-15 Todo '["R1"]' '{"blocked_by":["DEV-16"]}'),
    $(cmd_issue DEV-16 Backlog '["R1"]'),$(cmd_issue DEV-17 'In Progress' '["R1"]'),$(cmd_issue DEV-18 Todo '["R1"]' '{"duplicate_of":["DEV-10"]}')]"
  gold candidates "$("$FL" candidates 2>&1)"
  cmd_nolinear; unset FLEET_NOW
}

commands_hold() { # hold and hold --off
  qfresh cmdhold; qpr app-api 9 fleet/dev-9-c main 2026-10-20T10:00:00Z '["c.go"]' x; qteam h3 app-api 9 DEV-9 aaaaaaa9
  gold hold "$("$FL" hold https://github.com/acme/app-api/pull/9 --note "wait for the release" 2>&1)"
  gold unhold "$("$FL" hold '#9' --off 2>&1)"
  eq "commands: hold --off clears the hold" "$(jq -r 'length' "$FLEET_STATE_DIR/holds.json")" 0
}

commands_queue() { # the merge queue: the contract, base-branch and migration rules and a not-ready PR together
  qfresh cmdrich
  qpr app-api 10 fleet/dev-10-a main 2026-10-20T10:00:00Z '["a.go","db/migrations/0038_x.sql"]' x; qpr app-api 11 fleet/dev-11-b fleet/dev-10-a 2026-10-19T10:00:00Z '["b.go"]' x
  qpr app-api 12 fleet/dev-12-c main 2026-10-18T10:00:00Z '["c.go","db/migrations/0038_y.sql"]' x; qpr app-web 5 fleet/dev-5-w main 2026-10-21T10:00:00Z '["w.ts"]' 'Depends on https://github.com/acme/app-api/pull/12'
  qpr app-api 13 fleet/dev-13-d main 2026-10-17T10:00:00Z '["a.go"]' x
  qteam r10 app-api 10 DEV-10 aaaaaaa10 >/dev/null; qteam r11 app-api 11 DEV-11 aaaaaaa11 >/dev/null; qteam r12 app-api 12 DEV-12 aaaaaaa12 >/dev/null
  qteam r5 app-web 5 DEV-5 aaaaaaa5 >/dev/null; qteam r13 app-api 13 DEV-13 >/dev/null
  cmd_linear_ids DEV-10 DEV-11 DEV-12 DEV-5 DEV-13
  gold merge-queue "$(bash -c '. "$1/common.sh"; render_queue "$2"' _ "$SCRIPTS" "$(q)")"
  cmd_nolinear
}

commands_morning() { # the morning report
  qfresh cmdmorning; mkdir -p "$QD/ocwd"
  "$REG" add "$(jq -cn --arg c "$QD/ocwd" '{name: "orchestrator", team: "orchestrator", tier: "Orchestrator", status: "Working", herdr_ref: "om", pane: "pom", cwd: $c}')" >/dev/null
  local t
  for t in mo1 mo2; do "$REG" add "$(jq -cn --arg t "$t" '{name: ($t + "/lead"), team: $t, tier: "Lead", status: "Working", herdr_ref: ($t + "-l"), pane: ("p" + $t)}')" >/dev/null; done
  "$REG" add '{"name":"mo1/builder","team":"mo1","tier":"Worker","status":"Done","herdr_ref":"mo1-b","pane":"pmb","summary":"export shipped; UNVERIFIED: the cluster smoke run"}' >/dev/null
  "$REG" note mo1/lead decision "chose postgres over sqlite" >/dev/null; "$REG" note mo1/lead picked "Todo by priority; DEV-81 first" >/dev/null
  qpr app-api 85 fleet/dev-85 main 2026-10-23T20:00:00Z '["a.go"]' x CONFLICTING; qteam mo3 app-api 85 DEV-85 aaaaaaa85 >/dev/null
  { printf '{"at":"2026-10-22T09:00:00Z","type":"boot","team":"old","issue":"DEV-80"}\n'
    printf '{"at":"2026-10-24T01:00:00Z","type":"boot","team":"mo1","issue":"DEV-81","detail":"template build"}\n'
    printf '{"at":"2026-10-24T02:00:00Z","type":"boot","team":"mo2","issue":"DEV-82","detail":"template build"}\n'
    printf '{"at":"2026-10-24T03:00:00Z","type":"claim_takeover","team":"","name":"","issue":"DEV-83","detail":"holder fleet:other"}\n'
    printf '{"at":"2026-10-24T04:00:00Z","type":"claim_released","team":"","name":"","issue":"DEV-84","detail":"holder fleet:pr: its heartbeat is old"}\n'
    printf '{"at":"2026-10-24T05:00:00Z","type":"pr_conflicting","team":"mo3","name":"mo3/lead","pr":"https://github.com/acme/app-api/pull/86","detail":"after https://github.com/acme/app-api/pull/50"}\n'
  } >"$FLEET_STATE_DIR/events.jsonl"
  cmd_linear_ids DEV-1 DEV-2 DEV-3 DEV-4 DEV-5
  gold morning-report "$(TZ=UTC FLEET_NOW=2026-10-24T09:00:00Z FLEET_GH="$QD/gh-shim" "$SCRIPTS/metrics.sh" --morning 2>/dev/null)"
  cmd_nolinear
}

commands_claims() { # claim, claim --who, claim --take: their reply lines
  cmd_state claims
  printf 'BBBBBBBB-1111-4222-8333-444455556666\n' >"$FLEET_STATE_DIR/machine-id"
  export LINEAR_STUB_KEY=KEYFIXTURE-cmdc LINEAR_DB="$FLEET_STATE_DIR/linear.json" LINEAR_LOG="$FLEET_STATE_DIR/linear.log" LINEAR_ARGV_LOG="$FLEET_STATE_DIR/linear.argv" FLEET_CURL="$HERE/linear-stub.sh"
  printf '%s\n' "$LINEAR_STUB_KEY" >"$FLEET_CONFIG_DIR/linear_api""_key"; chmod 600 "$FLEET_CONFIG_DIR/linear_api""_key"
  cat >"$LINEAR_DB" <<'J'
{"team": "T1", "states": {"In Progress": "S1", "Done": "S2", "Todo": "S3"}, "next": 100,
 "labels": [{"id": "L1", "name": "fleet", "description": "", "parent": null},
            {"id": "L2", "name": "fleet:other", "description": "other host\nheartbeat=2026-10-18T06:00:00Z", "parent": {"id": "L1", "name": "fleet"}},
            {"id": "L3", "name": "bug", "description": "", "parent": null}],
 "issues": [{"id": "I1", "identifier": "DEV-1", "team": {"id": "T1"}, "state": {"id": "S3", "name": "Todo"}, "labelIds": ["L3"], "comments": []},
            {"id": "I2", "identifier": "DEV-2", "team": {"id": "T1"}, "state": {"id": "S1", "name": "In Progress"}, "labelIds": ["L2", "L3"], "comments": [], "branchName": "u/dev-2-x"}]}
J
  : >"$LINEAR_LOG"; : >"$LINEAR_ARGV_LOG"
  mkdir -p "$FLEET_STATE_DIR/gh"; printf '[]' >"$FLEET_STATE_DIR/gh-none.json"
  printf '#!/usr/bin/env bash\ncase "$1 $2" in "pr view") exit 1 ;; esac\ncat "%s"\n' "$FLEET_STATE_DIR/gh-none.json" >"$FLEET_STATE_DIR/gh-shim"; chmod +x "$FLEET_STATE_DIR/gh-shim"
  gcfg 'linear_writes = "on"'
  gold holder "$(FLEET_NOW=2026-10-18T09:00:00Z "$FL" claim DEV-2 --who 2>&1)"
  gold claim "$("$FL" claim DEV-1 2>&1)"
  gold takeover "$(FLEET_GH="$FLEET_STATE_DIR/gh-shim" FLEET_NOW=2026-10-18T09:00:00Z "$FL" claim DEV-2 --take 2>&1)"
  cmd_nolinear
}

commands_golden() { # every reply of the golden fixture: status, the team agents, disk, decide's list, the wakes and the team commands
  gfix; gcfg; export FLEET_NOW=2026-10-24T09:00:00Z DF_GB=500
  gold status "$("$FL" status 2>&1)"
  gold status-team "$("$FL" status build-api 2>&1)"
  gold disk "$(DF_GB=40 "$FL" status 2>&1 | grep '^Disk:')"
  gold escalations "$("$FL" decide 2>&1)"
  local w ev WAKES
  WAKES="$(bash -c '. "$1/common.sh"; printf "%s" "$WAKE_TYPES"' _ "$SCRIPTS")"
  for w in $WAKES; do
    case "$w" in
      pr_ready) ev='{"type":"pr_ready","team":"build-api","name":"build-api/tester","url":"https://github.com/acme/app-api/pull/214","sha":"abc1234def5678","ci":"green"}' ;;
      pr_merged) ev='{"type":"pr_merged","team":"build-web","name":"build-web/lead","url":"https://github.com/acme/app-web/pull/121"}' ;;
      pr_opened) ev='{"type":"pr_opened","team":"build-api","name":"build-api/builder","url":"https://github.com/acme/app-api/pull/214","lead_told":false}' ;;
      needs_input) ev='{"type":"needs_input","team":"build-api","name":"build-api/builder","detail":"login expired"}' ;;
      claim_takeover) ev='{"type":"claim_takeover","team":"build-api","name":"build-api/lead","issue":"DEV-12","holder":"fleet:other"}' ;;
      claim_lost) ev='{"type":"claim_lost","team":"build-api","name":"build-api/lead","issue":"DEV-12"}' ;;
      escalation) ev='{"type":"escalation","team":"build-api","name":"build-api/lead","id":"20261024T080000Z-1","severity":"P1","message":"which database?","options":["postgres","sqlite"]}' ;;
      pr_conflicting) ev='{"type":"pr_conflicting","team":"build-api","name":"build-api/lead","url":"https://github.com/acme/app-api/pull/214","merged":"https://github.com/acme/app-web/pull/121","lead_told":true}' ;;
      stale_version) ev='{"type":"stale_version","team":"build-api","name":"build-api/lead","from":"4.0.0","to":"4.1.0","detail":"runs 4.0.0, installed 4.1.0; waits for the go"}' ;;
      input_pending) ev='{"type":"input_pending","team":"build-api","name":"build-api/lead","detail":"yes go ahead and merge"}' ;;
      usage_limit) ev='{"type":"usage_limit","team":"","name":"","until":"2026-10-24T14:30:00Z","detail":"agents hit the plan usage limit"}' ;;
      status_changed) ev='{"type":"status_changed","team":"","name":"","ready":"2 ready: merge #214, then #121"}' ;;
      main_red) ev='{"type":"main_red","team":"","name":"acme/app","detail":"CI on main failed at abcdef1"}' ;;
      signoff_failed) ev='{"type":"signoff_failed","team":"build-api","name":"build-api/tester"}' ;;
      slot_free) ev='{"type":"slot_free","team":"","name":"","live":2,"target":3,"detail":"2 live < target 3"}' ;;
      morning_report) ev='{"type":"morning_report","team":"","name":"","date":"2026-10-24","path":"<T>/reports/fleet-morning-2026-10-24.md"}' ;;
      claim_released) ev='{"type":"claim_released","team":"","name":"","issue":"DEV-2","holder":"fleet:other"}' ;;
      claim_held_pr) ev='{"type":"claim_held_pr","team":"","name":"","issue":"DEV-6","holder":"fleet:other","url":"https://github.com/acme/app-api/pull/9"}' ;;
      claim_lapsed) ev='{"type":"claim_lapsed","team":"","name":"","issue":"DEV-4","holder":"fleet:other","detail":"no heartbeat, so it is not proven lapsed"}' ;;
      comment_pending) ev='{"type":"comment_pending","name":"build-api","issue":"DEV-12","url":"https://github.com/acme/app-api/pull/214","state":"retired","detail":"Owner: please rename the flag"}' ;;
      parked_reminder) ev='{"type":"parked_reminder","team":"build-api","name":"build-api/lead","id":"20261024T080000Z-1","severity":"P1","message":"merge the PR now?","options":["wait for CI"]}' ;;
      lead_waiting) ev='{"type":"lead_waiting","team":"build-api","name":"build-api/lead"}' ;;
      tick_failing) ev='{"type":"tick_failing","team":"","name":"disk","since":"2026-10-24T08:50:00Z","detail":"df: cannot read"}' ;;
      *) ev="$(jq -cn --arg t "$w" '{type: $t, team: "build-api", name: "build-api/builder"}')" ;;
    esac
    gold "wake-$w" "$(bash -c '. "$1/common.sh"; render_notice "$2"' _ "$SCRIPTS" "$ev")"
  done
  gold retire-ask "$("$FL" retire --summary build-web 2>&1)"
  mkdir -p "$G/la"; : >"$G/la/fleet.tick.plist"; printf '#!/bin/sh\n[ "$1" = print ]\n' >"$G/lctl"; chmod +x "$G/lctl"
  jq -n --argjson g "$(jq -rn '"2026-10-24T08:57:00Z" | fromdateiso8601')" '{last_good: $g}' >"$FLEET_STATE_DIR/loop.state.json"
  gold schedule "$(FLEET_LAUNCH_AGENTS="$G/la" FLEET_LAUNCHCTL="$G/lctl" "$FL" run schedule status 2>&1)"
  gold error "$("$FL" status build-nosuch 2>&1 >/dev/null)"
  gold tell "$("$FL" tell build-api/tester "hello there" 2>&1)"
  gold decision "$("$FL" escalate build-api/tester P2 "rename the flag?" 2>&1)"
  gold escalate "$("$FL" escalate build-api/builder P1 "which port?" 8080 9090 "decide later" 2>&1)"
  "$REG" resolve build-api/builder "$("$REG" escalations --open --team build-api | jq -r '[.[] | select(.message == "which port?")][0].id')" --note "use 8080" >/dev/null 2>&1
  gold boot "$(FLEET_FORCE=1 "$FL" boot --issue DEV-50 --issue-url https://linear.app/acme/issue/DEV-50/gold --issue-title "Web: the gold standard" build gold "$G/repo" "gold task" 2>/dev/null | sed -E 's/ at [0-9a-f]{7,}\./ at <sha>./')"
  gold park "$("$FL" park build-gold 2>&1)"
  gold unpark "$(FLEET_FORCE=1 "$FL" park build-old --undo 2>&1)"
  gold retire "$("$FL" retire build-gold --outcome Abandoned 2>&1)"
  printf '#!/usr/bin/env bash\necho "fleet: warning: herdr agent list failed; no classification or respawn this tick" >&2\necho "[]"\n' >"$G/fake-tick"
  printf '#!/bin/sh\necho "$1" >>"%s"\n' "$G/alert.log" >"$G/alert-cmd"; chmod +x "$G/fake-tick" "$G/alert-cmd"
  gcfg "alert_cmd = \"$G/alert-cmd\""; FLEET_TICK="$G/fake-tick" /bin/bash "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1; gcfg
  gold alert "$(cat "$G/alert.log" 2>/dev/null)"
  unset FLEET_NOW DF_GB
  # every command of help and every wake has its entry in output.md and a golden file; every golden has an entry
  local miss="" c f b h
  for c in $("$FL" help | sed -n '3,$p' | cut -d'`' -f2); do
    grep -qx "### $c" "$OUT_MD" || miss="$miss $c:heading"; [ -f "$GD/$c.md" ] || miss="$miss $c:golden"
  done
  for w in $WAKES; do grep -qx "### wake $w" "$OUT_MD" || miss="$miss wake-$w:heading"; [ -f "$GD/wake-$w.md" ] || miss="$miss wake-$w:golden"; done # parked_reminder: output.md has no entry yet
  for c in symbols "team table" "merge queue" error decision disk alert; do grep -qx "### $c" "$OUT_MD" || miss="$miss $c:heading"; done
  eq "commands: every command and wake has an entry in output.md and a golden file" "$miss" ""
  eq "commands: every golden file has an entry in output.md" "$(for f in "$GD"/*.md; do b="$(basename "$f" .md)"; case "$b" in wake-*) h="### wake ${b#wake-}" ;; *) h="### ${b//-/ }" ;; esac
    grep -qx "$h" "$OUT_MD" || grep -qx "### $b" "$OUT_MD" || grep -qx "### ${b%%-*}" "$OUT_MD" || echo "$b"; done | paste -sd' ' -)" ""
  eq "commands: no golden has a table row next to a line that is neither a row nor blank" "$(for f in "$GD"/*.md; do awk -v f="$(basename "$f")" '
      { row[NR] = ($0 ~ /^\|/); blank[NR] = ($0 == "") }
      END { for (i = 1; i <= NR; i++) if (row[i] && ((i > 1 && !row[i - 1] && !blank[i - 1]) || (i < NR && !row[i + 1] && !blank[i + 1]))) { print f; exit } }' "$f"; done)" ""
}

commands_suite() {
  GD="$HERE/golden"
  commands_dispatcher
  commands_decide
  commands_run
  commands_candidates
  commands_hold
  commands_queue
  commands_morning
  commands_claims
  commands_golden
}
