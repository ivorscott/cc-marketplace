#!/usr/bin/env bash
# 4.2.11: a new comment on an issue reaches its team whatever state the team is in, while its PR is open. Sourced by
# run.sh, after v413.sh and v420.sh, whose helpers it uses (v413_agent, v413_revive_team, v420_linear, v420_tick,
# v420_evn) with run.sh's own (ok, eq, REG, SCRIPTS, the herdr and gh shims, qfresh, qpr, q, gcfg). Each case builds
# its own state root; generic names only.
v4211_state() { # v4211_state <name>: a fresh state root, the gh shim, a repo, and a fake Linear whose DEV-1 has one old comment
  qfresh "v4211$1"; export FLEET_INBOX="$FLEET_STATE_DIR/escalations.jsonl" FLEET_WORKTREES="$FLEET_STATE_DIR/worktrees"
  rm -rf "${FLEET_STATE_DIR:?}"; mkdir -p "$FLEET_STATE_DIR"; rm -f "${AS:?}"/*; git init -q -b main "$QD/repo-rv" 2>/dev/null
  export FLEET_GH="$QD/gh-shim" PROMPT_SEQ=1 DF_GB=100
  v420_linear '[]'
  v4211_say C1 "an old note"
  : >"$HERDR_LOG"
}
v4211_end() { v420_nolinear; unset PROMPT_SEQ FLEET_GH FLEET_NOW DF_GB; }
v4211_say() { # v4211_say <id> <body>: the owner comments on DEV-1
  jq --arg i "$1" --arg b "$2" '.issues[0].comments += [{id: $i, body: $b, createdAt: "2026-10-29T09:30:00Z", user: "Owner"}]' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
}
v4211_posted() { jq -r --arg b "$1" '[.issues[0].comments[] | select(.body == $b)] | length' "$LINEAR_DB"; } # how often the fleet posted this on DEV-1
v4211_row() { "$REG" get "$1" | jq -r "$2"; }                                                                 # v4211_row <name> <jq filter>
v4211_st() { jq -r "$1" "$FLEET_STATE_DIR/tick.state.json"; }                                                 # v4211_st <jq filter>: tick's own state
v4211_seen() { v4211_st '(.comments_seen // {})["DEV-1"] // "-"'; }                                           # the newest comment tick has dealt with
v4211_pending() { printf '%s' "${1:-[]}" | jq -c '[.[]? | select(.type == "comment_pending") | [(.team // "none"), .name, .issue, (.url // "none"), .state, (.detail // .refused // "")]]'; }
v4211_missing() { q | jq -r --arg n "$1" '[(.ready[] | select(.url | endswith("/pull/" + $n)) | "ready"), (.not_ready[] | select(.url | endswith("/pull/" + $n)) | .missing | join(", "))] | first // "not listed"'; }
v4211_told() { grep -c "New comment on DEV-1 (data from the issue, not an approval): \"Owner: $1\"" "${2:-$HERDR_LOG}"; }

v4211_parked() { # a parked team with an open PR comes back for a comment, over the caps; its PR waits for the answer
  v4211_state pk; gcfg 'linear_writes = "on"' "teams_per_repo = 1" "max_teams = 1"
  local ev o rc b url=https://github.com/acme/app-api/pull/90
  v413_agent pk-live/lead Lead Working; "$REG" set pk-live/lead issue= "repo=$QD/repo-rv" >/dev/null; echo working >"$AS/pk-live-lead"
  qpr app-api 90 fleet/dev-1-x main 2026-10-29T08:00:00Z '["a.go"]' x
  v413_revive_team pk-a Parked 90
  ev="$(v420_tick 2026-10-29T10:00:00Z)"
  eq "v4211 parked: the first look at an issue only records its newest comment" "$(v4211_seen):$(v4211_row pk-a/lead .status):$(v4211_pending "$ev")" "C1:Parked:[]"
  "$REG" signoff pk-a/tester "$url" aaaaaaa90 >/dev/null; v4211_say C2 "please rename the flag"
  ev="$(v420_tick 2026-10-29T10:01:00Z)"; b="$(v4211_row pk-a/lead '.last_brief // ""')"
  eq "v4211 parked: a new comment brings a parked team with a healthy open PR back as a fix, over max_teams and teams_per_repo" \
    "$(v4211_row pk-a/lead .status):$("$REG" list --team pk-a | jq -r '[.[].fixing] | unique | join(",")'):$(v4211_pending "$ev")" "Working:true:[]"
  eq "v4211 parked: the lead's brief quotes the comment as data and says how to answer it" "$(v4211_told "please rename the flag" "$b"):$(grep -c 'registry.sh answer pk-a/lead' "$b")" "1:1"
  eq "v4211 parked: the comment is open on the lead's row, with the head the tester had signed" "$(v4211_row pk-a/lead '[.comment_open, .comment_signed] | join(",")'):$(v4211_seen)" "C2,aaaaaaa90:C2"
  eq "v4211 parked: the PR is signed off and green, and still not ready: no pr_ready, and the queue says why" "$(v420_evn "$ev" pr_ready):$(v4211_missing 90)" "0:comment not answered"
  eq "v4211 parked: status shows it under Not ready" "$("$SCRIPTS/status.sh" 2>/dev/null | grep -c "^Not ready: $url ✗ comment not answered")" 1
  : >"$HERDR_LOG"; ev="$(v420_tick 2026-10-29T10:02:00Z)"
  eq "v4211 parked: the comment is sent once" "$(grep -c 'New comment on DEV-1' "$HERDR_LOG"):$(v4211_seen):$(v4211_row pk-a/lead .comment_open)" "0:C2:C2"
  o="$(FLEET_ROLE=lead FLEET_NAME=pk-a/lead "$REG" answer pk-a/lead "the flag name   comes from the contract" 2>&1)"; rc=$?
  eq "v4211 parked: the lead answers that no change is needed" "$rc:$o" "0:Answered the comment open for pk-a/lead. The fleet posts it on the issue at its next tick."
  ev="$(v420_tick 2026-10-29T10:03:00Z)"
  eq "v4211 parked: the next tick posts the answer on the issue and the PR is ready" \
    "$(v4211_posted "[fleet] pk-a answered the comment above: the flag name comes from the contract"):$(v4211_row pk-a/lead '[.comment_open // "", .comment_answer // ""] | join(",")'):$(v420_evn "$ev" pr_ready):$(v4211_missing 90)" "1:,:1:ready"
  : >"$HERDR_LOG"; ev="$(v420_tick 2026-10-29T10:04:00Z)"
  eq "v4211 parked: the fleet's own answer is not a new comment" "$(grep -c 'New comment on DEV-1' "$HERDR_LOG"):$(v4211_row pk-a/lead '.comment_open // ""')" "0:"
  v4211_end
}

v4211_done() { # a done team comes back too; a newly signed head is the answer
  v4211_state dn
  local ev url=https://github.com/acme/app-api/pull/91
  qpr app-api 91 fleet/dev-1-x main 2026-10-29T08:00:00Z '["a.go"]' x
  v413_revive_team dn-a Done 91; "$REG" signoff dn-a/tester "$url" aaaaaaa91 >/dev/null
  ev="$(v420_tick 2026-10-29T10:00:00Z)"
  v4211_say C2 "the empty state needs a line of help"
  ev="$(v420_tick 2026-10-29T10:01:00Z)"
  eq "v4211 done: a done team with an open PR is brought back for a comment" \
    "$(v4211_row dn-a/lead .status):$(v4211_told "the empty state needs a line of help" "$(v4211_row dn-a/lead '.last_brief // ""')"):$(v4211_row dn-a/lead .comment_open):$(v4211_missing 91)" "Working:1:C2:comment not answered"
  jq '.headRefOid = "bbbbbbb91"' "$QGHD/app-api-91.json" >"$QD/h.json" && mv "$QD/h.json" "$QGHD/app-api-91.json"
  ev="$(v420_tick 2026-10-29T10:02:00Z)"
  eq "v4211 done: a new head alone does not answer it" "$(v4211_row dn-a/lead .comment_open)" "C2"
  "$REG" signoff dn-a/tester "$url" bbbbbbb91 >/dev/null
  ev="$(v420_tick 2026-10-29T10:03:00Z)"
  eq "v4211 done: the tester's sign-off of a new head answers it, and the fleet says so on the issue" \
    "$(v4211_posted "[fleet] dn-a: the tester signed a new head off after the comment above, bbbbbbb."):$(v4211_row dn-a/lead '.comment_open // ""'):$(v4211_missing 91)" "1::ready"
  v4211_end
}

v4211_nopr() { # a parked team with no PR is left alone, and gets the comment when it runs again
  v4211_state np
  local ev
  v413_agent np-a/lead Lead Working; echo working >"$AS/np-a-lead"
  ev="$(v420_tick 2026-10-29T10:00:00Z)"
  "$REG" set np-a/lead status=Parked >/dev/null; v4211_say C2 "one more thing"; : >"$HERDR_LOG"
  ev="$(v420_tick 2026-10-29T10:01:00Z)"
  eq "v4211 no PR: a parked team with no PR is not woken and the comment is kept" \
    "$(grep -c 'New comment on DEV-1' "$HERDR_LOG"):$(v4211_seen):$(v4211_row np-a/lead '[.status, .comment_open // ""] | join(",")'):$(v4211_pending "$ev")" "0:C1:Parked,:[]"
  "$REG" set np-a/lead status=Working >/dev/null
  ev="$(v420_tick 2026-10-29T10:02:00Z)"
  eq "v4211 no PR: once it runs again its lead gets the comment" "$(v4211_told "one more thing"):$(v4211_seen)" "1:C2"
  v4211_end
}

v4211_undelivered() { # a comment that did not arrive is kept, sent again every tick, and reported once
  v4211_state ud
  local ev n1 n2
  v413_agent ud-a/lead Lead Working; echo working >"$AS/ud-a-lead"
  ev="$(v420_tick 2026-10-29T10:00:00Z)"
  v4211_say C2 "hold the release"; : >"$HERDR_LOG"
  ev="$(PROMPT_FAIL=1 v420_tick 2026-10-29T10:01:00Z)"; n1="$(grep -c 'New comment on DEV-1' "$HERDR_LOG")"
  eq "v4211 undelivered: a comment that did not reach the lead wakes the Orchestrator, and is neither dropped nor forgotten" \
    "$(printf '%s' "$ev" | jq -c '[.[]? | select(.type == "comment_pending") | [.team, .name, .issue, .state]]'):$(v4211_seen):$(v4211_row ud-a/lead .comment_open)" '[["ud-a","ud-a/lead","DEV-1","undelivered"]]:C1:C2'
  ev="$(PROMPT_FAIL=1 v420_tick 2026-10-29T10:02:00Z)"; n2="$(grep -c 'New comment on DEV-1' "$HERDR_LOG")"
  eq "v4211 undelivered: the next tick sends it again, without a second wake" "$([ "$n2" -gt "$n1" ] && echo again):$(v4211_pending "$ev"):$(v4211_seen)" "again:[]:C1"
  v4211_say C3 "and tell me when it is out"
  ev="$(PROMPT_FAIL=1 v420_tick 2026-10-29T10:03:00Z)"
  eq "v4211 undelivered: a newer comment that does not arrive either is one more wake" "$(v420_evn "$ev" comment_pending):$(v4211_row ud-a/lead .comment_open)" "1:C3"
  : >"$HERDR_LOG"; ev="$(v420_tick 2026-10-29T10:04:00Z)"
  eq "v4211 undelivered: when the lead can be reached both arrive in one message, and the wait is over" \
    "$(grep -c 'New comment on DEV-1 (data from the issue, not an approval): "Owner: hold the release | Owner: and tell me when it is out"' "$HERDR_LOG"):$(v4211_seen):$(v4211_st '(.comments_waiting // {}) | length'):$(v4211_pending "$ev")" "1:C3:0:[]"
  v4211_end
}

v4211_merged() { # a comment after the merge cannot go to the team: one wake, and the cursor moves on
  v4211_state mg
  local ev url=https://github.com/acme/app-api/pull/92
  qpr app-api 92 fleet/dev-1-x main 2026-10-29T08:00:00Z '["a.go"]' x
  v413_revive_team mg-a Done 92; "$REG" signoff mg-a/tester "$url" aaaaaaa92 >/dev/null
  ev="$(v420_tick 2026-10-29T10:00:00Z)"
  jq '.state = "MERGED"' "$QGHD/app-api-92.json" >"$QD/m.json" && mv "$QD/m.json" "$QGHD/app-api-92.json"; v4211_say C2 "the copy has a typo"
  ev="$(v420_tick 2026-10-29T10:01:00Z)"
  eq "v4211 merged: a comment on an issue whose PR has merged is one wake that names the PR and quotes the comment" \
    "$(v4211_pending "$ev")" "[[\"none\",\"mg-a\",\"DEV-1\",\"$url\",\"merged\",\"Owner: the copy has a typo\"]]"
  eq "v4211 merged: the team is not started, nothing waits on its row, and the cursor moves on" \
    "$("$REG" list --team mg-a | jq -r '[.[].status] | index("Working") == null'):$(v4211_row mg-a/lead '.comment_open // ""'):$(v4211_seen)" "true::C2"
  ev="$(v420_tick 2026-10-29T10:02:00Z)"
  eq "v4211 merged: and it is said once" "$(v4211_pending "$ev")" "[]"
  v4211_end
}

v4211_retired() { # a retired team whose PR is still open: the Orchestrator is told, once per comment
  v4211_state rt
  local ev r url=https://github.com/acme/app-api/pull/93
  qpr app-api 93 fleet/dev-1-x main 2026-10-29T08:00:00Z '["a.go"]' x
  v413_revive_team rt-a Done 93
  for r in lead builder tester; do "$REG" set "rt-a/$r" status=Retired >/dev/null; done
  ev="$(v420_tick 2026-10-29T10:00:00Z)"
  eq "v4211 retired: the first look only records the newest comment" "$(v4211_seen):$(v4211_pending "$ev")" "C1:[]"
  v4211_say C2 "please also cover the empty list"; v4211_say C3 "[fleet] a note of the fleet's own"
  ev="$(v420_tick 2026-10-29T10:01:00Z)"
  eq "v4211 retired: a comment while the PR of a retired team is open is one wake with no team to act on" \
    "$(v4211_pending "$ev")" "[[\"none\",\"rt-a\",\"DEV-1\",\"$url\",\"retired\",\"Owner: please also cover the empty list\"]]"
  eq "v4211 retired: status shows the notice (a notice with no team is not dropped as handled)" "$("$SCRIPTS/status.sh" 2>/dev/null | grep -c '^Comment waiting DEV-1: a new comment while .* is open and its team rt-a is retired')" 1
  ev="$(v420_tick 2026-10-29T10:02:00Z)"
  eq "v4211 retired: once" "$(v4211_pending "$ev"):$(v4211_seen)" "[]:C3"
  jq '.state = "MERGED"' "$QGHD/app-api-93.json" >"$QD/m.json" && mv "$QD/m.json" "$QGHD/app-api-93.json"; v4211_say C4 "thanks"
  ev="$(v420_tick 2026-10-29T10:03:00Z)"
  eq "v4211 retired: after the merge nothing is read or said, and the PR is remembered as closed" \
    "$(v4211_pending "$ev"):$(v4211_seen):$(v4211_st '.retired_pr_closed // [] | tojson')" "[]:C3:[\"$url\"]"
  # a live team that holds the issue again gets the comment itself
  v413_agent rt-b/lead Lead Working; echo working >"$AS/rt-b-lead"; : >"$HERDR_LOG"
  ev="$(v420_tick 2026-10-29T10:04:00Z)"
  eq "v4211 retired: a live team on the same issue gets the comment itself" "$(v4211_told "thanks"):$(v4211_pending "$ev")" "1:[]"
  v4211_end
}

v4211_own_lines() { # the fleet's own comments open nothing; registry.sh answer refuses what it cannot record
  v4211_state ol
  local ev o rc
  v413_agent ol-a/lead Lead Working; echo working >"$AS/ol-a-lead"; v413_agent ol-a/builder Worker Idle
  ev="$(v420_tick 2026-10-29T10:00:00Z)"
  v4211_say C2 "[fleet] decision recorded"; v4211_say C2b "PR opened: https://github.com/acme/app-api/pull/9

## In plain English
- **Problem:** the summary the lead copies from its PR body"; v4211_say C3 "fleet: taken over from other-mac"; : >"$HERDR_LOG"
  ev="$(v420_tick 2026-10-29T10:01:00Z)"
  eq "v4211 own lines: a machine's takeover line is told and asks for no answer; a [fleet] comment and the lead's own In plain English summary are not told at all" \
    "$(v4211_told "fleet: taken over from other-mac"):$(grep -c 'decision recorded' "$HERDR_LOG"):$(grep -c 'the summary the lead copies' "$HERDR_LOG"):$(v4211_row ol-a/lead '.comment_open // ""'):$(v4211_seen)" "1:0:0::C3"
  o="$("$REG" answer ol-a/lead "nothing to say" 2>&1)"; rc=$?
  eq "v4211 answer: with no comment open there is nothing to answer" "$([ "$rc" != 0 ] && echo refused):$(printf '%s' "$o" | grep -c 'no comment is open for ol-a/lead')" "refused:1"
  v4211_say C4 "why two flags?"
  ev="$(v420_tick 2026-10-29T10:02:00Z)"
  o="$(FLEET_ROLE=builder FLEET_NAME=ol-a/builder "$REG" answer ol-a "because" 2>&1)"; rc=$?
  eq "v4211 answer: only the lead answers a comment on its issue" "$([ "$rc" != 0 ] && echo refused):$(printf '%s' "$o" | grep -c 'ol-a/lead is not you (ol-a/builder)'):$(v4211_row ol-a/lead '.comment_answer // ""')" "refused:1:"
  o="$("$REG" answer ol-a "one flag per surface" 2>&1)"; rc=$?
  eq "v4211 answer: a bare team name is its lead (the Orchestrator may answer for it)" "$rc:$(v4211_row ol-a/lead .comment_answer)" "0:one flag per surface"
  v4211_say C5 "and the docs?"
  ev="$(v420_tick 2026-10-29T10:03:00Z)"
  eq "v4211 answer: the answer is posted, and a comment made since is open in its place" \
    "$(v4211_posted "[fleet] ol-a answered the comment above: one flag per surface"):$(v4211_row ol-a/lead '[.comment_open, .comment_answer // ""] | join(",")')" "1:C5,"
  v4211_end
}

v4211_render() { # the notices a wake carries, by what happened to the comment
  local r; r() { bash -c '. "$1/common.sh"; render_notice "$2"' _ "$SCRIPTS" "$1"; }
  eq "v4211 notice: a comment that did not arrive" "$(r '{"type":"comment_pending","team":"build-api","name":"build-api/lead","issue":"DEV-12","state":"undelivered","refused":"herdr refused the prompt"}')" \
    "Comment waiting DEV-12: a new comment did not reach build-api/lead (herdr refused the prompt). It is sent again every tick; look at build-api (fleet status)."
  eq "v4211 notice: a comment after the merge" "$(r '{"type":"comment_pending","name":"build-api","issue":"DEV-12","url":"https://github.com/acme/app-api/pull/214","state":"merged","detail":"Owner: one typo"}' | grep -c '^Comment waiting DEV-12: a new comment after .* of build-api merged or closed: "Owner: one typo". Boot a new team for it, or file a follow-up issue\.$')" 1
}

v4211_smoke() { # the critical cases, CI (V4211_ONLY="name name" runs just those, to debug one)
  local f
  for f in v4211_parked v4211_merged; do
    case " ${V4211_ONLY:-$f} " in *" $f "*) "$f" ;; esac
  done
}
v4211_full() {
  local f
  v4211_smoke
  for f in v4211_done v4211_undelivered v4211_retired v4211_own_lines v4211_nopr v4211_render; do
    case " ${V4211_ONLY:-$f} " in *" $f "*) "$f" ;; esac
  done
}
