#!/usr/bin/env bash
# 4.3.2 cases (DEV-1247): the summary a machine publishes carries each team's issue title and URL, so the other machine's
# rows (status table, merge queue) show the same Issue cell as local ones. Sourced by run.sh (ok/eq, q* helpers, $REG).

v432_summary() { # a team with a title and URL publishes short it/iu; one without publishes neither
  qfresh v432
  "$REG" add "$(jq -cn '{name: "car-1/builder", team: "car-1", tier: "Worker", status: "Working", herdr_ref: "c1", pane: "p", issue: "DEV-1",
    issue_title: "Web: A very long issue title that goes well past the forty character cut", issue_url: "https://linear.app/acme/issue/DEV-1/a-very-long-slug"}')" >/dev/null
  "$REG" add "$(jq -cn '{name: "car-2/builder", team: "car-2", tier: "Worker", status: "Working", herdr_ref: "c2", pane: "p", issue: "DEV-2"}')" >/dev/null
  local s; s="$(bash -c '. "$1/common.sh"; fleet_summary' _ "$SCRIPTS")"
  eq "v432 summary: a team with title and URL carries the short it and iu" \
    "$(jq -r '.[] | select(.t == "car-1") | "\(.it)|\(.iu)"' <<<"$s")" "A very long issue title that goes well|https://linear.app/acme/issue/DEV-1"
  eq "v432 summary: a team with neither carries no it or iu" "$(jq -r '.[] | select(.t == "car-2") | [has("it"), has("iu")] | join(",")' <<<"$s")" "false,false"
  eq "v432 label: a long title still fits the label cap as a valid array" \
    "$(jq -c . <<<"$s" | bash -c '. "$1/common.sh"; summary_for_label 255' _ "$SCRIPTS" | jq -e 'type == "array" and length > 0' >/dev/null && echo ok)" "ok"
  eq "v432 label: the label line is within the cap" "$(jq -c . <<<"$s" | bash -c '. "$1/common.sh"; summary_for_label 255' _ "$SCRIPTS" | awk '{print (length($0) <= 255) ? "ok" : "long"}')" "ok"
}

v432_table() { # a peer team renders the same Issue cell as a local one; an older summary renders the bare key
  local rows cell
  rows='[{"team":"p1","machine":"air","issue":"DEV-1","issue_url":"https://linear.app/acme/issue/DEV-1","issue_title":"Short title","pr":"","state":"Working","needs":""},{"team":"p2","machine":"air","issue":"DEV-2","pr":"","state":"Working","needs":""}]'
  cell() { bash -c '. "$1/common.sh"; render_table --peers "$2"' _ "$SCRIPTS" "$rows" | awk -F'|' -v t="$1" '$2 ~ "^ *"t" *$" {gsub(/^ +| +$/, "", $4); print $4}'; }
  eq "v432 table: a peer team with title and URL shows the linked key and title" "$(cell p1)" "[DEV-1](https://linear.app/acme/issue/DEV-1) Short title"
  eq "v432 table: a peer team from an older summary shows the bare key" "$(cell p2)" "DEV-2"
  eq "v432 table: the local cell for the same issue reads the same" \
    "$(bash -c '. "$1/common.sh"; issue_link "$2" "$3" "$4"' _ "$SCRIPTS" DEV-1 https://linear.app/acme/issue/DEV-1 "Short title")" "[DEV-1](https://linear.app/acme/issue/DEV-1) Short title"
}

v432_queue() { # a peer PR in the merge queue carries the peer's issue link and title
  qfresh v432q; export FLEET_NOW=2026-11-27T10:00:00Z
  jq -cn '[{"url":"https://github.com/acme/app/pull/38","number":38,"title":"t","headRefName":"fleet/dev-51-x","baseRefName":"main","mergeable":"MERGEABLE","isDraft":false,"body":"b","createdAt":"2026-11-27T08:10:00Z","headRefOid":"b38","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}],"files":[{"path":"b.go"}]}]' >"$QGHD/list-app.json"
  local peers='[{"machine":"air","heartbeat":"2026-11-27T09:59:00Z","summary":[{"t":"car-51","i":"DEV-51","it":"Peer title","iu":"https://linear.app/acme/issue/DEV-51","pr":"https://github.com/acme/app/pull/38","s":"Parked","r":true}]}]'
  eq "v432 queue: the peer PR entry shows the issue link and title" \
    "$(FLEET_PEERS_JSON="$peers" q | jq -r '[.ready[] | select(.url | endswith("/38")) | .issue] | first')" "[DEV-51](https://linear.app/acme/issue/DEV-51) Peer title"
  unset FLEET_NOW
}

v432_smoke() { v432_summary; v432_table; v432_queue; }
v432_full() { v432_smoke; }
