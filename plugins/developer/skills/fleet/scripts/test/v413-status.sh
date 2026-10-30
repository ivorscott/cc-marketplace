#!/usr/bin/env bash
# 4.1.3, bugs 6 and 1 (one status for every machine) and 7 (predicting and fixing cross-machine conflicts).
# Sourced by v413.sh, which gives it v413_state, v413_agent and run.sh's helpers.
v413_linear() { # a fake Linear with two other machines' labels: peera (a summary) and peerb (none, an older plugin)
  local kf="linear_api""_key" sm
  sm='[{"t":"build-p","i":"DEV-21","pr":"https://github.com/acme/app-api/pull/21","s":"Done","n":"merge the PR","r":true},{"t":"build-q","i":"DEV-22","s":"Working"}]'
  export LINEAR_STUB_KEY=KEYFIXTURE-v413 LINEAR_DB="$FLEET_STATE_DIR/linear.json" LINEAR_LOG="$FLEET_STATE_DIR/linear.log" FLEET_CURL="$HERE/linear-stub.sh"
  : >"$LINEAR_LOG"
  jq -n --arg sm "$sm" '{team: "T1", states: {}, next: 100, labels: [{id: "L0", name: "fleet", description: "", parent: null},
      {id: "L1", name: "fleet:peera", description: ("owner=Fixture\nheartbeat=2026-10-29T09:55:00Z\nsummary=" + $sm), parent: {id: "L0", name: "fleet"}},
      {id: "L2", name: "fleet:peerb", description: "heartbeat=2026-10-29T09:50:00Z", parent: {id: "L0", name: "fleet"}}],
    issues: [{id: "I21", identifier: "DEV-21", team: {id: "T1"}, state: {id: "S", name: "In Progress"}, labelIds: ["L1"], comments: []},
      {id: "I30", identifier: "DEV-30", team: {id: "T1"}, state: {id: "S", name: "In Progress"}, labelIds: ["L2"], comments: []}]}' >"$LINEAR_DB"
  printf 'KEYFIXTURE-v413\n' >"$FLEET_CONFIG_DIR/$kf"; chmod 600 "$FLEET_CONFIG_DIR/$kf"
}
v413_nolinear() { rm -f "$FLEET_CONFIG_DIR/linear_api""_key"; unset LINEAR_STUB_KEY LINEAR_DB LINEAR_LOG FLEET_CURL; }

v413_all_machines() {
  qfresh v413all; export FLEET_STATE_DIR="$QD/state.v413all" FLEET_REGISTRY="$QD/state.v413all/fleet.json" FLEET_INBOX="$QD/state.v413all/escalations.jsonl"
  export FLEET_NOW=2026-10-29T10:00:00Z FLEET_GH="$QD/gh-shim" DF_GB=100
  # a local PR #20 (ready), a peer's #21 (its summary says ready) and a local #23 that is not ready, touching #20's file
  qpr app-api 20 fleet/dev-1-a main 2026-10-29T08:00:00Z '["local.go"]' x
  qpr app-api 21 fleet/dev-21-b main 2026-10-29T07:00:00Z '["peer.go"]' y
  qpr app-api 23 fleet/dev-3-c main 2026-10-29T09:00:00Z '["local.go"]' z
  qteam v413-x app-api 20 DEV-1 aaaaaaa20; qteam v413-y app-api 23 DEV-3; v413_agent v413-live/lead Lead Idle
  v413_linear
  out="$("$SCRIPTS/status.sh" 2>"$T/v413.err")"; rc=$?
  eq "v413-6 status: the default shows the other machines in the one table, with a Machine column" \
    "$rc:$(printf '%s\n' "$out" | grep -c '^| Team | Machine | Issue | PR | State | Needs you |$'):$(printf '%s\n' "$out" | grep -c '^| build-p | peera ')" "0:1:1"
  eq "v413-6 status: a local row names this machine, a peer's team its own" \
    "$(printf '%s\n' "$out" | grep '^| v413-x ' | cut -d'|' -f3 | tr -d ' '):$(printf '%s\n' "$out" | grep '^| build-q ' | cut -d'|' -f3 | tr -d ' ')" "test:peera"
  eq "v413-6 status: a peer's cells come from its summary (state, needs you)" "$(printf '%s\n' "$out" | grep '^| build-p ' | cut -d'|' -f6,7 | tr -d ' ')" "Done|mergethePR"
  eq "v413-6 status: no heading per machine" "$(printf '%s\n' "$out" | grep -ci '^machine\|^peera\|on peera:')" 0
  eq "v413-6 status: a machine with no summary is one claim-only line" "$(printf '%s\n' "$out" | grep '^Other machines:')" \
    "Other machines: DEV-30 on peerb (claim only: no summary)."
  eq "v413 heartbeat: a fresh heartbeat produces no heartbeat text at all, in the table, the lines or the queue" "$(printf '%s\n' "$out" | grep -ci 'heartbeat\|ago')" 0
  eq "v413-6 status: the rows whose PR is in the queue come first, in its order" \
    "$(printf '%s\n' "$out" | grep '^| \(build-p\|v413-x\|v413-y\|build-q\) ' | cut -d'|' -f2 | tr -d ' ' | paste -sd, -)" "build-p,v413-x,build-q,v413-y"
  eq "v413-6 queue: a local and a peer ready PR are in one numbered list, each with its machine" \
    "$(printf '%s\n' "$out" | grep '^| [12] | ' | cut -d'|' -f2,3,5 | sed 's#https://github.com/acme/##; s/ //g' | paste -sd, -)" "1|app-api/pull/21|peera,2|app-api/pull/20|test"
  eq "v413-7 queue: a ready PR says which not-ready PR touches the same files" "$(printf '%s\n' "$out" | grep -c 'touches the same files as app-api #23 (not ready yet)')" 1
  eq "v413-6 status: nothing was written for the other machines (no mutation, the registry rows unchanged)" \
    "$(grep -c '^mutation' "$LINEAR_LOG"):$("$REG" list | jq -r '[.[].team] | unique | join(",")')" "0:v413-live,v413-x,v413-y"
  # the peer's summary when it is older than lease_hours: in the table with its age, and its PR is never ready
  jq '.labels[1].description |= sub("09:55:00"; "03:55:00")' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"; rm -f "$FLEET_STATE_DIR/queue.json"
  out="$("$SCRIPTS/status.sh" 2>/dev/null)"
  eq "v413-6 status: a summary older than lease_hours stays in the table with its age, and its PR is not ready" \
    "$(printf '%s\n' "$out" | grep '^| build-p ' | cut -d'|' -f6 | tr -d ' '):$(printf '%s\n' "$out" | grep -c '^| [12] | .*pull/21')" "Done:0"
  eq "v413 heartbeat: and a plain line says its heartbeat lapsed, with no age" "$(printf '%s\n' "$out" | grep -i 'heartbeat')" "peera: heartbeat lapsed."
  eq "v413-6 queue: and it is listed as not ready, with the peer's state" "$(printf '%s\n' "$out" | grep -c 'Not ready: https://github.com/acme/app-api/pull/21 ✗ other machine (Done)')" 1
  # --json
  eq "v413-6 status --json: this machine only, the shape unchanged" "$("$SCRIPTS/status.sh" --json 2>/dev/null | jq -c '[.[] | .source // "none"] | unique')" '["none"]'
  eq "v413-6 status --json --all: the other machines' rows carry machine and source" \
    "$("$SCRIPTS/status.sh" --json --all 2>/dev/null | jq -c '[.[] | [.source, .machine]] | unique')" '[["registry","test"],["tracker","peera"],["tracker","peerb"]]'
  eq "v413-6 status: --all is accepted and prints the table it prints without it" "$("$SCRIPTS/status.sh" --all 2>/dev/null)" "$("$SCRIPTS/status.sh" 2>/dev/null)"
  out="$(FLEET_STATUS_LOCAL=1 "$SCRIPTS/status.sh" 2>/dev/null)"
  eq "v413-6 status: FLEET_STATUS_LOCAL=1 shows this machine's teams only, and no Other machines line" \
    "$(printf '%s\n' "$out" | grep -c '^| build-p '):$(printf '%s\n' "$out" | grep -c '^Other machines')" "0:0"
  v413_nolinear
  out="$("$SCRIPTS/status.sh" 2>/dev/null)"
  eq "v413-6 status: with no Linear key one line says the others are unknown, and this machine's rows print" \
    "$(printf '%s\n' "$out" | grep -c '^Other machines: unknown (no Linear key).$'):$(printf '%s\n' "$out" | grep -c '^| v413-x ')" "1:1"
  unset FLEET_NOW FLEET_GH
}

v413_summary_publish() {
  qfresh v413sum; export FLEET_STATE_DIR="$QD/state.v413sum" FLEET_REGISTRY="$QD/state.v413sum/fleet.json" FLEET_INBOX="$QD/state.v413sum/escalations.jsonl"
  v413_agent build-s/lead Lead Working; v413_agent build-s/builder Worker Done "pr=https://github.com/acme/app-api/pull/40"
  s="$(bash -c '. "$1/common.sh"; fleet_summary' _ "$SCRIPTS")"
  eq "v413-1 summary: one entry per team, compact, with its issue, PR and state" "$(printf '%s' "$s" | jq -c '.[0] | {t, i, pr, s}')" \
    '{"t":"build-s","i":"DEV-1","pr":"https://github.com/acme/app-api/pull/40","s":"Working"}'
  # many teams: at most 12 entries, and under the size cap
  for n in $(seq 1 20); do v413_agent "build-m$n/lead" Lead Working "pr=https://github.com/acme/app-api/pull/$((100 + n))"; done
  s="$(bash -c '. "$1/common.sh"; fleet_summary' _ "$SCRIPTS")"
  eq "v413-1 summary: capped to 12 teams and 1500 characters" "$(printf '%s' "$s" | jq 'length <= 12'):$([ ${#s} -le 1500 ] && echo fits)" "true:fits"
  v413_linear
  jq '.labels += [{id: "L9", name: "fleet:test", description: "owner=Fixture", parent: {id: "L0", name: "fleet"}}]
      | .issues += [{id: "I1", identifier: "DEV-1", team: {id: "T1"}, state: {id: "S", name: "In Progress"}, labelIds: ["L9"], comments: []}]' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  gcfg 'linear_writes = "on"'; : >"$LINEAR_LOG"; FLEET_NOW=2026-10-29T10:00:00Z "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1; rc=$?
  eq "v413-1 heartbeat: the summary rides on the one label update" "$rc:$(grep -c '^mutation IssueLabelUpdate' "$LINEAR_LOG")" "0:1"
  desc="$(jq -r '.labels[] | select(.name == "fleet:test") | .description' "$LINEAR_DB")"
  eq "v413-1 heartbeat: the description holds heartbeat= and a summary= line next to it, once" \
    "$(printf '%s\n' "$desc" | grep -c '^heartbeat=2026-10-29T10:00:00Z$'):$(printf '%s\n' "$desc" | grep -c '^summary=\[')" "1:1"
  eq "v413-1 peers: the summary line comes back parsed, null for a label without one" \
    "$("$SCRIPTS/linear.sh" peers | jq -c 'map({machine, n: (.summary | if . == null then null else length end)}) | sort_by(.machine)')" \
    '[{"machine":"peera","n":2},{"machine":"peerb","n":null}]'
  FLEET_NOW=2026-10-29T10:00:00Z "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1
  eq "v413-1 heartbeat: a second heartbeat replaces both lines, never adds one" \
    "$(jq -r '.labels[] | select(.name == "fleet:test") | .description' "$LINEAR_DB" | grep -c "^summary=\|^heartbeat=")" "2"
  # DEV-636: 21 teams' summary must not push the description over the limit, and a refused write still lands the heartbeat
  FLEET_NOW=2026-10-29T10:01:00Z LINEAR_STUB_DESC_MAX=255 "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>"$T/hb636.err"; rc=$?
  desc="$(jq -r '.labels[] | select(.name == "fleet:test") | .description' "$LINEAR_DB")"
  eq "v636 heartbeat: with 21 teams the description fits 255 characters, the heartbeat lands and the summary is a whole JSON array"     "$rc:$([ ${#desc} -le 255 ] && echo fits):$(printf '%s\n' "$desc" | grep -c '^heartbeat=2026-10-29T10:01:00Z$'):$(printf '%s\n' "$desc" | sed -n 's/^summary=//p' | jq -e 'type == "array" and length > 0' >/dev/null && echo array)" "0:fits:1:array"
  FLEET_NOW=2026-10-29T10:02:00Z LINEAR_STUB_DESC_MAX=60 "$SCRIPTS/linear.sh" heartbeat >"$T/hb636.out" 2>"$T/hb636.err"; rc=$?
  desc="$(jq -r '.labels[] | select(.name == "fleet:test") | .description' "$LINEAR_DB")"
  eq "v636 heartbeat: a description Linear refuses is retried without the summary, with a warning on stderr and the usual stdout" \
    "$rc:$(printf '%s\n' "$desc" | grep -c '^heartbeat=2026-10-29T10:02:00Z$'):$(printf '%s\n' "$desc" | grep -c '^summary='):$(grep -c 'without the team summary' "$T/hb636.err"):$(jq -c .heartbeat "$T/hb636.out")" "0:1:0:1:true"
  FLEET_NOW=2026-10-29T10:03:00Z LINEAR_STUB_DESC_MAX=5 "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>"$T/hb636.err"; rc=$?
  eq "v636 heartbeat: a write refused even without the summary says 'heartbeat not written' and exits 1" \
    "$rc:$(grep -c 'heartbeat not written' "$T/hb636.err")" "1:1"
  gcfg; v413_nolinear
}

v413_conflict_catchup() {
  qfresh v413cc; export FLEET_STATE_DIR="$QD/state.v413cc" FLEET_REGISTRY="$QD/state.v413cc/fleet.json" FLEET_INBOX="$QD/state.v413cc/escalations.jsonl" FLEET_WORKTREES="$QD/state.v413cc/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; rm -f "$AS"/*; git init -q -b main "$QD/repo-cc" 2>/dev/null
  local t r n
  for t in tc td; do for r in lead builder tester; do
    "$REG" add "$(jq -cn --arg t "$t" --arg r "$r" --arg repo "$QD/repo-cc" '{name: ($t + "/" + $r), team: $t, tier: (if $r == "lead" then "Lead" else "Worker" end), template: "build",
      harness: "claude", status: "Done", herdr_ref: ($t + "-" + $r), pane: ("p" + $t + $r), workspace: "w", repo: $repo, cwd: $repo, assignment: "task", issue: ($t | ascii_upcase)}')" >/dev/null
    echo gone >"$AS/$t-$r"
  done; done
  n=60; for t in tc td; do
    "$REG" set "$t/builder" pr="https://github.com/acme/app-api/pull/$n" >/dev/null; "$REG" signoff "$t/tester" "https://github.com/acme/app-api/pull/$n" "aaaaaaa$n" >/dev/null
    qpr app-api "$n" "fleet/$t-x" main 2026-10-29T08:00:00Z '["a.go"]' x; n=$((n + 1))
  done
  tk() { PROMPT_SEQ=1 FLEET_FORCE=1 FLEET_NOW="$1" FLEET_GH="$QD/gh-shim" "$SCRIPTS/tick.sh" 2>>"${V413_ERR:-/dev/null}"; }
  evn() { printf '%s' "$1" | jq -s --arg t "$2" '[.[][]? | select(.type == $t)] | length'; }
  t1="$(tk 2026-10-29T10:00:00Z)"
  eq "v413-7 catchup: both PRs are ready" "$(evn "$t1" pr_ready)" 2
  # #60 merges (and #62, with other files, merged too); #61 conflicts
  jq '.state = "MERGED"' "$QGHD/app-api-60.json" >"$QD/m.json" && mv "$QD/m.json" "$QGHD/app-api-60.json"
  jq '.mergeable = "CONFLICTING"' "$QGHD/app-api-61.json" >"$QD/m.json" && mv "$QD/m.json" "$QGHD/app-api-61.json"
  jq -nc '[{number: 60, url: "https://github.com/acme/app-api/pull/60", mergedAt: "2026-10-29T10:02:00Z", files: [{path: "a.go"}]},
           {number: 62, url: "https://github.com/acme/app-api/pull/62", mergedAt: "2026-10-29T10:03:00Z", files: [{path: "other.go"}]},
           {number: 64, url: "https://github.com/acme/app-api/pull/64", mergedAt: "2026-10-29T10:04:00Z", files: [{path: "a.go"}]}]' >"$QGHD/merged-app-api.json"
  : >"$HERDR_LOG"; t2="$(tk 2026-10-29T10:05:00Z)"
  eq "v413-7 catchup: a Done team with exited agents is started again when its PR conflicts" \
    "$(evn "$t2" pr_conflicting):$("$REG" list --team td | jq -r '[.[].status] | map(select(. == "Done")) | length'):$(jq -s '[.[] | select(.type == "respawned" and .team == "td")] | length' "$FLEET_STATE_DIR/events.jsonl")" "1:0:3"
  b="$("$REG" get td/lead | jq -r .last_brief)"
  eq "v413-7 catchup: the lead's brief tells it to merge origin/main with a plain push, and that part has no rebase or force-push" \
    "$(sed -n '/What to do now/,/do not push a guess/p' "$b" | grep -c 'git merge origin/main'):$(sed -n '/What to do now/,/do not push a guess/p' "$b" | grep -ciE 'rebase|force|push -f')" "1:0"
  eq "v413-7 catchup: the cause is read from GitHub: every merged PR that shares files (64 was not merged by a fleet team), not the one that does not" \
    "$(printf '%s' "$t2" | jq -r '.[] | select(.type == "pr_conflicting") | .detail')" "after https://github.com/acme/app-api/pull/60, https://github.com/acme/app-api/pull/64"
  eq "v413-7 catchup: the notice says it" "$(printf '%s' "$t2" | jq -c '.[] | select(.type == "pr_conflicting")' | while IFS= read -r e; do bash -c '. "$1/common.sh"; render_notice "$2"' _ "$SCRIPTS" "$e"; done | grep -c 'conflicts after https://github.com/acme/app-api/pull/60, https://github.com/acme/app-api/pull/64 merged. Lead told to merge main into the PR')" 1
  eq "v413-7 catchup: told once per head" "$(evn "$(tk 2026-10-29T10:10:00Z)" pr_conflicting)" 0
  # the new head is pushed and signed off: ready again
  jq '.mergeable = "MERGEABLE" | .headRefOid = "bbbbbbb61"' "$QGHD/app-api-61.json" >"$QD/m.json" && mv "$QD/m.json" "$QGHD/app-api-61.json"
  "$REG" signoff td/tester https://github.com/acme/app-api/pull/61 bbbbbbb61 >/dev/null
  eq "v413-7 catchup: a sign-off at the new head makes the PR ready again" "$(evn "$(tk 2026-10-29T10:15:00Z)" pr_ready)" 1
  # a second and a third conflict: two catch-ups at most, then a P1 escalation
  for h in 2 3; do
    for r in lead builder tester; do "$REG" set "td/$r" status=Done >/dev/null; echo gone >"$AS/td-$r"; done
    jq --arg h "ccccccc$h" '.mergeable = "CONFLICTING" | .headRefOid = $h' "$QGHD/app-api-61.json" >"$QD/m.json" && mv "$QD/m.json" "$QGHD/app-api-61.json"
    "$REG" signoff td/tester https://github.com/acme/app-api/pull/61 "ccccccc$h" >/dev/null
    tk "2026-10-29T11:0$h:00Z" >/dev/null
  done
  eq "v413-7 catchup: at most 2 catch-ups per PR, then a P1 escalation instead of another round" \
    "$(jq -s '[.[] | select(.type == "catchup")] | length' "$FLEET_STATE_DIR/events.jsonl"):$("$REG" escalations --open --team td | jq -r '[.[] | select(.severity == "P1")] | length')" "2:1"
  eq "v413-7 catchup: no script or brief text tells an agent to rebase or force-push" \
    "$(grep -ciE -- '--force|push -f|rebase' "$SCRIPTS/catchup.sh")" 0
  unset -f tk evn
}

v413_same_repo() {
  qfresh v413sr; export FLEET_STATE_DIR="$QD/state.v413sr" FLEET_REGISTRY="$QD/state.v413sr/fleet.json" FLEET_INBOX="$QD/state.v413sr/escalations.jsonl"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; export FLEET_GH="$QD/gh-shim"
  local ci='.github/workflows/ci.yml'
  # two repos, one workflow path and one migration number each: neither is a conflict with the other
  qpr app-api 30 fleet/dev-30-a main 2026-10-29T08:00:00Z "[\"$ci\",\"db/migrations/0040_a.sql\"]" x
  qpr app-web 31 fleet/dev-31-b main 2026-10-29T09:00:00Z "[\"$ci\",\"db/migrations/0040_b.sql\"]" y
  qteam sr1 app-api 30 DEV-30 aaaaaaa30; qteam sr2 app-web 31 DEV-31 aaaaaaa31
  eq "v413-7 queue: the same path in two repos is not an overlap: no rebase, no note, no migration clash" \
    "$(q | jq -r '[.ready[] | .after + "|" + .why] | join(";")')" "—|oldest first;—|oldest first"
  # the same two files in one repo: the later one is marked
  qfresh v413sr2; export FLEET_STATE_DIR="$QD/state.v413sr2" FLEET_REGISTRY="$QD/state.v413sr2/fleet.json"; mkdir -p "$FLEET_STATE_DIR"
  qpr app-api 30 fleet/dev-30-a main 2026-10-29T08:00:00Z "[\"$ci\"]" x
  qpr app-api 32 fleet/dev-32-c main 2026-10-29T09:00:00Z "[\"$ci\"]" y
  qteam sr1 app-api 30 DEV-30 aaaaaaa30; qteam sr3 app-api 32 DEV-32 aaaaaaa32
  eq "v413-7 queue: in one repo the later PR is marked rebase after the first" \
    "$(q | jq -r '[.ready[] | (.url | sub(".*/pull/"; "#")) + " " + .after] | join(";")')" "#30 —;#32 rebase after #30"
  unset FLEET_GH
}

v413_summary_escape() {
  qfresh v413esc; export FLEET_STATE_DIR="$QD/state.v413esc" FLEET_REGISTRY="$QD/state.v413esc/fleet.json" FLEET_INBOX="$QD/state.v413esc/escalations.jsonl"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; export FLEET_NOW=2026-10-29T10:00:00Z
  v413_agent build-e/lead Lead Working
  "$REG" escalate build-e/lead P1 'say "no" to C:\temp\new and a\\b' a b >/dev/null 2>&1
  v413_linear
  jq '.labels += [{id: "L9", name: "fleet:test", description: "owner=Fixture", parent: {id: "L0", name: "fleet"}}]
      | .issues += [{id: "I1", identifier: "DEV-1", team: {id: "T1"}, state: {id: "S", name: "In Progress"}, labelIds: ["L9"], comments: []}]' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  gcfg 'linear_writes = "on"'; "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1
  local want got
  want="$(bash -c '. "$1/common.sh"; fleet_summary' _ "$SCRIPTS" | jq -c .)"
  got="$(FLEET_MACHINE=other "$SCRIPTS/linear.sh" peers | jq -c '[.[] | select(.machine == "test")] | first | .summary')"
  eq "v413-1 summary: an escalation text with a quote and a backslash survives the label, and peers reads it back exactly" \
    "$([ "$got" != null ] && [ "$got" = "$want" ] && echo same):$(printf '%s' "$want" | jq -r '.[0].n' | grep -cF 'say "no" to C:\temp\new and a\\b')" "same:1"
  : >"$LINEAR_LOG"; "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1
  eq "v413-1 heartbeat: a second heartbeat with nothing changed makes no mutation" "$(grep -c '^mutation' "$LINEAR_LOG")" 0
  gcfg; v413_nolinear; unset FLEET_NOW
}

# DEV-648: six live teams and a claimed= line leave ~90 characters; the summary must still be written and read back.
v648_summary_fits() {
  qfresh v648; export FLEET_STATE_DIR="$QD/state.v648" FLEET_REGISTRY="$QD/state.v648/fleet.json" FLEET_INBOX="$QD/state.v648/escalations.jsonl"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; export FLEET_NOW=2026-10-30T10:00:00Z
  local n desc sm
  for n in 1 2 3 4 5 6; do
    v413_agent "build-fit-$n/lead" Lead Working "pr=https://github.com/acme/app-api/pull/$((200 + n))" "issue=DEV-$((640 + n))"
  done
  v413_linear
  jq '.labels += [{id: "L9", name: "fleet:test", description: "owner=Fixture\nclaimed=DEV-641@2026-10-30T09:00:00Z", parent: {id: "L0", name: "fleet"}}]
      | .issues += [{id: "I1", identifier: "DEV-641", team: {id: "T1"}, state: {id: "S", name: "In Progress"}, labelIds: ["L9"], comments: []}]' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  gcfg 'linear_writes = "on"'
  LINEAR_STUB_DESC_MAX=255 "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>"$T/hb648.err"; local rc=$?
  desc="$(jq -r '.labels[] | select(.name == "fleet:test") | .description' "$LINEAR_DB")"
  sm="$(printf '%s\n' "$desc" | sed -n 's/^summary=//p')"
  eq "v648 heartbeat: 6 teams and a claimed= line: the description is at most 255, with heartbeat, claim and a summary of all 6 teams" \
    "$rc:$([ ${#desc} -le 255 ] && echo fits):$(printf '%s\n' "$desc" | grep -c '^heartbeat=2026-10-30T10:00:00Z$'):$(printf '%s\n' "$desc" | grep -c '^claimed=DEV-641@'):$(printf '%s' "$sm" | jq -c 'if type == "array" then length else -1 end')" "0:fits:1:1:6"
  eq "v648 peers: the other machine reads the same summary back" \
    "$([ -n "$sm" ] && [ "$(FLEET_MACHINE=other "$SCRIPTS/linear.sh" peers | jq -c '[.[] | select(.machine == "test")] | first | .summary')" = "$(printf '%s' "$sm" | jq -c .)" ] && echo same)" "same"
  # teams exist but none fits: the heartbeat still lands, and a warning says why
  FLEET_NOW=2026-10-30T10:01:00Z FLEET_DESC_CAP=80 "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>"$T/hb648.err"; rc=$?
  desc="$(jq -r '.labels[] | select(.name == "fleet:test") | .description' "$LINEAR_DB")"
  eq "v648 heartbeat: teams with no summary that fits warn, and the heartbeat still lands" \
    "$rc:$(grep -c 'no team summary fits' "$T/hb648.err"):$(printf '%s\n' "$desc" | grep -c '^heartbeat=2026-10-30T10:01:00Z$'):$(printf '%s\n' "$desc" | grep -c '^summary=')" "0:1:1:0"
  # fleet_summary itself failing (no registry readable) never stops the heartbeat
  printf 'not json' >"$FLEET_STATE_DIR/bad.json"
  FLEET_NOW=2026-10-30T10:02:00Z FLEET_REGISTRY="$FLEET_STATE_DIR/bad.json" "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>"$T/hb648.err"; rc=$?
  desc="$(jq -r '.labels[] | select(.name == "fleet:test") | .description' "$LINEAR_DB")"
  eq "v648 heartbeat: a failing fleet_summary is a warning, and the heartbeat lands" \
    "$rc:$(printf '%s\n' "$desc" | grep -c '^heartbeat=2026-10-30T10:02:00Z$')" "0:1"
  gcfg; v413_nolinear; unset FLEET_NOW
}
