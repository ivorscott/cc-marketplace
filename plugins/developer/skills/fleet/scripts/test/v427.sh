#!/usr/bin/env bash
# 4.2.7 cases (DEV-720): fewer redundant Orchestrator wakes and replies. Sourced by run.sh after v426.sh, which gives
# it v420_state, v420_linear, v420_tick, v420_evn and the helpers. A new file so the shared test files see few edits.
# No network: the tracker is linear-stub.sh, the forge a shim.
v427_issue() { # v427_issue <ID> <state> <label ids json> [extra json]: one issue of the fake tracker
  jq -nc --arg id "$1" --arg st "$2" --argjson l "$3" --argjson x "${4:-{\}}" \
    '{id: ("I" + ($id | sub("^[A-Za-z]+-"; ""))), identifier: $id, team: {id: "T1"}, state: {id: "S9", name: $st}, labelIds: $l, comments: [], title: ("title of " + $id), priority: 3} + $x'
}
v427_db() { # v427_db <extra issues json array>: the fake tracker with a role label, DEV-1 In Progress with a live claim
  v420_linear "$1"
  jq '.labels += [{id: "R1", name: "role:backend", description: "", parent: null}]' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
}
v427_cands() { "$SCRIPTS/linear.sh" candidates --detail 2>/dev/null; }
v427_dbedit() { jq "$@" "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"; }

v427_watch() { # fleet watch prints the one command; help lists it and candidates
  v420_state watch
  local out; out="$("$SCRIPTS/watch.sh")"
  eq "v427 watch: the first line is the tail command on wakes.log, the second a comment" \
    "$(printf '%s\n' "$out" | sed -n 1p):$(printf '%s\n' "$out" | wc -l | tr -d ' '):$(printf '%s\n' "$out" | sed -n 2p | cut -c1-1)" "tail -n 0 -F $FLEET_STATE_DIR/wakes.log:2:#"
  gold watch "$out"
  eq "v427 watch: fleet help lists watch and candidates" "$("$SCRIPTS/fleet" help | grep -c '^| `\(watch\|candidates\)` ')" 2
}

v427_candidates() { # only bootable work, the rest in skipped with a reason
  v420_state cands; export FLEET_NOW=2026-10-29T10:00:00Z
  "$REG" add '{"name":"cd-a/lead","team":"cd-a","tier":"Lead","status":"Working","herdr_ref":"cd-a-lead","pane":"p1","issue":"DEV-1"}' >/dev/null
  v427_db "[$(v427_issue DEV-10 Todo '["R1"]' '{"priority":2}'),$(v427_issue DEV-11 Verify '["R1"]'),$(v427_issue DEV-12 Duplicate '["R1"]'),$(v427_issue DEV-13 Todo '[]'),
    $(v427_issue ACME-5 Todo '["R1"]'),$(v427_issue DEV-14 'In Progress' '["R1","L2"]'),$(v427_issue DEV-15 Todo '["R1"]' '{"blocked_by":["DEV-16"]}'),
    $(v427_issue DEV-16 Backlog '["R1"]'),$(v427_issue DEV-17 'In Progress' '["R1"]'),$(v427_issue DEV-18 Todo '["R1"]' '{"duplicate_of":["DEV-10"]}')]"
  eq "v427 candidates: bootable are only the ready ones (Todo and Backlog, a lapsed or unlabelled In Progress)" \
    "$(v427_cands | jq -r '[.bootable[] | .id + ":" + .reason] | sort | join(",")')" "DEV-10:ready,DEV-16:ready,DEV-17:in-progress-lapsed"
  eq "v427 candidates: Verify, Duplicate, no role, other team, live claim, blocked are skipped with a reason" \
    "$(v427_cands | jq -r '[.skipped[] | .id + ":" + .reason] | sort | join(",")')" "ACME-5:other-team,DEV-11:verify,DEV-12:duplicate,DEV-13:no-role,DEV-14:claimed,DEV-15:blocked,DEV-18:duplicate,DEV-1:no-role"
  eq "v427 candidates: the plain form is the same bootable set as ids" "$("$SCRIPTS/linear.sh" candidates | jq -r 'sort | join(",")')" "DEV-10,DEV-16,DEV-17"
  gcfg 'linear_writes = "on"' 'tracker_teams = ["ACME"]'
  eq "v427 candidates: an explicit tracker_teams wins over the registry" "$(v427_cands | jq -r '[.bootable[].id] | join(",")')" "ACME-5"
  gcfg 'linear_writes = "on"' 'candidates_allow_unlabelled = true'
  eq "v427 candidates: candidates_allow_unlabelled admits the issue without a role label" "$(v427_cands | jq -r '[.bootable[] | select(.id == "DEV-13") | .id] | join(",")')" "DEV-13"
  gcfg 'linear_writes = "on"'
  local out; out="$("$SCRIPTS/candidates.sh" 2>&1)"
  eq "v427 candidates: the command prints the bootable lines by priority, then the skipped line" \
    "$(printf '%s\n' "$out" | head -n 3 | tr '\n' '|')" "- DEV-10 · P2 · title of DEV-10 · ready|- DEV-16 · P3 · title of DEV-16 · ready|- DEV-17 · P3 · title of DEV-17 · in-progress-lapsed|"
  eq "v427 candidates: and says why each other issue was left out" "$(printf '%s\n' "$out" | tail -n 1)" \
    "skipped: DEV-1 no-role, ACME-5 other-team, DEV-11 verify, DEV-12 duplicate, DEV-13 no-role, DEV-14 claimed, DEV-15 blocked, DEV-18 duplicate"
  gold candidates "$out"
  "$REG" add '{"name":"cd-b/lead","team":"cd-b","tier":"Lead","status":"Working","herdr_ref":"cd-b-lead","pane":"p2","issue":"DEV-10"}' >/dev/null
  eq "v427 candidates: an issue a registry row holds is skipped as held" "$("$SCRIPTS/candidates.sh" 2>&1 | tail -n 1 | grep -c 'DEV-10 held')" 1
  v420_nolinear; unset FLEET_NOW
}

v427_slot_free() { # one slot_free per set of bootable work
  v420_state slotfree; export DF_GB=100
  "$REG" add '{"name":"orchestrator","team":"orchestrator","tier":"Orchestrator","status":"Working","herdr_ref":"o9","pane":"po9"}' >/dev/null
  "$REG" add '{"name":"sf-a/lead","team":"sf-a","tier":"Lead","status":"Working","herdr_ref":"sf-a-lead","pane":"p1","issue":"DEV-1"}' >/dev/null; echo working >"$AS/sf-a-lead"
  "$REG" set orchestrator target_teams=3 >/dev/null
  v427_db "[$(v427_issue DEV-10 Todo '["R1"]'),$(v427_issue DEV-19 Verify '["R1"]'),$(v427_issue DEV-13 Todo '[]')]"
  local ev
  ev="$(v420_tick 2026-10-29T10:00:00Z)"; eq "v427 slot_free: the first bootable set announces once" "$(v420_evn "$ev" slot_free)" 1
  ev="$(v420_tick 2026-10-29T10:11:00Z)"; eq "v427 slot_free: an unchanged set is silent" "$(v420_evn "$ev" slot_free)" 0
  v427_dbedit --argjson i "$(v427_issue DEV-11 Todo '["R1"]')" '.issues += [$i]'
  ev="$(v420_tick 2026-10-29T10:22:00Z)"; eq "v427 slot_free: a new candidate announces again" "$(v420_evn "$ev" slot_free)" 1
  v427_dbedit --argjson i "$(v427_issue DEV-12 Todo '["R1"]' '{"blocked_by":["DEV-10"]}')" '.issues += [$i]'
  "$REG" add '{"name":"sf-h/lead","team":"sf-h","tier":"Lead","status":"Working","herdr_ref":"sf-h-lead","pane":"p3","issue":"DEV-11"}' >/dev/null; echo working >"$AS/sf-h-lead"
  ev="$(v420_tick 2026-10-29T10:33:00Z)"; eq "v427 slot_free: a blocked issue, a held one and a Verify one do not announce" "$(v420_evn "$ev" slot_free)" 0
  v427_dbedit '.issues |= map(select(.identifier != "DEV-10"))'
  ev="$(v420_tick 2026-10-29T10:44:00Z)"; eq "v427 slot_free: a shrunk set does not announce" "$(v420_evn "$ev" slot_free)" 0
  v427_dbedit '.issues |= map(select(.identifier != "DEV-12"))'
  ev="$(v420_tick 2026-10-29T10:55:00Z)"
  eq "v427 slot_free: with no bootable work left there is none, and the record is cleared" "$(v420_evn "$ev" slot_free):$(jq -r 'has("slot_free_set")' "$FLEET_STATE_DIR/tick.state.json")" "0:false"
  v420_nolinear; unset DF_GB
}

v427_notices() { # a repeated Slot free prints once
  v420_state notices
  v427_n() { bash -c ". '$SCRIPTS/common.sh'; notice_add \"\$1\" '{\"type\":\"slot_free\"}'" _ "$1"; }
  v427_n "Slot free (1 of 3 teams running). Pick the next issue and boot it."; v427_n "Slot free (1 of 3 teams running). Pick the next issue and boot it."
  v427_n "Slot free (2 of 4 teams running). Pick the next issue and boot it."
  eq "v427 notices: an older Slot free is dropped for the later one, printed once" "$(bash -c ". '$SCRIPTS/common.sh'; notices_show" | grep -c '^Slot free')" 1
  : >"$FLEET_STATE_DIR/notices.log"; rm -f "$FLEET_STATE_DIR/notices.log.shown"
  bash -c ". '$SCRIPTS/common.sh'; notice_add 'Ready to merge: 1 ready: merge #4.' '{}'; notice_add 'Ready to merge: 1 ready: merge #4.' '{}'"
  eq "v427 notices: and an identical text is printed once" "$(bash -c ". '$SCRIPTS/common.sh'; notices_show" | grep -c '^Ready to merge')" 1
}

v427_status() { # status_changed only for the owner
  v420_state status; export DF_GB=100 FLEET_GH="$QD/gh-shim"; rm -f "$AS"/*
  local ev
  "$REG" add '{"name":"so-a/lead","team":"so-a","tier":"Lead","status":"Working","herdr_ref":"so-a-lead","pane":"p1","issue":"DEV-1"}' >/dev/null; echo working >"$AS/so-a-lead"
  v420_tick 2026-10-29T10:00:00Z >/dev/null
  "$REG" set so-a/lead status=Idle >/dev/null; echo idle >"$AS/so-a-lead"
  ev="$(v420_tick 2026-10-29T10:30:00Z)"
  eq "v427 status: a Working to Idle flip wakes nobody and goes to the event log" "$(v420_evn "$ev" status_changed):$(grep -c '"type":"state_flip"' "$FLEET_STATE_DIR/events.jsonl")" "0:1"
  "$REG" escalate so-a/lead P2 "which name?" >/dev/null
  ev="$(v420_tick 2026-10-29T10:45:00Z)"; eq "v427 status: a new open escalation wakes once" "$(v420_evn "$ev" status_changed)" 1
  ev="$(v420_tick 2026-10-29T11:00:00Z)"; eq "v427 status: and not again" "$(v420_evn "$ev" status_changed)" 0
  "$REG" add '{"name":"so-f/lead","team":"so-f","tier":"Lead","status":"Failed","herdr_ref":"so-f-lead","pane":"p2","issue":"DEV-2"}' >/dev/null
  ev="$(v420_tick 2026-10-29T11:15:00Z)"; eq "v427 status: a Failed row wakes once" "$(v420_evn "$ev" status_changed)" 1
  qpr app-api 20 fleet/dev-20-a main 2026-10-29T08:00:00Z '["a.go"]' x; qteam so-r app-api 20 DEV-20 aaaaaaa20
  ev="$(v420_tick 2026-10-29T11:30:00Z)"; eq "v427 status: a new ready PR wakes once, with its push text" "$(v420_evn "$ev" status_changed):$(printf '%s' "$ev" | jq -r '[.[] | select(.type == "status_changed") | .ready] | first')" "1:1 ready: merge #20"
  unset DF_GB FLEET_GH
}

v427_idle_day() { # 24 hours idle with one parked PR: no wake but the morning report
  v420_state idleday; export DF_GB=100 FLEET_GH="$QD/gh-shim" TZ=UTC; rm -f "$AS"/*
  mkdir -p "$QD/idcwd"
  "$REG" add "$(jq -cn --arg c "$QD/idcwd" '{name: "orchestrator", team: "orchestrator", tier: "Orchestrator", status: "Working", herdr_ref: "om", pane: "pom", cwd: $c}')" >/dev/null
  qpr app-api 30 fleet/dev-30-a main 2026-10-29T08:00:00Z '["a.go"]' x
  qteam id-a app-api 30 DEV-30 aaaaaaa30
  "$REG" set orchestrator target_teams=2 >/dev/null
  v427_db "[$(v427_issue DEV-40 Todo '["R1"]')]"
  gcfg 'linear_writes = "on"' 'overnight = true'
  local h ev types=""
  v420_tick 2026-10-29T10:00:00Z >/dev/null # the first look announces what is new (the ready PR, the free slot, the day's report)
  for h in 11 12 14 17 20 23; do ev="$(v420_tick "2026-10-29T$h:00:00Z")"; types+="$(printf '%s' "$ev" | jq -r '[.[]? | .type] | join(",")'),"; done
  for h in 02 05 08 10; do ev="$(v420_tick "2026-10-30T$h:00:00Z")"; types+="$(printf '%s' "$ev" | jq -r '[.[]? | .type] | join(",")'),"; done
  eq "v427 idle day: after the first look, 24 hours with a ready PR and a free slot wake only for the next morning report" \
    "$(printf '%s' "$types" | tr ',' '\n' | grep -v '^$' | sort | uniq -c | tr -s ' ' | tr '\n' ';')" " 1 morning_report;"
  v420_nolinear; unset DF_GB FLEET_GH TZ
}

v427_report() { # morning: filed deferred items, hand-resolved parked escalations; defer for a retired team
  v420_state report; export FLEET_NOW=2026-10-29T10:00:00Z TZ=UTC
  "$REG" add '{"name":"dm-a/lead","team":"dm-a","tier":"Lead","status":"Working","herdr_ref":"dm-a-lead","pane":"p1","issue":"DEV-1"}' >/dev/null; echo working >"$AS/dm-a-lead"
  "$REG" note dm-a/lead deferred "fix the copy → not filed: no Linear key" >/dev/null
  "$REG" note dm-a/lead deferred "rename the export → not filed: no Linear key" >/dev/null
  "$REG" note dm-a/lead deferred "audit the logs → not filed: no Linear key" >/dev/null
  "$REG" note dm-a/lead deferred-filed "DEV-77 fix the copy" >/dev/null
  v427_eyes() { "$SCRIPTS/metrics.sh" --morning 2>/dev/null | awk '/^## Needs your eyes/ {on = 1; next} /^## / {on = 0} on'; }
  eq "v427 report: a deferred-filed note turns the item into one filed line" "$(v427_eyes | grep -c '^- filed: DEV-77$'):$(v427_eyes | grep -c 'fix the copy')" "1:0"
  eq "v427 report: items still not filed keep listing" "$(v427_eyes | grep -c 'deferred (dm-a/lead): rename the export → not filed')" 1
  v427_db "[$(v427_issue DEV-78 Todo '["R1"]' '{"description":"Follow-up: rename the export"}')]"
  eq "v427 report: with a Linear key an issue holding the item's text counts as filed" "$(v427_eyes | grep -c '^- filed: DEV-78$'):$(v427_eyes | grep -c 'rename the export')" "1:0"
  eq "v427 report: and the item nothing matches stays" "$(v427_eyes | grep -c 'audit the logs')" 1
  v420_nolinear
  "$REG" escalate dm-a/lead P1 "may I merge the PR to main myself?" yes no >/dev/null 2>&1
  local id; id="$("$REG" escalations --open | jq -r '.[0].id')"
  "$SCRIPTS/decide.sh" dm-a "$id" >/dev/null 2>&1
  eq "v427 report: decide records the escalation id on the parked note" "$("$REG" get dm-a/lead | jq -r '[.notes[] | select(.kind == "parked") | .message] | first | test("^\\[esc [^]]+\\] ")')" true
  "$REG" escalate dm-a/lead P1 "rotate the deploy key by hand?" yes no >/dev/null 2>&1
  id="$("$REG" escalations --open | jq -r '.[0].id')"
  "$REG" note dm-a/lead parked "[esc $id] rotate the deploy key by hand?" >/dev/null
  "$REG" resolve dm-a/lead "$id" --note "done by the owner" >/dev/null
  "$REG" note dm-a/lead parked "an old parked note" >/dev/null
  eq "v427 report: the parked line decide wrote stays, the hand-resolved one goes, the old one without an id stays" \
    "$(v427_eyes | grep -c 'parked for you (dm-a/lead): may I merge'):$(v427_eyes | grep -c 'rotate the deploy key'):$(v427_eyes | grep -c 'parked for you (dm-a/lead): an old parked note')" "1:0:1"
  # defer for a retired team: in the registry, then in the archive
  "$REG" add '{"name":"dr-a/lead","team":"dr-a","tier":"Lead","status":"Working","herdr_ref":"dr-a-lead","pane":"p9","issue":"DEV-1"}' >/dev/null
  v427_db '[]'
  "$REG" retire dr-a --outcome Shipped >/dev/null
  local o; o="$("$SCRIPTS/defer.sh" dr-a --item "polish the docs" 2>&1)"
  eq "v427 defer: a retired team files the item and notes it on its lead" "$(printf '%s' "$o" | grep -c '^Deferred NEW-'):$("$REG" get dr-a/lead | jq -r '[.notes[] | select(.kind == "deferred")] | length')" "1:1"
  jq -n --slurpfile r "$FLEET_REGISTRY" '{agents: {"dr-a/lead": $r[0].agents["dr-a/lead"]}}' >"$FLEET_STATE_DIR/fleet-archive.json"
  jq 'del(.agents["dr-a/lead"])' "$FLEET_REGISTRY" >"$FLEET_REGISTRY.t" && mv "$FLEET_REGISTRY.t" "$FLEET_REGISTRY"
  o="$("$SCRIPTS/defer.sh" dr-a --item "tidy the tests" 2>&1)"
  eq "v427 defer: and so does an archived one, the note landing in the archive" \
    "$(printf '%s' "$o" | grep -c '^Deferred NEW-'):$(jq -r '[.agents["dr-a/lead"].notes[] | select(.kind == "deferred")] | length' "$FLEET_STATE_DIR/fleet-archive.json")" "1:2"
  v420_nolinear; unset FLEET_NOW TZ
}

v427_smoke() { # the critical cases, CI (V427_ONLY="name name" runs just those, to debug one)
  local f
  for f in v427_watch v427_candidates v427_slot_free v427_notices v427_status v427_idle_day v427_report; do
    case " ${V427_ONLY:-$f} " in *" $f "*) "$f" ;; esac
  done
}
v427_full() { v427_smoke; }
