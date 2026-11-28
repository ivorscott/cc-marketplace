#!/usr/bin/env bash
# Teams: a team's life outside the tick. boot, tell, retire, park (and --undo), hold --off, next, revive, respawn,
# env (the team test environment), catchup, decide and defer. One case per behaviour; output shapes are `commands`.
# Sourced by run.sh (ok/eq/check, $SCRIPTS, $T, $REG, $AS, $HERDR_LOG from lib.sh).

tm_state() { # tm_state <name>: a fresh state root, no agent state, an empty config
  export FLEET_STATE_DIR="$T/tm-$1" FLEET_REGISTRY="$T/tm-$1/fleet.json" FLEET_INBOX="$T/tm-$1/escalations.jsonl" FLEET_WORKTREES="$T/tm-$1/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; rm -f "$AS"/*; : >"$HERDR_LOG"; gcfg; export FLEET_FORCE=
  unset FLEET_NOW FLEET_CURL LINEAR_STUB_KEY LINEAR_DB LINEAR_LOG; rm -f "$FLEET_CONFIG_DIR/linear_api""_key"
}
tm_repo() { # tm_repo <dir>: a repo with one commit, pushed to a bare origin
  rm -rf "$1" "$1-origin.git"; git init -q -b main "$1"; echo tracked >"$1/tracked.txt"; git -C "$1" add tracked.txt
  git -C "$1" -c user.email=t@t -c user.name=t commit -q -m init
  git init -q --bare "$1-origin.git"; git -C "$1" remote add origin "$1-origin.git"; git -C "$1" push -q origin main 2>/dev/null
}
tm_linear() { # a fake Linear: DEV-1 In Progress, labelled fleet:test, writes on
  local kf="linear_api""_key"
  export LINEAR_STUB_KEY=KEYFIXTURE-teams LINEAR_DB="$FLEET_STATE_DIR/linear.json" LINEAR_LOG="$FLEET_STATE_DIR/linear.log" LINEAR_ARGV_LOG="$FLEET_STATE_DIR/linear.argv" FLEET_CURL="$HERE/linear-stub.sh"
  : >"$LINEAR_LOG"
  jq -n '{team: "T1", states: {Done: "S3", Todo: "S2", Verify: "S4", "In Progress": "S1"}, next: 100,
    labels: [{id: "L0", name: "fleet", description: "", parent: null}, {id: "L2", name: "fleet:test", description: "heartbeat=2026-10-29T09:55:00Z", parent: {id: "L0", name: "fleet"}}],
    issues: [{id: "I1", identifier: "DEV-1", team: {id: "T1"}, state: {id: "S1", name: "In Progress"}, labelIds: ["L2"], comments: []}]}' >"$LINEAR_DB"
  printf 'KEYFIXTURE-teams\n' >"$FLEET_CONFIG_DIR/$kf"; chmod 600 "$FLEET_CONFIG_DIR/$kf"; gcfg 'linear_writes = "on"'
}
tm_row() { # tm_row <team/role> <tier> <status> [extra json]
  "$REG" add "$(jq -cn --arg n "$1" --arg tier "$2" --arg st "$3" --argjson x "${4:-{\}}" --arg r "${TM_REPO:-$T/tm-repo}" \
    '{name: $n, team: ($n | split("/")[0]), tier: $tier, status: $st, herdr_ref: ($n | sub("/"; "-")), pane: ("p-" + ($n | sub("/"; "-"))), workspace: "w0",
      repo: $r, cwd: $r, harness: "claude", template: "build", assignment: "task", machine: "test"} + $x')" >/dev/null
}
tm_wt() { # tm_wt <repo> <branch>: a pushed worktree of <repo>, its path printed
  local w="$T/tm-wt/${2//\//-}"; rm -rf "$w"; git -C "$1" worktree add -q -b "$2" "$w" >/dev/null 2>&1; git -C "$w" push -q origin "$2" 2>/dev/null; printf '%s' "$w"
}
tm_status() { "$REG" list --team "$1" | jq -r '[.[].status] | unique | join(",")'; }

teams_boot() {
  tm_state boot; local R="$T/tm-boot-repo" rc n bf w
  tm_repo "$R"; mkdir -p "$R/.claude"; printf 'Repo rule: run make check.\n' >"$R/.claude/fleet-rules.md"
  git -C "$R" add .claude && git -C "$R" -c user.email=t@t -c user.name=t commit -q -m rules && git -C "$R" push -q origin main 2>/dev/null
  "$SCRIPTS/boot.sh" --issue DEV-7 --issue-url https://tracker.example/issue/DEV-7 build bt "$R" "build the thing" >"$T/tm-boot.out" 2>"$T/tm-boot.err"; rc=$?
  n="$("$REG" list --team build-bt | jq length)"
  eq "boot: a build team boots: lead, planner, builder, tester" "$rc:$n:$("$REG" list --team build-bt | jq -r '[.[].name | split("/")[1]] | sort | join(",")')" "0:4:builder,lead,planner,tester"
  eq "boot: one workspace for the team" "$(grep -c '^workspace create' "$HERDR_LOG")" 1
  w="$("$REG" get build-bt/builder | jq -r .worktree)"
  eq "boot: a writer gets its own worktree on fleet/<team>/<role>" "$(git -C "$w" branch --show-current 2>/dev/null)" "fleet/build-bt/builder"
  eq "boot: the lead has no worktree" "$("$REG" get build-bt/lead | jq -r '.worktree // ""')" ""
  eq "boot: each agent gets one pointer line to its brief, never the brief text" \
    "$(grep -c '^agent prompt build-bt-[a-z]* Read your brief: ' "$HERDR_LOG"):$(grep -c 'House rules (fleet)' "$HERDR_LOG" || true)" "$n:0"
  bf="$("$REG" get build-bt/builder | jq -r .last_brief)"
  eq "boot: the brief is a mode-600 file" "$(stat -f %Lp "$bf" 2>/dev/null || stat -c %a "$bf")" 600
  eq "boot: the brief carries the done contract, the house rules once, then the repo's rules" \
    "$(grep -c 'registry.sh done' "$bf" | awk '{print ($1 > 0)}'):$(grep -c '^House rules (fleet)' "$bf"):$(awk '/^House rules/ {h = NR} /Repo rule: run make check/ {r = NR} END {print (h && r > h)}' "$bf")" "1:1:1"
  check "boot: --issue puts the exact Fixes line in the builder's brief" grep -q 'Fixes https://tracker.example/issue/DEV-7' "$bf"
  eq "boot: rows carry the issue and its URL" "$("$REG" get build-bt/builder | jq -r '[.issue, .issue_url] | join(" ")')" "DEV-7 https://tracker.example/issue/DEV-7"
  eq "boot: every agent starts with a session id and permission checks on" \
    "$(grep '^agent start' "$HERDR_LOG" | grep -c -- '--session-id [0-9a-f-]\{36\}'):$(grep -c -- '--permission-mode bypassPermissions\|--dangerously' "$HERDR_LOG" || true)" "$n:0"
  eq "boot: no pane's environment carries the tracker key" "$(cat "$AS"/*.env 2>/dev/null | grep -c LINEAR_API_KEY || true)" 0
  # refusals: a name already live, leftovers of an earlier boot, caps, disk
  "$SCRIPTS/boot.sh" build bt "$R" "again" >/dev/null 2>&1; eq "boot: a team name already live is refused" "$?" 1
  "$REG" retire build-bt >/dev/null 2>&1
  : >"$HERDR_LOG"; "$SCRIPTS/boot.sh" build bt "$R" "again" >/dev/null 2>"$T/tm-left.err"; rc=$?
  eq "boot: leftovers of an earlier boot (its branches) are refused, with no herdr call" "$rc:$(grep -c leftovers "$T/tm-left.err"):$(wc -l <"$HERDR_LOG" | tr -d ' ')" "1:1:0"
  "$SCRIPTS/retire.sh" build-bt >/dev/null 2>&1
  "$SCRIPTS/boot.sh" build bt "$R" "again" >/dev/null 2>&1; eq "boot: after retire tidies them the name boots again" "$?" 0
  gcfg 'max_teams = 1'
  : >"$HERDR_LOG"; "$SCRIPTS/boot.sh" build b2 "$R" "t" >/dev/null 2>"$T/tm-cap.err"; rc=$?
  eq "boot: over max_teams is refused, with no herdr call and no rows" "$rc:$(grep -c max_teams "$T/tm-cap.err"):$(wc -l <"$HERDR_LOG" | tr -d ' '):$("$REG" list --team build-b2 | jq length)" "1:1:0:0"
  FLEET_FORCE=1 "$SCRIPTS/boot.sh" build b2 "$R" "t" >/dev/null 2>&1; eq "boot: FLEET_FORCE=1 overrides the cap" "$?" 0
  gcfg 'teams_per_repo = 1' 'max_teams = 9'
  "$SCRIPTS/boot.sh" build b3 "$R" "t" >/dev/null 2>"$T/tm-tpr.err"; eq "boot: over teams_per_repo is refused" "$?:$(grep -c teams_per_repo "$T/tm-tpr.err")" "1:1"
  gcfg 'max_teams = 9' 'teams_per_repo = 9'
  DF_GB=10 "$SCRIPTS/boot.sh" build b4 "$R" "t" >/dev/null 2>"$T/tm-df.err"; eq "boot: below the disk floor is refused" "$?:$(grep -c min_free_gb "$T/tm-df.err")" "1:1"
  # a boot that dies after the first panes undoes what it made
  : >"$HERDR_LOG"; SPLIT_FAIL_AT=2 "$SCRIPTS/boot.sh" build b5 "$R" "t" >/dev/null 2>&1; rc=$?
  eq "boot: a boot that fails part way undoes its rows, worktrees and branches" \
    "$((rc != 0)):$("$REG" list --team build-b5 | jq '[.[] | select(.status != "Retired")] | length'):$(git -C "$R" for-each-ref --format=x refs/heads/fleet/build-b5/ | grep -c . || true)" "1:0:0"
  # a brief that never lands
  : >"$HERDR_LOG"; rm -f "$AS"/*; BRIEF_LOST=1 PROMPT_NOSTATE=1 "$SCRIPTS/boot.sh" build b6 "$R" "t" >/dev/null 2>&1; rc=$?
  eq "boot: a brief that never lands fails the boot and marks the rows Failed" "$((rc != 0)):$(tm_status build-b6)" "1:Failed"
  gcfg
}

teams_boot_claim() { # several machines on Linear: --issue options before the template, and the claim is checked
  tm_state claim; local R="$T/tm-claim-repo" rc
  tm_repo "$R"; gcfg 'machines = 2'
  "$SCRIPTS/boot.sh" --issue DEV-1 build nk "$R" t >/dev/null 2>&1; eq "boot: --issue with no tracker key and machines > 1 is refused" "$?" 1
  tm_linear; gcfg 'linear_writes = "on"' 'machines = 2'
  "$SCRIPTS/boot.sh" --issue DEV-1 --claimed-by test build own "$R" t >/dev/null 2>&1; rc=$?
  eq "boot: this machine's own claim boots and the row records it" "$rc:$("$REG" get build-own/builder | jq -r '[.issue, .claimed_by] | join(",")')" "0:DEV-1,test"
  "$SCRIPTS/boot.sh" --issue DEV-1 --claimed-by other build oth "$R" t >/dev/null 2>&1; rc=$?
  eq "boot: another machine's claim is refused, even with FLEET_FORCE" "$rc:$(FLEET_FORCE=1 "$SCRIPTS/boot.sh" --issue DEV-1 --claimed-by other build oth2 "$R" t >/dev/null 2>&1; echo $?)" "1:1"
  "$SCRIPTS/boot.sh" --nope build x "$R" t >/dev/null 2>&1; eq "boot: an unknown option is refused" "$?" 1
  gcfg
}

teams_tell() {
  tm_state tell; TM_REPO="$T/tm-tell-repo"; tm_repo "$TM_REPO"
  local out rc
  tm_row tl/builder Worker Idle
  out="$("$SCRIPTS/tell.sh" tl/builder "do the thing" 2>/dev/null)"; rc=$?
  eq "tell: delivered when the agent goes working" "$rc:$(told "$out")" "0:true"
  rm -f "$AS"/*; : >"$HERDR_LOG"
  out="$(PROMPT_NOSTATE=1 ENTER_WORKS=1 "$SCRIPTS/tell.sh" tl/builder "needs an enter" 2>/dev/null)"; rc=$?
  eq "tell: one enter retries a message that sat in the input box" "$rc:$(told "$out"):$(grep -c '^agent send-keys tl-builder enter' "$HERDR_LOG")" "0:true:1"
  rm -f "$AS"/*
  out="$(PROMPT_NOSTATE=1 "$SCRIPTS/tell.sh" tl/builder "never arrives" 2>/dev/null)"; rc=$?
  eq "tell: no sign of arrival is not delivered (exit 1)" "$rc:$(told "$out")" "1:false"
  out="$(PROMPT_FAIL=1 "$SCRIPTS/tell.sh" tl/builder "x" 2>/dev/null)"; eq "tell: a send herdr rejects is exit 1" "$?" 1
  echo gone >"$AS/tl-builder"; "$SCRIPTS/tell.sh" tl/builder "x" >/dev/null 2>&1; eq "tell: an agent herdr cannot find exits 2" "$?" 2
  rm -f "$AS"/*
  # a Done or Parked team whose PR is open comes back through its lead
  export FLEET_GH="$QD/gh-shim" PROMPT_SEQ=1; rm -f "$QGHD"/*.json; gcfg "max_teams = 9" "teams_per_repo = 9"
  qpr app-api 80 fleet/dev-1-x main 2026-10-29T08:00:00Z '["a.go"]' x
  for r in lead:Lead builder:Worker tester:Worker; do tm_row "rv-a/${r%%:*}" "${r##*:}" Done '{"pr":"https://github.com/acme/app-api/pull/80","issue":"DEV-1"}'; done
  out="$("$SCRIPTS/tell.sh" rv-a/builder "check the build" 2>&1)"; rc=$?
  eq "tell: a message to a Done team with an open PR revives it through the lead" \
    "$rc:$(printf '%s' "$out" | grep -c '(revived)$'):$("$REG" get rv-a/lead | jq -r .status):$(grep -c '(meant for builder) check the build' "$("$REG" get rv-a/lead | jq -r .last_brief)")" "0:1:Working:1"
  qpr app-api 81 fleet/dev-2-x main 2026-10-29T08:00:00Z '["b.go"]' x; jq '.state = "MERGED"' "$QGHD/app-api-81.json" >"$T/tm-m.json" && mv "$T/tm-m.json" "$QGHD/app-api-81.json"
  for r in lead:Lead builder:Worker; do tm_row "rv-b/${r%%:*}" "${r##*:}" Done '{"pr":"https://github.com/acme/app-api/pull/81"}'; done
  "$SCRIPTS/tell.sh" rv-b/lead "one more thing" >/dev/null 2>&1; rc=$?
  eq "tell: a team whose PR merged is not revived" "$rc:$(tm_status rv-b)" "1:Done"
  unset PROMPT_SEQ FLEET_GH TM_REPO; gcfg
}

teams_retire() {
  tm_state retire; local R="$T/tm-ret-repo" W rc
  tm_repo "$R"; export FLEET_ARCHIVE_DIR="$T/tm-archive"; rm -rf "$FLEET_ARCHIVE_DIR"
  mk() { # mk <team>: a lead and a builder with a pushed worktree
    TM_REPO="$R" tm_row "$1/lead" Lead Working
    TM_REPO="$R" tm_row "$1/builder" Worker Working "$(jq -cn --arg w "$(tm_wt "$R" "fleet/$1-b")" '{worktree: $w, cwd: $w}')"
  }
  # clean: reports archived, worktree removed, only the team's panes closed
  mk rt-a; W="$("$REG" get rt-a/builder | jq -r .worktree)"; mkdir -p "$W/reports" "$W/node_modules"; echo r >"$W/reports/r.md"; echo m >"$W/node_modules/i.js"
  : >"$HERDR_LOG"; "$SCRIPTS/retire.sh" rt-a >"$T/tm-ret.out" 2>&1; rc=$?
  eq "retire: a clean team is retired and its worktree removed" "$rc:$(tm_status rt-a):$([ -e "$W" ] && echo kept || echo gone)" "0:Retired:gone"
  eq "retire: reports are archived, build output is not" "$(cd "$FLEET_ARCHIVE_DIR/rt-a-builder" 2>/dev/null && find . -type f | sort | tr '\n' ' ')" "./reports/r.md "
  eq "retire: only the team's own workspace is closed" "$(grep -c '^workspace close w0' "$HERDR_LOG"):$(grep '^pane close\|^workspace close' "$HERDR_LOG" | grep -vc ' w0\| p-rt-a-' || true)" "1:0"
  # kept worktrees: unpushed commit, uncommitted change, untracked source
  mk rt-b; W="$("$REG" get rt-b/builder | jq -r .worktree)"; git -C "$W" -c user.email=t@t -c user.name=t commit -q --allow-empty -m wip
  "$SCRIPTS/retire.sh" rt-b >"$T/tm-ret.out" 2>&1
  eq "retire: a worktree with an unpushed commit is kept and named" "$([ -d "$W" ] && echo kept):$(grep -c 'Kept: builder (unpushed commits)' "$T/tm-ret.out")" "kept:1"
  mk rt-c; W="$("$REG" get rt-c/builder | jq -r .worktree)"; echo changed >"$W/tracked.txt"
  "$SCRIPTS/retire.sh" rt-c >"$T/tm-ret.out" 2>&1
  eq "retire: a worktree with an uncommitted change is kept" "$([ -d "$W" ] && echo kept):$(grep -c 'uncommitted changes' "$T/tm-ret.out")" "kept:1"
  mk rt-d; W="$("$REG" get rt-d/builder | jq -r .worktree)"; mkdir -p "$W/src"; echo x >"$W/src/new.go"
  "$SCRIPTS/retire.sh" rt-d >"$T/tm-ret.out" 2>&1
  eq "retire: untracked source keeps the worktree" "$([ -d "$W" ] && echo kept):$(grep -c 'untracked files' "$T/tm-ret.out")" "kept:1"
  # open escalations close at retire
  TM_REPO="$R" tm_row rt-e/lead Lead Working; "$REG" escalate rt-e/lead P1 "which port?" 80 81 >/dev/null 2>&1
  "$SCRIPTS/retire.sh" rt-e >/dev/null 2>&1
  eq "retire: open escalations close with 'closed at retire'" "$("$REG" escalations --open --team rt-e | jq length):$("$REG" escalations --team rt-e | jq -r '.[0].resolution')" "0:closed at retire"
  # Linear: Shipped moves the issue to Done once its PR merged; Abandoned puts it back in Todo
  tm_linear; export FLEET_GH="$QD/gh-shim"; rm -f "$QGHD"/*.json
  qpr app-api 90 fleet/dev-1-x main 2026-10-29T08:00:00Z '["a.go"]' "Fixes DEV-1"; jq '.state = "MERGED"' "$QGHD/app-api-90.json" >"$T/tm-m.json" && mv "$T/tm-m.json" "$QGHD/app-api-90.json"
  TM_REPO="$R" tm_row rt-f/lead Lead Done '{"issue":"DEV-1","claimed_by":"test"}'; TM_REPO="$R" tm_row rt-f/builder Worker Done '{"issue":"DEV-1","claimed_by":"test","pr":"https://github.com/acme/app-api/pull/90"}'
  "$SCRIPTS/retire.sh" rt-f --outcome Shipped >/dev/null 2>&1
  eq "retire: Shipped with a merged PR moves the issue to Done" "$(jq -r '.issues[] | select(.identifier == "DEV-1") | .state.name' "$LINEAR_DB")" Done
  jq '(.issues[] | select(.identifier == "DEV-1") | .state) = {id: "S1", name: "In Progress"}' "$LINEAR_DB" >"$T/tm-l.json" && mv "$T/tm-l.json" "$LINEAR_DB"
  TM_REPO="$R" tm_row rt-g/lead Lead Working '{"issue":"DEV-1","claimed_by":"test"}'
  "$SCRIPTS/retire.sh" rt-g --outcome Abandoned >/dev/null 2>&1
  eq "retire: Abandoned puts the issue back in Todo" "$(jq -r '.issues[] | select(.identifier == "DEV-1") | .state.name' "$LINEAR_DB")" Todo
  unset FLEET_GH FLEET_ARCHIVE_DIR TM_REPO; gcfg
}

teams_park() {
  tm_state park; local R="$T/tm-park-repo" W rc sha
  tm_repo "$R"; export TM_REPO="$R"
  pk() { tm_row "$1/lead" Lead Working '{"issue":"DEV-9"}'; tm_row "$1/builder" Worker Working "$(jq -cn --arg w "$(tm_wt "$R" "fleet/$1-b")" '{worktree: $w, cwd: $w, issue: "DEV-9"}')"; }
  pk pk-a; pk pk-b
  FLEET_ROLE=lead "$SCRIPTS/park.sh" pk-a >/dev/null 2>&1; eq "park: an agent may not park" "$?" 1
  : >"$HERDR_LOG"; "$SCRIPTS/park.sh" pk-a >/dev/null 2>&1; rc=$?
  W="$("$REG" get pk-a/builder | jq -r .worktree)"
  eq "park: a clean team parks, its panes closed, its worktree and issue kept" \
    "$rc:$(tm_status pk-a):$(grep -c '^pane close' "$HERDR_LOG"):$(git -C "$W" branch --show-current):$("$REG" get pk-a/lead | jq -r .issue)" "0:Parked:2:fleet/pk-a-b:DEV-9"
  eq "park: a parked team does not count against max_teams" "$(bash -c ". '$SCRIPTS/common.sh'; live_team_count")" 1
  W="$("$REG" get pk-b/builder | jq -r .worktree)"; echo wip >"$W/wip.txt"; : >"$HERDR_LOG"; sha="$(shasum "$FLEET_REGISTRY")"
  "$SCRIPTS/park.sh" pk-b >/dev/null 2>&1; rc=$?
  eq "park: a dirty worktree is refused and nothing changes" "$rc:$(grep -c '^pane close' "$HERDR_LOG"):$([ "$(shasum "$FLEET_REGISTRY")" = "$sha" ] && echo same)" "1:0:same"
  rm -f "$W/wip.txt"
  AGENT_LIST_FAIL=1 "$SCRIPTS/park.sh" pk-b >/dev/null 2>&1; eq "park: herdr down is refused" "$?" 1
  # --undo brings it back, refused over a cap
  gcfg 'max_teams = 1' 'teams_per_repo = 9'
  "$SCRIPTS/park.sh" pk-a --undo >/dev/null 2>&1; eq "park --undo: refused while the cap is full" "$?:$(tm_status pk-a)" "1:Parked"
  gcfg 'teams_per_repo = 9'
  : >"$HERDR_LOG"; "$SCRIPTS/park.sh" pk-a --undo >/dev/null 2>&1; rc=$?
  eq "park --undo: the team comes back with a resume brief, the lead Working" \
    "$rc:$("$REG" get pk-a/lead | jq -r .status):$(grep -c '^agent prompt pk-a-[a-z]* Read your brief: ' "$HERDR_LOG")" "0:Working:2"
  "$SCRIPTS/park.sh" pk-a --after-merge >/dev/null 2>&1; eq "park: --after-merge is gone (5.0)" "$?" 1
  unset TM_REPO; gcfg
}

teams_hold() {
  tm_state hold; local u="https://github.com/acme/app-api/pull/9"
  "$SCRIPTS/hold.sh" "$u" --note "wait for the release" >/dev/null 2>&1
  eq "hold: a PR is held with its note" "$(jq -r --arg u "$u" '.[$u].note' "$FLEET_STATE_DIR/holds.json")" "wait for the release"
  "$SCRIPTS/hold.sh" "$u" >/dev/null 2>&1; eq "hold: a note is required" "$?" 1
  "$SCRIPTS/fleet" hold "$u" --off >/dev/null 2>&1; eq "hold --off: the hold is gone" "$?:$(jq -r length "$FLEET_STATE_DIR/holds.json")" "0:0"
  "$SCRIPTS/hold.sh" "$u" --off >/dev/null 2>&1; eq "hold --off: a PR that is not held is refused" "$?" 1
  FLEET_ROLE=lead "$SCRIPTS/hold.sh" "$u" --note x >/dev/null 2>&1; eq "hold: an agent may not hold" "$?" 1
}

teams_next_revive_respawn() {
  tm_state next; TM_REPO="$T/tm-next-repo"; tm_repo "$TM_REPO"; local rc nb
  "$SCRIPTS/boot.sh" --issue DEV-1 build nx "$TM_REPO" "first issue" >/dev/null 2>&1
  nb="$("$REG" list --team build-nx | jq length)"
  for r in $("$REG" list --team build-nx | jq -r '.[].herdr_ref'); do echo idle >"$AS/$r"; done
  echo working >"$AS/build-nx-builder"; "$SCRIPTS/next.sh" build-nx DEV-2 >/dev/null 2>&1; rc=$?
  eq "next: a team with an agent mid-turn is not moved" "$rc:$("$REG" list --team build-nx | jq -r '[.[].issue // ""] | unique | join(",")')" "1:DEV-1"
  echo idle >"$AS/build-nx-builder"; : >"$HERDR_LOG"; "$REG" set build-nx/builder outcome=Shipped summary="PR opened" >/dev/null
  "$SCRIPTS/next.sh" build-nx DEV-2 >/dev/null 2>&1; rc=$?
  eq "next: at a safe point every agent restarts fresh on the new issue with its brief" \
    "$rc:$("$REG" list --team build-nx | jq -r '[.[].issue] | unique | join(",")'):$(grep -c '^agent prompt build-nx-[a-z]* /exit' "$HERDR_LOG"):$(grep -c '^agent prompt build-nx-[a-z]* Read your brief: ' "$HERDR_LOG")" "0:DEV-2:$nb:$nb"
  eq "next: issue_done is logged for the old issue with its outcome" "$(jq -s '[.[] | select(.type == "issue_done")] | length' "$FLEET_STATE_DIR/events.jsonl")" 1
  # respawn: a Zombie row is started again from its row; a Done or Retired one is not
  "$REG" set build-nx/builder status=Zombie >/dev/null; : >"$HERDR_LOG"
  "$SCRIPTS/respawn.sh" build-nx/builder >/dev/null 2>&1; rc=$?
  eq "respawn: a dead agent starts again from its row with a new session, Working" \
    "$rc:$(grep '^agent start build-nx-builder ' "$HERDR_LOG" | grep -c -- '--session-id'):$("$REG" get build-nx/builder | jq -r .status)" "0:1:Working"
  "$REG" set build-nx/tester status=Done >/dev/null; : >"$HERDR_LOG"
  "$SCRIPTS/respawn.sh" build-nx/tester >/dev/null 2>&1; eq "respawn: a Done row is not respawned" "$(grep -c '^agent start' "$HERDR_LOG")" 0
  # revive: a Done team comes back with one thing to do; the lead Working, workers Idle
  for r in $("$REG" list --team build-nx | jq -r '.[].name'); do "$REG" set "$r" status=Done >/dev/null; done
  for r in $("$REG" list --team build-nx | jq -r '.[].herdr_ref'); do echo gone >"$AS/$r"; done
  "$SCRIPTS/revive.sh" build-nx --text "answer the review" >/dev/null 2>&1; rc=$?
  eq "revive: a Done team comes back, the lead with the text in its brief" \
    "$rc:$("$REG" get build-nx/lead | jq -r .status):$("$REG" get build-nx/builder | jq -r .status):$(grep -c 'answer the review' "$("$REG" get build-nx/lead | jq -r .last_brief)")" "0:Working:Idle:1"
  unset TM_REPO
}

teams_env() {
  tm_state env; local R="$T/tm-env-repo" rc
  tm_repo "$R"; mkdir -p "$R/.claude"
  jq -n --arg u "$T/up.sh" --arg d "$T/down.sh" '{up: "\($u) {{cluster}} {{kubeconfig}} {{http_port}} {{https_port}} {{branch}}", down: "\($d) {{cluster}} {{http_port}}", kubeconfig: "true"}' >"$R/.claude/fleet-env.json"
  export STUB_LOG="$T/tm-stub.log"; : >"$STUB_LOG"
  TM_REPO="$R" tm_row build-ea/builder Worker Working; TM_REPO="$R" tm_row build-eb/builder Worker Working
  (cd "$R" && "$SCRIPTS/env.sh" up build-ea >/dev/null 2>&1); rc=$?
  eq "env: up runs the repo's up once and writes a kubeconfig with the team's context" \
    "$rc:$(grep -c '^up fleet-build-ea ' "$STUB_LOG"):$(grep -c '^  name: fleet-build-ea$' "$FLEET_STATE_DIR/env/build-ea/kubeconfig")" "0:1:1"
  eq "env: status says Up" "$("$SCRIPTS/env.sh" status build-ea)" "Env build-ea: Up. Context fleet-build-ea."
  (cd "$R" && "$SCRIPTS/env.sh" up build-eb >/dev/null 2>&1)
  eq "env: two teams get different port slots" "$("$REG" env-get build-ea | jq -r .http_port)$([ "$("$REG" env-get build-ea | jq -r .http_port)" != "$("$REG" env-get build-eb | jq -r .http_port)" ] && echo :differ)" "$("$REG" env-get build-ea | jq -r .http_port):differ"
  "$SCRIPTS/env.sh" down build-ea >/dev/null 2>&1
  eq "env: down runs the repo's down and frees the slot" "$(grep -c '^down fleet-build-ea' "$STUB_LOG"):$("$REG" env-get build-ea | jq -r .state)" "1:Down"
  eq "env: nothing reached a real docker or kind" "$(wc -l <"$REAL_DOCKER_LOG" | tr -d ' ')" 0
  "$SCRIPTS/retire.sh" build-eb >/dev/null 2>&1
  eq "env: retire takes a team's environment down" "$(grep -c '^down fleet-build-eb' "$STUB_LOG"):$("$REG" env-get build-eb | jq -r .state)" "1:Down"
  unset STUB_LOG
}

teams_catchup() {
  tm_state catchup; TM_REPO="$T/tm-cc-repo"; tm_repo "$TM_REPO"; local rc
  export FLEET_GH="$QD/gh-shim"; rm -f "$QGHD"/*.json
  qpr app-api 61 fleet/td-x main 2026-10-29T08:00:00Z '["a.go"]' x CONFLICTING
  for r in lead:Lead builder:Worker tester:Worker; do tm_row "td/${r%%:*}" "${r##*:}" Done '{"pr":"https://github.com/acme/app-api/pull/61","issue":"DEV-1"}'; echo gone >"$AS/td-${r%%:*}"; done
  : >"$HERDR_LOG"; "$SCRIPTS/catchup.sh" td https://github.com/acme/app-api/pull/61 https://github.com/acme/app-api/pull/60 >/dev/null 2>&1; rc=$?
  local b; b="$("$REG" get td/lead | jq -r .last_brief)"
  eq "catchup: a finished team comes back to merge main into its conflicting PR" "$rc:$("$REG" get td/lead | jq -r .status)" "0:Working"
  eq "catchup: the brief says merge origin/main and a plain push, never a rebase or force-push" \
    "$(grep -c 'git merge origin/main' "$b" | awk '{print ($1 > 0)}'):$(sed -n '/What to do now/,$p' "$b" | grep -ciE 'git rebase|push -f|--force' || true)" "1:0"
  unset FLEET_GH TM_REPO
}

teams_decide() {
  tm_state decide; tm_linear; export FLEET_NOW=2026-10-29T10:00:00Z
  local id out
  "$REG" add '{"name":"dc-a/lead","team":"dc-a","tier":"Lead","status":"Working","herdr_ref":"dc-a-lead","pane":"p1","issue":"DEV-1"}' >/dev/null; echo working >"$AS/dc-a-lead"
  "$REG" escalate dc-a/lead P1 "which database?" "use postgres" sqlite >/dev/null 2>&1
  id="$("$REG" escalations --open | jq -r '.[0].id')"
  eq "decide: with no arguments it lists the open question" "$("$SCRIPTS/fleet" decide | grep -c "^| $id | ")" 1
  : >"$HERDR_LOG"; out="$("$SCRIPTS/decide.sh" dc-a "$id" 2>&1)"
  eq "decide: the first option is taken, the lead told, the question closed, the decision noted" \
    "$(printf '%s' "$out" | grep -c '→ use postgres'):$(grep -c 'use postgres' "$HERDR_LOG" | awk '{print ($1 > 0)}'):$("$REG" escalations --open | jq length):$("$REG" get dc-a/lead | jq '[.notes[] | select(.kind == "decision")] | length')" "1:1:0:1"
  eq "decide: the decision is commented on the issue as the fleet's" "$(jq -r '.issues[0].comments[0].body' "$LINEAR_DB" | grep -c '^\[fleet\]')" 1
  local q
  for q in "may I merge the PR to main myself?" "Rotate the API key" "kubectl apply the manifests to production"; do
    "$REG" escalate dc-a/lead P1 "$q" yes no >/dev/null 2>&1; id="$("$REG" escalations --open | jq -r '[.[] | select(.parked != true)][0].id')"
    eq "decide: '$q' is the human's: parked, left open" "$("$SCRIPTS/decide.sh" dc-a "$id" 2>&1 | grep -c '^Parked '):$("$REG" escalations --open | jq -r --arg i "$id" '[.[] | select(.id == $i and .parked == true)] | length')" "1:1"
  done
  "$REG" escalate dc-a/lead P0 "the database is gone" restore wait >/dev/null 2>&1; id="$("$REG" escalations --open | jq -r '[.[] | select(.parked != true)][0].id')"
  eq "decide: a P0 is parked whatever it says" "$("$SCRIPTS/decide.sh" dc-a "$id" 2>&1 | grep -c '^Parked ')" 1
  echo idle >"$AS/dc-a-lead"; : >"$HERDR_LOG"
  out="$("$SCRIPTS/fleet" decide dc-a "$id" --answer "restore it" 2>&1)"
  eq "decide --answer: the lead is told the owner's answer and the question closes" \
    "$(grep -c "The owner answered your question $id: restore it" "$HERDR_LOG"):$("$REG" escalations --open | jq -r --arg i "$id" '[.[] | select(.id == $i)] | length')" "1:0"
  "$SCRIPTS/fleet" decide dc-a "$id" --answer again >/dev/null 2>&1; eq "decide --answer: a closed question is refused" "$?" 1
  FLEET_ROLE=lead "$SCRIPTS/decide.sh" >/dev/null 2>&1; eq "decide: an agent may not decide" "$?" 1
  unset FLEET_NOW; gcfg
}

teams_defer() {
  tm_state defer; tm_linear; export FLEET_GH="$QD/gh-shim"; rm -f "$QGHD"/*.json
  local o body="Fixes DEV-1

Deferred:
- review the onboarding copy
- decide on the export name

Done."
  qpr app-api 70 fleet/dev-1-x main 2026-10-29T08:00:00Z '["a.go"]' "$body"
  "$REG" add '{"name":"rp-a/lead","team":"rp-a","tier":"Lead","status":"Working","herdr_ref":"rp-a-lead","pane":"pl","issue":"DEV-1","pr":"https://github.com/acme/app-api/pull/70"}' >/dev/null
  o="$("$SCRIPTS/defer.sh" rp-a 2>&1)"
  eq "defer: each deferred item of the PR body is filed as an issue linked to the PR" \
    "$(printf '%s\n' "$o" | grep -c '^Deferred NEW-'):$(grep -c '^mutation IssueCreate' "$LINEAR_LOG"):$(jq -r '[.issues[] | select(.identifier | startswith("NEW-")) | .attachments[0]] | unique | join(",")' "$LINEAR_DB")" "2:2:https://github.com/acme/app-api/pull/70"
  eq "defer: and noted on the lead" "$("$REG" get rp-a/lead | jq '[.notes[] | select(.kind == "deferred")] | length')" 2
  "$SCRIPTS/defer.sh" rp-a >/dev/null 2>&1; eq "defer: a second run files nothing more" "$(grep -c '^mutation IssueCreate' "$LINEAR_LOG")" 2
  unset FLEET_GH; gcfg
}

teams_suite() {
  local d="$PWD"
  teams_boot; teams_boot_claim; teams_tell; teams_retire; teams_park; teams_hold
  teams_next_revive_respawn; teams_env; teams_catchup; teams_decide; teams_defer
  cd "$d" || true
}
