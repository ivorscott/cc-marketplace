#!/usr/bin/env bash
# 4.2.x patch cases. Sourced by run.sh, which gives it the helpers (ok, eq, check, REG, SCRIPTS, the herdr shim, gcfg).
# v42x_smoke runs the critical subset (CI), v42x_full every case. Each case builds its own state root under
# $T/v42x-<name>; generic names only.
#
# 4.2.2 (DEV-649): another machine's tick must not release a lapsed claim whose open PR is in a repo this machine has
# no team in. The PR is found from the issue itself: its PR attachments, its fleet/<slug> branch, a search by owner.
v42x_state() { # v42x_state <name>: a fresh state root and config, a fake Linear and a fake gh
  export FLEET_STATE_DIR="$T/v42x-$1" FLEET_REGISTRY="$T/v42x-$1/fleet.json" FLEET_INBOX="$T/v42x-$1/escalations.jsonl" FLEET_WORKTREES="$T/v42x-$1/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; rm -f "$AS"/*
  local kf="linear_api""_key"
  export LINEAR_STUB_KEY=KEYFIXTURE-v42x LINEAR_DB="$FLEET_STATE_DIR/linear.json" LINEAR_LOG="$FLEET_STATE_DIR/linear.log" FLEET_CURL="$HERE/linear-stub.sh"
  export V42X_GH_LOG="$FLEET_STATE_DIR/gh.log" V42X_DIR="$FLEET_STATE_DIR/gh"; mkdir -p "$V42X_DIR"; : >"$V42X_GH_LOG" ; : >"$LINEAR_LOG"
  printf '[]' >"$V42X_DIR/none.json"
  cat >"$FLEET_STATE_DIR/gh-shim" <<'S'
#!/usr/bin/env bash
# pr view <url> → $V42X_DIR/view-<N>.json; search prs --head → head.json; search prs <KEY> → search.json; anything else []
echo "$*" >>"$V42X_GH_LOG"
[ -z "${V42X_GH_FAIL:-}" ] || exit 1
case "$1 $2" in
  "pr view") f="$V42X_DIR/view-${3##*/}.json"; [ -f "$f" ] || exit 1; cat "$f"; exit ;;
  "search prs") case " $* " in *" --head "*) f=head ;; *) f=search ;; esac; cat "$V42X_DIR/$f.json" 2>/dev/null || cat "$V42X_DIR/none.json"; exit ;;
esac
cat "$V42X_DIR/none.json"
S
  chmod +x "$FLEET_STATE_DIR/gh-shim"
  printf 'KEYFIXTURE-v42x\n' >"$FLEET_CONFIG_DIR/$kf"; chmod 600 "$FLEET_CONFIG_DIR/$kf"; gcfg 'linear_writes = "on"' "$@"
}
v42x_db() { # v42x_db <extra fields for DEV-7, a JSON object> [summary line]: DEV-7 held by fleet:other, heartbeat long past
  jq -n --argjson x "${1:-"{}"}" --arg sm "${2:-}" '{team: "T1", states: {"In Progress": "S1", Done: "S3", Todo: "S2"}, next: 100,
    labels: [{id: "L0", name: "fleet", description: "", parent: null},
      {id: "L2", name: "fleet:test", description: "heartbeat=2026-10-29T09:55:00Z", parent: {id: "L0", name: "fleet"}},
      {id: "L3", name: "fleet:other", description: ("other host\nheartbeat=2026-10-29T01:00:00Z" + (if $sm != "" then "\nsummary=" + $sm else "" end)), parent: {id: "L0", name: "fleet"}}],
    issues: [{id: "I7", identifier: "DEV-7", team: {id: "T1"}, state: {id: "S1", name: "In Progress"}, labelIds: ["L3"], comments: []} + $x]}' >"$LINEAR_DB"
}
v42x_tick() { # the tick's events on stdout; V42X_DEBUG=1 shows its stderr and the gh calls
  FLEET_GH="$FLEET_STATE_DIR/gh-shim" FLEET_NOW=2026-10-29T10:00:00Z "$SCRIPTS/tick.sh" 2>"$FLEET_STATE_DIR/tick.err"
  [ -z "${V42X_DEBUG:-}" ] || { cat "$FLEET_STATE_DIR/tick.err" "$V42X_GH_LOG"; } >&2
}
v42x_ev() { printf '%s' "$1" | jq -r '[.[] | select(.type | startswith("claim_")) | .type + ":" + .issue + (if .url then ":" + .url else "" end)] | join(" ")'; }
v42x_view() { printf '{"url": "%s", "state": "%s", "isCrossRepository": %s}' "$2" "$3" "$4" >"$V42X_DIR/view-$1.json"; } # v42x_view <N> <url> <state> <cross>
v42x_muts() { grep -c '^mutation IssueUpdate' "$LINEAR_LOG" || true; }
v42x_labels() { jq -r '.issues[0].labelIds | join(",")' "$LINEAR_DB"; }

v42x_attachment() { # the PR is only in the issue's attachments, in a repo nobody here has a team in
  v42x_state attach
  local u=https://github.com/acme/other-app/pull/12 ev
  v42x_db '{"attachmentUrls": ["'"$u"'", "https://example.com/not-a-pr"]}'; v42x_view 12 "$u" OPEN false
  ev="$(v42x_ev "$(v42x_tick)")"
  eq "v42x attachment: an open PR in a repo this machine has no team in holds the claim, and tick names it" "$ev" "claim_held_pr:DEV-7:$u"
  eq "v42x attachment: nothing was written and the other machine's label is kept" "$(v42x_muts):$(v42x_labels)" "0:L3"
  v42x_db '{"attachmentUrls": ["'"$u"'"]}'; v42x_view 12 "$u" MERGED false; rm -f "$FLEET_STATE_DIR/tick.state.json"
  ev="$(v42x_ev "$(v42x_tick)")"
  eq "v42x attachment: control, the same PR merged: the claim is released" "$ev:$(v42x_muts):$(v42x_labels)" "claim_released:DEV-7:1:"
  v42x_db '{"attachmentUrls": ["'"$u"'"]}'; v42x_view 12 "$u" OPEN true; rm -f "$FLEET_STATE_DIR/tick.state.json"
  ev="$(v42x_ev "$(v42x_tick)")"
  eq "v42x attachment: a fork PR (cross-repository) does not hold the claim" "$ev" "claim_released:DEV-7"
}

v42x_listed_other_repo() { # the reported case: this machine lists repo Y only; the PR is in repo X
  local R="$T/v42x-repo-y" u=https://github.com/acme/other-app/pull/12 ev
  rm -rf "$R"; git init -q "$R"; git -C "$R" remote add origin https://github.com/acme/app-y.git
  v42x_state listed "repos = [\"$R\"]"
  v42x_db '{"attachmentUrls": ["'"$u"'"]}'; v42x_view 12 "$u" OPEN false
  ev="$(v42x_ev "$(v42x_tick)")"
  eq "v42x listed: with only repo Y known, an open PR in repo X still holds the claim (4.2.1 released it)" "$ev:$(v42x_muts):$(v42x_labels)" "claim_held_pr:DEV-7:$u:0:L3"
}

v42x_branch() { # the PR is found only by the issue's branch (no attachment, no owner configured)
  v42x_state branch
  local u=https://github.com/acme/other-app/pull/21 ev
  v42x_db '{"branchName": "someone/dev-7-fix-it"}'
  printf '[{"url": "%s", "title": "fix it", "body": "Fixes https://linear.app/acme/issue/DEV-7"}]' "$u" >"$V42X_DIR/head.json"
  ev="$(v42x_ev "$(v42x_tick)")"
  eq "v42x branch: an open PR on fleet/<slug> that names the issue holds the claim, found with no owner and no attachment" "$ev" "claim_held_pr:DEV-7:$u"
  eq "v42x branch: the search used the branch without its user prefix, and nothing was written" "$(grep -c -- '^search prs --head fleet/dev-7-fix-it ' "$V42X_GH_LOG"):$(v42x_muts):$(v42x_labels)" "1:0:L3"
  printf '[{"url": "%s", "title": "other", "body": "Fixes https://linear.app/acme/issue/DEV-70"}]' "$u" >"$V42X_DIR/head.json"; rm -f "$FLEET_STATE_DIR/tick.state.json"; v42x_db '{"branchName": "someone/dev-7-fix-it"}'
  ev="$(v42x_ev "$(v42x_tick)")"
  eq "v42x branch: a PR on that branch that names a different issue (DEV-70) does not hold it" "$ev" "claim_released:DEV-7"
}

v42x_search() { # the PR is found only by a search over a configured owner
  v42x_state search 'repo_owners = ["acme"]'
  local u=https://github.com/acme/other-app/pull/31 ev
  v42x_db '{}'
  printf '[{"url": "%s", "title": "x", "body": "Fixes https://linear.app/acme/issue/DEV-7"}]' "$u" >"$V42X_DIR/search.json"
  ev="$(v42x_ev "$(v42x_tick)")"
  eq "v42x search: gh search prs over a repo_owners owner finds the PR and holds the claim" "$ev:$(grep -c -- '^search prs DEV-7 --owner acme ' "$V42X_GH_LOG")" "claim_held_pr:DEV-7:$u:1"
  eq "v42x search: nothing was written" "$(v42x_muts):$(v42x_labels)" "0:L3"
  printf '[]' >"$V42X_DIR/search.json"; rm -f "$FLEET_STATE_DIR/tick.state.json"
  eq "v42x search: control, no open PR: released" "$(v42x_ev "$(v42x_tick)")" "claim_released:DEV-7"
}

v42x_closed() { # a lookup that fails, or nothing to look in, never releases
  v42x_state closed 'repo_owners = ["acme"]'
  local ev
  v42x_db '{}'
  ev="$(V42X_GH_FAIL=1 v42x_tick)"
  eq "v42x closed: gh failing refuses: claim_lapsed (read-only), never claim_released, label kept" "$(v42x_ev "$ev"):$(v42x_muts):$(v42x_labels)" "claim_lapsed:DEV-7:0:L3"
  v42x_state closed2
  v42x_db '{}'
  ev="$(v42x_tick)"
  eq "v42x closed: no attachment, no branch and no owner is nothing to look in: claim_lapsed, never claim_released" "$(v42x_ev "$ev"):$(v42x_muts):$(v42x_labels)" "claim_lapsed:DEV-7:0:L3"
  v42x_state closed3
  v42x_db '{"attachmentUrls": ["https://github.com/acme/other-app/pull/5"]}'
  ev="$(v42x_tick)"
  eq "v42x closed: an attachment gh cannot view refuses too" "$(v42x_ev "$ev"):$(v42x_muts):$(v42x_labels)" "claim_lapsed:DEV-7:0:L3"
}

v42x_takeover() { # takeover shares the check
  v42x_state take
  local u=https://github.com/acme/other-app/pull/12
  v42x_db '{"attachmentUrls": ["'"$u"'"]}'; v42x_view 12 "$u" OPEN false
  FLEET_GH="$FLEET_STATE_DIR/gh-shim" FLEET_NOW=2026-10-29T10:00:00Z "$SCRIPTS/linear.sh" takeover DEV-7 >/dev/null 2>"$FLEET_STATE_DIR/e"
  eq "v42x takeover: refuses while the issue's attachment PR is open, writing nothing" "$?:$(grep -c "open PR ($u)" "$FLEET_STATE_DIR/e"):$(v42x_muts)" "1:1:0"
}

v42x_peer_repos() { # the repos of the PRs in the other machines' summaries are looked in too
  v42x_state peers
  v42x_db '{}' '[{"t":"t1","i":"DEV-7","pr":"acme/summary-app/pull/9"}]'
  v42x_tick >/dev/null
  eq "v42x peers: gh was asked about the repo of the PR in the peer's summary" "$(grep -c -- '^pr list.*--repo acme/summary-app' "$V42X_GH_LOG" | sed 's/^[1-9].*/some/')" some
}


# 4.2.3 (DEV-660): boot options after the repo dir are task text, so the issue was never claimed. Boot refuses them, a
# build boot on a fleet of several machines needs an issue, boot checks the claim once, and branches name the machine.
v42x_boot_state() { # a fresh state, DEV-7 labelled with the given label ids; the herdr shim log emptied
  v42x_state "$1" "${@:3}"
  jq -n --arg l "$2" '{team: "T1", states: {"In Progress": "S1"}, next: 100,
    labels: [{id: "L0", name: "fleet", description: "", parent: null},
      {id: "L2", name: "fleet:test", description: "heartbeat=2026-10-29T09:55:00Z", parent: {id: "L0", name: "fleet"}},
      {id: "L3", name: "fleet:other", description: "heartbeat=2026-10-29T09:55:00Z", parent: {id: "L0", name: "fleet"}}],
    issues: [{id: "I7", identifier: "DEV-7", team: {id: "T1"}, state: {id: "S1", name: "In Progress"}, labelIds: ($l | split(",") | map(select(. != ""))), comments: []}]}' >"$LINEAR_DB"
  : >"$HERDR_LOG"
  V42X_REPO="$FLEET_STATE_DIR/repo"; git init -q -b main "$V42X_REPO"; git -C "$V42X_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}
v42x_boot() { # the exit code; V42X_DEBUG=1 shows boot's stderr
  FLEET_FORCE=1 FLEET_MACHINE=test "$SCRIPTS/boot.sh" "$@" >"$FLEET_STATE_DIR/boot.out" 2>"$FLEET_STATE_DIR/boot.err"; local rc=$?
  [ -z "${V42X_DEBUG:-}" ] || cat "$FLEET_STATE_DIR/boot.err" >&2
  echo "$rc"
}
v42x_rows() { "$REG" list 2>/dev/null | jq length; }

v42x_misplaced() { # an option in the task text is refused before anything is created
  v42x_boot_state misplaced L2 'machines = 1'
  local o rc res=""
  for o in --issue --issue-url --issue-title --claimed-by --labels --scope --branch-slug --no-issue; do
    rc="$(v42x_boot build mp "$V42X_REPO" "do it" "$o" x)"
    res="$res $rc:$(grep -c "^fleet: $o is in the task text" "$FLEET_STATE_DIR/boot.err"):$(grep -c . "$HERDR_LOG"):$(v42x_rows)"
  done
  eq "v42x misplaced: each boot option after the repo dir is refused, named, with no herdr call and no row" "$res" \
    " 1:1:0:0 1:1:0:0 1:1:0:0 1:1:0:0 1:1:0:0 1:1:0:0 1:1:0:0 1:1:0:0"
  rc="$(v42x_boot build mp "$V42X_REPO" "do it --issue=DEV-7")"
  eq "v42x misplaced: --opt=value inside one quoted task string is refused too" "$rc:$(v42x_rows)" "1:0"
  rc="$(v42x_boot build mp "$V42X_REPO" fix the issue tracker --fixed-width)"
  eq "v42x misplaced: a task that only mentions issue or --fixed-width boots" "$rc" 0
}

v42x_no_issue() { # machines > 1: a build boot with no claim is refused, unless --no-issue
  v42x_boot_state noissue L2 'machines = 2'
  local rc
  rc="$(v42x_boot build ni "$V42X_REPO" task)"
  eq "v42x no-issue: machines = 2, build, no --issue: refused, nothing created" "$rc:$(grep -c 'build boot with no --issue on a fleet of 2 machines' "$FLEET_STATE_DIR/boot.err"):$(grep -c . "$HERDR_LOG"):$(v42x_rows)" "1:1:0:0"
  rc="$(v42x_boot --no-issue build ni "$V42X_REPO" task)"
  eq "v42x no-issue: --no-issue boots" "$rc" 0
  v42x_boot_state noissue2 L2 'machines = 2'
  eq "v42x no-issue: a research template is not affected" "$(v42x_boot research ni2 "$V42X_REPO" task)" 0
  v42x_boot_state noissue3 L2 'machines = 1'
  eq "v42x no-issue: machines = 1 is not affected" "$(v42x_boot build ni3 "$V42X_REPO" task)" 0
}

v42x_gate() { # boot reads the issue once: this machine's label and no other
  local rc
  v42x_boot_state gate1 L3 'linear_writes = "on"'
  rc="$(v42x_boot --issue DEV-7 build g1 "$V42X_REPO" task)"
  eq "v42x gate: another machine's label refuses, naming it, nothing created" "$rc:$(grep -c 'DEV-7 is claimed by fleet:other' "$FLEET_STATE_DIR/boot.err"):$(grep -c . "$HERDR_LOG"):$(v42x_rows)" "1:1:0:0"
  v42x_boot_state gate2 "" 'linear_writes = "on"'
  rc="$(v42x_boot --issue DEV-7 build g2 "$V42X_REPO" task)"
  eq "v42x gate: no label refuses, saying to claim first" "$rc:$(grep -c 'has no claim by' "$FLEET_STATE_DIR/boot.err"):$(v42x_rows)" "1:1:0"
  v42x_boot_state gate3 L2 'linear_writes = "on"'
  rc="$(v42x_boot --issue DEV-7 build g3 "$V42X_REPO" task)"
  eq "v42x gate: this machine's label boots, one issue read" "$rc:$(grep -c '^query Issue' "$LINEAR_LOG")" "0:1"
}

v42x_pushbranch() { # the team pushes fleet/<key>-<machine key>-<rest>; the brief and the row carry it
  v42x_boot_state branch L2 'linear_writes = "on"'
  local rc
  rc="$(v42x_boot --issue DEV-7 --branch-slug fix-login build br "$V42X_REPO" task)"
  eq "v42x branch: the row records the machine-specific branch" "$rc:$("$REG" get build-br/builder | jq -r .push_branch)" "0:fleet/dev-7-test-fix-login"
  check "v42x branch: the brief names the exact branch" grep -q 'Your branch is `fleet/dev-7-test-fix-login`' "$("$REG" get build-br/builder | jq -r .last_brief)"
  check "v42x branch: and pushes with --force-with-lease to it" grep -q 'force-with-lease origin fleet/dev-7-test-fix-login' "$("$REG" get build-br/builder | jq -r .last_brief)"
}

v42x_nameless_peer() { # DEV-661: a thin summary tier keeps a name for a team with no issue; the reader never prints a blank row
  qfresh v42xn; export FLEET_STATE_DIR="$QD/state.v42xn" FLEET_REGISTRY="$QD/state.v42xn/fleet.json" FLEET_INBOX="$QD/state.v42xn/escalations.jsonl"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"
  local n s out
  for n in 1 2 3 4 5 6; do
    if [ $((n % 2)) = 1 ]; then v413_agent "build-nameless-long-$n/lead" Lead Working "issue=DEV-$((660 + n))"
    else v413_agent "build-nameless-long-$n/lead" Lead Working; fi
  done
  s="$(bash -c '. "$1/common.sh"; fleet_summary 90' _ "$SCRIPTS")"
  eq "v42x nameless: at 90 characters the thin tier keeps rows and names each (the issue, else a short team name)" \
    "$(printf '%s' "$s" | jq -r 'length > 0 and ((tojson | length) <= 90) and all(.[]; has("i") or has("t"))')" true
  eq "v42x nameless: a team name in the thin tier is cut to 12 characters" \
    "$(printf '%s' "$s" | jq -r '[.[] | select(has("t")) | .t | length] | max <= 12')" true
  eq "v42x nameless: the full rows keep the whole team name" \
    "$(bash -c '. "$1/common.sh"; fleet_summary 1500' _ "$SCRIPTS" | jq -r '[.[].t | length] | min')" 21
  # the reader: a row with only t shows its team; rows with neither print no row and one line with the count
  v413_linear
  jq '.labels |= map(if .name == "fleet:peera" then .description = "owner=Fixture\nheartbeat=2026-10-29T09:55:00Z\nsummary=[{\"t\":\"only-team\",\"s\":\"Working\"}]"
        elif .name == "fleet:peerb" then .description = "heartbeat=2026-10-29T09:50:00Z\nsummary=[{\"s\":\"Working\"},{\"s\":\"Parked\"},{\"s\":\"Parked\"}]" else . end)' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  out="$(FLEET_NOW=2026-10-29T10:00:00Z "$SCRIPTS/status.sh" 2>/dev/null)"
  eq "v42x nameless reader: a peer row with only t is named by it" "$(printf '%s\n' "$out" | grep -c '^| only-team | peera ')" 1
  eq "v42x nameless reader: rows with neither print no blank row, one line gives the count" \
    "$(printf '%s\n' "$out" | grep -c '^| *| peerb '):$(printf '%s\n' "$out" | grep -c "^peerb: 3 teams (names didn't fit)$")" "0:1"
  v413_nolinear
}

v42x_smoke() { # the critical cases, CI
  local f
  for f in v42x_attachment v42x_listed_other_repo v42x_branch v42x_search v42x_closed v42x_takeover v42x_peer_repos v42x_nameless_peer v42x_misplaced v42x_no_issue v42x_gate v42x_pushbranch; do
    case " ${V42X_ONLY:-$f} " in *" $f "*) "$f" ;; esac
  done
}
v42x_full() { # every case
  v42x_smoke
}
