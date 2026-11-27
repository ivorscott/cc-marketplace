#!/usr/bin/env bash
# 4.3.1 cases (DEV-1246): the other machine's ready PRs reach the merge queue and the Needs you column whatever the
# state of their team. Sourced by run.sh, which gives it ok/eq, the q* queue helpers and $REG.

v431_fq() { FLEET_GH="$QD/gh-shim" bash -c '. "$1/common.sh"; fleet_queue | jq -r "[.ready[].url | sub(\".*/pull/\"; \"#\")] | sort | join(\",\")"' _ "$SCRIPTS"; }

v431_peer_ready() { # a Parked and an Idle peer team, both r:true
  qfresh v431; export FLEET_NOW=2026-11-27T10:00:00Z
  qpr app 1 fleet/dev-9-mine main 2026-11-27T08:00:00Z '["a.go"]' "Fixes it"
  qteam v431-a app 1 DEV-9 aaaaaaa1
  jq -cn '[{"url":"https://github.com/acme/app/pull/38","number":38,"title":"t","headRefName":"fleet/dev-51-x","baseRefName":"main","mergeable":"MERGEABLE","isDraft":false,"body":"b","createdAt":"2026-11-27T08:10:00Z","headRefOid":"b38","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}],"files":[{"path":"b.go"}]},
    {"url":"https://github.com/acme/app/pull/39","number":39,"title":"t","headRefName":"fleet/dev-52-x","baseRefName":"main","mergeable":"MERGEABLE","isDraft":false,"body":"b","createdAt":"2026-11-27T08:20:00Z","headRefOid":"b39","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}],"files":[{"path":"c.go"}]}]' >"$QGHD/list-app.json"
  local peers q rows
  peers='[{"machine":"air","heartbeat":"2026-11-27T09:59:00Z","summary":[{"t":"car-51","i":"DEV-51","pr":"https://github.com/acme/app/pull/38","s":"Parked","r":true},{"t":"car-52","i":"DEV-52","pr":"https://github.com/acme/app/pull/39","s":"Idle","r":true}]}]'
  q="$(FLEET_PEERS_JSON="$peers" q)"
  eq "v431 queue: both ready peer PRs are listed, Parked or Idle" "$(jq -r '[.ready[] | .url | sub(".*/pull/"; "#")] | sort | join(",")' <<<"$q")" "#1,#38,#39"
  rows='[{"team":"car-51","machine":"air","issue":"DEV-51","pr":"https://github.com/acme/app/pull/38","state":"Parked","needs":"","ready":true},{"team":"car-52","machine":"air","issue":"DEV-52","pr":"https://github.com/acme/app/pull/39","state":"Idle","needs":"","ready":true}]'
  eq "v431 table: every ready peer row says merge the PR" \
    "$(bash -c '. "$1/common.sh"; render_table --queue "$2" --peers "$3"' _ "$SCRIPTS" "$q" "$rows" | grep -E '^\| car-5[12] ' | awk -F'|' '{gsub(/^ +| +$/, "", $2); gsub(/^ +| +$/, "", $7); print $2 ":" $7}' | paste -sd, -)" "car-51:merge the PR,car-52:merge the PR"
  # a queue kept a few seconds ago, before the peer's summary said ready, is not reused
  rm -f "$FLEET_STATE_DIR/queue.json"
  FLEET_PEERS_JSON="$(jq -c '.[0].summary |= map(.r = false)' <<<"$peers")" v431_fq >/dev/null
  eq "v431 cache: a kept queue is rebuilt when a peer's summary turns ready" "$(FLEET_PEERS_JSON="$peers" v431_fq)" "#1,#38,#39"
  unset FLEET_NOW
}

v431_smoke() { v431_peer_ready; }
v431_full() { v431_smoke; }
