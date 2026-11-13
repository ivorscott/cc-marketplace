#!/usr/bin/env bash
# 4.2.10 cases (DEV-768: the per-machine team summary lives in a Linear document, not in the 255-character label description).
# Sourced by run.sh after v428.sh, which gives it v413_agent, v413_linear and the helpers. No network: the tracker is
# linear-stub.sh (documents in LINEAR_DB `.documents`), the forge a shim. Two machines are two state dirs and two machine keys
# (a1, b2) on one stub database.

v4210_db() { # v4210_db: a fake Linear with a label for each machine (a1 on DEV-1, b2 on DEV-2) and no documents
  local kf="linear_api""_key"
  export LINEAR_STUB_KEY=KEYFIXTURE-v4210 LINEAR_DB="$QD/linear.v4210.json" LINEAR_LOG="$QD/linear.v4210.log" FLEET_CURL="$HERE/linear-stub.sh"
  : >"$LINEAR_LOG"
  jq -n '{team: "T1", states: {}, next: 100, documents: [], labels: [{id: "L0", name: "fleet", description: "", parent: null},
      {id: "L1", name: "fleet:a1", description: "heartbeat=2026-10-29T09:50:00Z", parent: {id: "L0", name: "fleet"}},
      {id: "L2", name: "fleet:b2", description: "heartbeat=2026-10-29T09:50:00Z", parent: {id: "L0", name: "fleet"}}],
    issues: [{id: "I1", identifier: "DEV-1", team: {id: "T1"}, state: {id: "S", name: "In Progress"}, labelIds: ["L1"], comments: []},
      {id: "I2", identifier: "DEV-2", team: {id: "T1"}, state: {id: "S", name: "In Progress"}, labelIds: ["L2"], comments: []}]}' >"$LINEAR_DB"
  printf 'KEYFIXTURE-v4210\n' >"$FLEET_CONFIG_DIR/$kf"; chmod 600 "$FLEET_CONFIG_DIR/$kf"
  gcfg 'linear_writes = "on"' '[machine_names]' 'a1 = "Machine A"' 'b2 = "Machine B"'
}
v4210_machine() { # v4210_machine <key>: this shell is that machine, with its own state dir
  export FLEET_MACHINE="$1" FLEET_STATE_DIR="$QD/state.v4210.$1" FLEET_REGISTRY="$QD/state.v4210.$1/fleet.json" FLEET_INBOX="$QD/state.v4210.$1/escalations.jsonl"
  mkdir -p "$FLEET_STATE_DIR"
}
v4210_rows() { # v4210_rows <status output>: the table rows, sorted (header and separator left out)
  printf '%s\n' "$1" | grep '^| ' | grep -v '^| Team \|^| ---\|^| # ' | sort
}

v4210_sandbox() { # the issue's case: 12 teams on machine A, 3 on B; both machines show the same rows, names and merge queue
  local n out_a out_b q_a q_b
  qfresh v4210x; rm -f "$QD"/state.v4210.*/fleet.json
  export FLEET_NOW=2026-10-29T10:00:00Z FLEET_GH="$QD/gh-shim" DF_GB=100
  qpr app-api 21 fleet/dev-21-b main 2026-10-29T07:00:00Z '["b.go"]' y; qpr app-api 20 fleet/dev-20-a main 2026-10-29T06:00:00Z '["a.go"]' x
  v4210_db
  v4210_machine a1
  rm -f "$FLEET_REGISTRY"
  for n in $(seq 1 12); do v413_agent "ta$n/lead" Lead Working "issue=DEV-$((100 + n))"; done
  qteam ta1 app-api 20 DEV-101 aaaaaaa20
  jq -nc '{at: "2026-10-29T10:00:00Z", sig: "x", queue: {ready: [{url: "https://github.com/acme/app-api/pull/20"}]}}' >"$FLEET_STATE_DIR/queue.json"
  FLEET_DESC_CAP=255 "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>"$T/v4210.err"
  v4210_machine b2
  rm -f "$FLEET_REGISTRY"
  for n in 1 2 3; do v413_agent "tb$n/lead" Lead Working "issue=DEV-$((200 + n))"; done
  qteam tb1 app-api 21 DEV-201 aaaaaaa21
  jq -nc '{at: "2026-10-29T10:00:00Z", sig: "x", queue: {ready: [{url: "https://github.com/acme/app-api/pull/21"}]}}' >"$FLEET_STATE_DIR/queue.json"
  "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>>"$T/v4210.err"
  eq "v4210 sandbox: each machine wrote its own document (12 teams and 3 teams), A's past the 255-character label limit" \
    "$(jq -r '[.documents[] | [.title, (.content | length > 255 | tostring)]] | sort | map(join("=")) | join(",")' "$LINEAR_DB")" \
    "Fleet summary · a1=true,Fleet summary · b2=false"
  eq "v4210 sandbox: the 12 teams are all in machine A's document" \
    "$(jq -r '.documents[] | select(.title | endswith("a1")) | .content' "$LINEAR_DB" | grep -o '"i":"DEV-1[0-9][0-9]"' | wc -l | tr -d ' ')" 12
  eq "v4210 sandbox: the document names the machine" "$(jq -r '.documents[] | select(.title | endswith("a1")) | .content' "$LINEAR_DB" | sed -n 1p)" "name=a1"
  eq "v4210 sandbox: no label description passes 255 characters" "$(jq -r '[.labels[] | .description | length] | max <= 255' "$LINEAR_DB")" true

  v4210_machine a1; out_a="$("$SCRIPTS/status.sh" 2>>"$T/v4210.err")"
  v4210_machine b2; out_b="$("$SCRIPTS/status.sh" 2>>"$T/v4210.err")"
  eq "v4210 sandbox: 15 team rows on A and 15 on B" "$(v4210_rows "$out_a" | grep -c '^| t[ab]'):$(v4210_rows "$out_b" | grep -c '^| t[ab]')" "15:15"
  eq "v4210 sandbox: the same rows on A and on B (team, machine name, issue, PR)" \
    "$(v4210_rows "$out_a" | grep '^| t[ab]' | cut -d'|' -f2-5)" "$(v4210_rows "$out_b" | grep '^| t[ab]' | cut -d'|' -f2-5)"
  eq "v4210 sandbox: machine names come from config, never a number" \
    "$(v4210_rows "$out_a" | grep '^| t[ab]' | cut -d'|' -f3 | tr -d ' ' | sort | uniq -c | tr -s ' ' | paste -sd, -)" " 12 MachineA, 3 MachineB"
  eq "v4210 sandbox: no machine is cut to a bare count" "$(printf '%s\n%s\n' "$out_a" "$out_b" | grep -c "names didn't fit\|claim only")" 0
  q_a="$(v4210_rows "$out_a" | grep '^| [0-9]')"; q_b="$(v4210_rows "$out_b" | grep '^| [0-9]')"
  eq "v4210 sandbox: the merge queue lists B's ready PR the same on both machines" "$q_a" "$q_b"
  eq "v4210 sandbox: and both PRs are in it" "$(printf '%s\n' "$q_a" | grep -c 'pull/2[01]')" 2
  v4210_machine a1
  eq "v4210 peers: a document-backed peer says so" "$("$SCRIPTS/linear.sh" peers | jq -r '.[0] | "\(.source):\(.name):\(.summary | length)"')" "doc:b2:3"

  # an unchanged summary: no second document write, and no label write either
  : >"$LINEAR_LOG"
  v4210_machine b2; "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1 # status rewrote the queue file: this one settles the summary
  : >"$LINEAR_LOG"; "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1
  eq "v4210 unchanged: the second heartbeat (same summary) makes no document write" "$(grep -c '^mutation Document' "$LINEAR_LOG")" 0
  : >"$LINEAR_LOG"; FLEET_NOW=2026-10-29T10:05:00Z "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1
  eq "v4210 unchanged: a later heartbeat is one label update and no document write" "$(grep -c '^mutation IssueLabelUpdate' "$LINEAR_LOG"):$(grep -c '^mutation Document' "$LINEAR_LOG")" "1:0"
  "$REG" set tb2/lead pr=https://github.com/acme/app-api/pull/22 >/dev/null
  : >"$LINEAR_LOG"; FLEET_NOW=2026-10-29T10:06:00Z "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1
  eq "v4210 changed: a changed summary is one document update" "$(grep -c '^mutation DocumentUpdate' "$LINEAR_LOG"):$(grep -c '^mutation DocumentCreate' "$LINEAR_LOG")" "1:0"
  rm -f "$FLEET_STATE_DIR/summary.doc.sha"; : >"$LINEAR_LOG"; FLEET_NOW=2026-10-29T10:07:00Z "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1
  eq "v4210 unchanged: with the hash lost the document is read once and not rewritten" "$(grep -c '^query SummaryDocs' "$LINEAR_LOG"):$(grep -c '^mutation Document' "$LINEAR_LOG")" "1:0"

  # an older peer (a summary= line only) and one with neither
  v4210_machine a1
  jq '.documents |= map(select(.title | endswith("b2") | not)) | .labels |= map(if .name == "fleet:b2" then .description = "heartbeat=2026-10-29T09:55:00Z\nsummary=[{\"t\":\"old-team\",\"s\":\"Working\"}]" else . end)' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  out_a="$("$SCRIPTS/status.sh" 2>/dev/null)"
  eq "v4210 old peer: a machine with only a label summary= line still shows its rows" "$(printf '%s\n' "$out_a" | grep -c '^| old-team | Machine B ')" 1
  eq "v4210 old peer: its source is the label" "$("$SCRIPTS/linear.sh" peers | jq -r '.[0].source')" label
  jq '.labels |= map(if .name == "fleet:b2" then .description = "heartbeat=2026-10-29T09:55:00Z" else . end)' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  out_a="$("$SCRIPTS/status.sh" 2>/dev/null)"
  eq "v4210 old peer: a machine with neither is one claim-only line" "$(printf '%s\n' "$out_a" | grep -c 'DEV-2 on b2 (claim only: no summary)')" 1

  # the document store refuses: the heartbeat still lands, and a warning says so
  v4210_db; v4210_machine a1; rm -f "$FLEET_REGISTRY" "$FLEET_STATE_DIR/summary.doc.sha"
  v413_agent "tz/lead" Lead Working "issue=DEV-300"
  LINEAR_STUB_DOC_REFUSE=1 "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>"$T/v4210.err"; local rc=$?
  eq "v4210 refused: a refused document write is a warning, the heartbeat lands, the label keeps the thin summary" \
    "$rc:$(grep -c 'summary document not written' "$T/v4210.err"):$(jq -r '.labels[] | select(.name == "fleet:a1") | .description' "$LINEAR_DB" | grep -c -e '^heartbeat=2026-10-29T10:00:00Z$' -e '^summary=\['):$(jq '.documents | length' "$LINEAR_DB")" "0:1:2:0"

  # test mode: only this machine's own summary document is writable (the guard itself, taken out of linear.sh: it refuses before any call)
  eq "v4210 test mode: another machine's summary document is refused, this machine's own is cleared" \
    "$(bash -c 'die() { echo "refused"; exit 1; }; machine_key() { echo a1; }; machine_label() { echo fleet:a1; }
      DOC_PREFIX="Fleet summary · "; TEST_TEAM=T; OWN_LID=L1; ISSUES_OK=""
      eval "$(sed -n "/^clear_write() {/,/^}/p" "$1/linear.sh")"
      clear_write DocumentUpdate "Fleet summary · a1" && echo own-ok
      (clear_write DocumentUpdate "Fleet summary · b2"; echo not-reached)
      (clear_write DocumentCreate "Elsewhere"; echo not-reached)' _ "$SCRIPTS" 2>&1 | paste -sd, -)" "own-ok,refused,refused"
  gcfg 'linear_writes = "test:T"'; v4210_machine a1; rm -f "$FLEET_REGISTRY" "$FLEET_STATE_DIR/summary.doc.sha"; v413_agent "tz/lead" Lead Working "issue=DEV-300"
  jq '.issues[0].team = {id: "T1", key: "T"}' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1
  eq "v4210 test mode: a heartbeat writes only this machine's document" "$(jq -r '[.documents[].title] | join(",")' "$LINEAR_DB")" "Fleet summary · a1"
  v420_nolinear; unset FLEET_NOW FLEET_GH FLEET_MACHINE
}

v4210_team() { # with tracker_teams unset, the summary document is still created: under the registry's issue key, else any team
  qfresh v4210t; export FLEET_NOW=2026-10-29T10:00:00Z FLEET_GH="$QD/gh-shim" DF_GB=100
  v4210_db; v4210_machine a1; rm -f "$FLEET_REGISTRY" "$FLEET_STATE_DIR/summary.doc.sha"
  v413_agent "tk/lead" Lead Working "issue=DEV-400"
  : >"$LINEAR_LOG"; "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>"$T/v4210t.err"
  eq "v4210 team: no tracker_teams, the registry's issue key finds the team and the document is written" \
    "$(grep -c 'summary document not written' "$T/v4210t.err"):$(grep -cx 'query TeamId' "$LINEAR_LOG"):$(jq -r '[.documents[] | .title + "@" + .teamId] | join(",")' "$LINEAR_DB")" \
    "0:1:Fleet summary · a1@T1"
  v4210_db; v4210_machine a1; rm -f "$FLEET_REGISTRY" "$FLEET_STATE_DIR/fleet-archive.json" "$FLEET_STATE_DIR/summary.doc.sha"
  v413_agent "tn/lead" Lead Working "issue="
  : >"$LINEAR_LOG"; "$SCRIPTS/linear.sh" heartbeat >/dev/null 2>"$T/v4210t.err"
  eq "v4210 team: no tracker_teams and no issue on any row, the first team is used (no empty key filter)" \
    "$(grep -c 'summary document not written' "$T/v4210t.err"):$(grep -cx 'query TeamIdAny' "$LINEAR_LOG"):$(jq '.documents | length' "$LINEAR_DB")" "0:1:1"
  v420_nolinear; unset FLEET_NOW FLEET_GH FLEET_MACHINE DF_GB
}

v4210_smoke() { v4210_sandbox; v4210_team; }
v4210_full() { v4210_smoke; }
