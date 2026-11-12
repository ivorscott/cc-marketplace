#!/usr/bin/env bash
# 4.2.8 cases (DEV-739 branch cleanup, DEV-736 plain-English rule, DEV-740 takeover repeats). Sourced by run.sh after v427.sh,
# which gives it v420_state, v420_linear, v420_tick, v420_evn and the helpers. No network: the tracker is linear-stub.sh,
# the forge a shim, every git remote a local bare repo, and the Claude settings file a temp file (FLEET_CLAUDE_SETTINGS).

# ---- DEV-740: one takeover, reported once --------------------------------------------------------------------------
v428_events_n() { # v428_events_n <type>: how many events of the type are in the event log
  [ -s "$FLEET_STATE_DIR/events.jsonl" ] || { echo 0; return; }
  jq -s --arg t "$1" '[.[] | select(.type == $t)] | length' "$FLEET_STATE_DIR/events.jsonl"
}
v428_takeover_setup() { # v428_takeover_setup <name> <row status>: a team on DEV-1 whose issue carries another machine's label
  v420_state "$1"; v420_linear '[]'
  v427_dbedit '.labels += [{id: "L3", name: "fleet:other", description: "heartbeat=2026-10-29T09:55:00Z", parent: {id: "L0", name: "fleet"}}] | .issues |= map(if .identifier == "DEV-1" then .labelIds = ["L3"] else . end)'
  "$REG" add "{\"name\":\"$1/lead\",\"team\":\"$1\",\"tier\":\"Lead\",\"status\":\"$2\",\"herdr_ref\":\"$1-lead\",\"pane\":\"p1\",\"issue\":\"DEV-1\"}" >/dev/null
  echo idle >"$AS/$1-lead"
}
v428_takeover() { # a Done row (PR merged, team not retired yet) keeps its claim; its takeover is reported once, not on every tick
  local i n
  v428_takeover_setup tkdone Done
  for i in 1 2 3 4 5 6; do v420_tick "2026-10-29T10:0$i:00Z" >/dev/null; done
  n="$(v428_events_n claim_takeover)"
  eq "v428 takeover: a Done row taken over is logged once in six ticks" "$n" 1
  v428_takeover_setup tklive Working
  for i in 1 2 3 4 5 6; do v420_tick "2026-10-29T10:0$i:00Z" >/dev/null; done
  eq "v428 takeover: a live row taken over is still logged once" "$(v428_events_n claim_takeover)" 1
  # a team whose every PR merged: the event says so, and its notice is a note, not a stop-or-hand-off
  v428_takeover_setup tkmerged Done
  "$REG" set tkmerged/lead pr=https://github.com/acme/app/pull/9 >/dev/null
  printf '{"pr_merged_emitted":["https://github.com/acme/app/pull/9"]}\n' >"$FLEET_STATE_DIR/tick.state.json"
  local ev; ev="$(v420_tick 2026-10-29T10:01:00Z)"
  eq "v428 takeover: a takeover after the PR merged carries merged: true" "$(printf '%s' "$ev" | jq -r '[.[] | select(.type == "claim_takeover") | .merged] | join(",")')" true
  eq "v428 takeover: its logged detail says the PR merged" "$(jq -rs '[.[] | select(.type == "claim_takeover") | .detail] | join(",")' "$FLEET_STATE_DIR/events.jsonl")" "holder fleet:other: PR merged"
  eq "v428 takeover: the notice says nothing is to do and names the retire" \
    "$(bash -c '. "$1/common.sh"; render_line claim_takeover issue=DEV-1 machine=fleet:other team=t1 merged=yes' _ "$SCRIPTS")" "DEV-1 taken over by fleet:other after its PR merged; nothing to do, retire t1."
  eq "v428 takeover: an unmerged takeover keeps the stop-or-hand-off notice" \
    "$(bash -c '. "$1/common.sh"; render_line claim_takeover issue=DEV-1 machine=fleet:other team=t1' _ "$SCRIPTS")" "DEV-1 taken over by fleet:other. Stop or hand off t1."
  v420_nolinear
}

v428_morning() { # an event log that already holds 100 copies of one takeover reads as one line
  v420_state tkmorning; gcfg
  local i
  { for i in $(seq 0 99); do printf '{"at":"2026-10-24T03:%02d:00Z","type":"claim_takeover","team":"","name":"","issue":"DEV-701","detail":"holder fleet:peer"}\n' $((i % 60)); done
    printf '{"at":"2026-10-24T04:00:00Z","type":"claim_takeover","team":"","name":"","issue":"DEV-702","detail":"holder fleet:peer: PR merged"}\n'
    printf '{"at":"2026-10-24T05:00:00Z","type":"claim_lost","team":"t1","name":"t1/lead","issue":"DEV-703"}\n'
    printf '{"at":"2026-10-24T05:01:00Z","type":"claim_lost","team":"t1","name":"t1/lead","issue":"DEV-703"}\n'
  } >"$FLEET_STATE_DIR/events.jsonl"
  local out; out="$(TZ=UTC FLEET_NOW=2026-10-24T09:00:00Z "$SCRIPTS/metrics.sh" --morning 2>/dev/null)"
  eq "v428 morning: 100 copies of one takeover read as one line, the earliest time" "$(printf '%s\n' "$out" | grep -c 'DEV-701: taken over')" 1
  eq "v428 morning: the line carries the holder and the first-seen time" "$(printf '%s\n' "$out" | grep 'DEV-701')" "- DEV-701: taken over by fleet:peer (first seen 03:00)"
  eq "v428 morning: a takeover after the merge says so" "$(printf '%s\n' "$out" | grep 'DEV-702')" "- DEV-702: taken over by fleet:peer (PR already merged) (first seen 04:00)"
  eq "v428 morning: a repeated claim_lost is one line too" "$(printf '%s\n' "$out" | grep -c 'DEV-703')" 1
}

# ---- DEV-739: remote branch cleanup ----------------------------------------------------------------------------------
# Every fixture's origin is a local bare repo; the suite aborts if one is not. gh is a shim that answers `pr list --head`
# from a table; the settings file is a temp file (FLEET_CLAUDE_SETTINGS). Nothing here can reach GitHub or the real settings.
v428_g() { git -c user.email=t@t -c user.name=t "$@"; }
v428_local_only() { # v428_local_only <repo>: abort the whole suite unless the repo's origin is a local directory
  local u; u="$(git -C "$1" remote get-url origin 2>/dev/null || true)"
  case "$u" in /*) [ -d "$u" ] && return 0 ;; esac
  printf 'FATAL v428 fixture: origin of %s is "%s", not a local bare repo; aborting\n' "$1" "$u" >&2; exit 1
}
v428_gh_shim() { # v428_gh_shim <table file>: a gh that answers pr list --head <b> from "<branch> <STATE> <number>" lines
  local sh="$T/v428-gh"
  cat >"$sh" <<'EOF'
#!/usr/bin/env bash
# gh shim: only `pr list --head <b> ...`, from $V428_PRS ("<branch> <STATE> <number>"); V428_GH_FAIL=<branch> fails for it
[ "$1 $2" = "pr list" ] || exit 1
b=""; while [ $# -gt 0 ]; do [ "$1" != --head ] || b="$2"; shift; done
[ "${V428_GH_FAIL:-}" != "$b" ] || exit 1
origin="$(git remote get-url origin)"
tip="$(git --git-dir="$origin" rev-parse -q --verify "refs/heads/$b" 2>/dev/null || true)"
awk -v b="$b" -v tip="$tip" '$1 == b { printf "%s{\"number\":%s,\"state\":\"%s\",\"url\":\"https://github.com/acme/app/pull/%s\",\"headRefOid\":\"%s\"}", (n++ ? "," : "["), $3, $2, $3, ($4 != "" ? $4 : tip) } END { printf "%s\n", (n ? "]" : "[]") }' "$(dirname "$origin")/prs.txt"
EOF
  chmod +x "$sh"; export FLEET_GH="$sh"
}
v428_fixture() { # v428_fixture <name>: sets V428_R (clone), V428_ORIGIN (bare), V428_PRS, V428_SETTINGS (rule allowed)
  local d="$T/v428-$1" b i
  rm -rf "$d"; mkdir -p "$d"
  V428_ORIGIN="$d/origin.git"; V428_R="$d/repo"; V428_PRS="$d/prs.txt"; V428_SETTINGS="$d/settings.json"
  git init -q --bare -b main "$V428_ORIGIN"; git init -q -b main "$V428_R"; git -C "$V428_R" remote add origin "$V428_ORIGIN"
  v428_local_only "$V428_R"
  v428_g -C "$V428_R" commit -q --allow-empty -m init; git -C "$V428_R" push -q origin main 2>/dev/null
  git -C "$V428_R" remote set-head origin main >/dev/null 2>&1 || git -C "$V428_R" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  : >"$V428_PRS"
  push_unmerged() { # push_unmerged <branch>: a branch with one commit that is not in main
    git -C "$V428_R" checkout -q -b "$1" main; echo "$1" >"$V428_R/$(echo "$1" | tr / _).txt"; git -C "$V428_R" add -A; v428_g -C "$V428_R" commit -q -m "work on $1"
    git -C "$V428_R" push -q origin "$1" 2>/dev/null; git -C "$V428_R" checkout -q main
  }
  for i in 1 2 3; do push_unmerged "fleet/dev-1$i-merged"; echo "fleet/dev-1$i-merged MERGED 1$i" >>"$V428_PRS"; done
  for i in 1 2 3; do push_unmerged "fleet/dev-2$i-closed"; echo "fleet/dev-2$i-closed CLOSED 2$i" >>"$V428_PRS"; done
  for i in 1 2 3; do git -C "$V428_R" push -q origin "main:refs/heads/fleet/dev-3$i-inmain" 2>/dev/null; done # no PR, every commit in main
  for b in release/v0.1.0 renovate/a renovate/b; do git -C "$V428_R" push -q origin "main:refs/heads/$b" 2>/dev/null; done
  push_unmerged "fleet/dev-41-open"; echo "fleet/dev-41-open OPEN 41" >>"$V428_PRS"
  push_unmerged "fleet/dev-42-unmerged"                                  # no PR, a commit that is not in main
  push_unmerged "fleet/dev-9-cafebabe-theirs"                            # another machine's branch, its claim live
  git -C "$V428_R" fetch -q origin
  jq -n --arg r "$DELETE_RULE_T" '{theme: "dark", permissions: {allow: ["Bash(ls:*)", $r]}}' >"$V428_SETTINGS"
  export V428_ORIGIN V428_PRS FLEET_CLAUDE_SETTINGS="$V428_SETTINGS"
  v428_gh_shim
}
DELETE_RULE_T='Bash(git push origin --delete:*)'
v428_heads() { git --git-dir="$V428_ORIGIN" for-each-ref --format='%(refname:short)' refs/heads/ | sort | paste -sd, -; }
v428_other_machine() { # DEV-9 is held by another machine's live claim
  v420_linear '[]'
  v427_dbedit '.labels += [{id: "L3", name: "fleet:cafebabe", description: "heartbeat=2026-10-29T09:55:00Z", parent: {id: "L0", name: "fleet"}}] | .issues += [{id: "I9", identifier: "DEV-9", team: {id: "T1"}, state: {id: "S1", name: "In Progress"}, labelIds: ["L3"], comments: []}]'
}

v428_branches() {
  v420_state br; v428_fixture br; v428_other_machine; export FLEET_NOW=2026-10-29T10:00:00Z
  local before out
  before="$(v428_heads)"
  out="$("$SCRIPTS/branches.sh" "$V428_R" --dry-run 2>/dev/null)"
  eq "v428 branches: --dry-run lists the 9 deletable branches" "$(printf '%s\n' "$out" | head -n 1)" "Branches of $(basename "$V428_R"): 9 to delete, 7 kept. Dry run: nothing deleted."
  eq "v428 branches: --dry-run deletes nothing" "$(v428_heads)" "$before"
  eq "v428 branches: the Delete table names merged, closed and fully-merged branches" \
    "$(printf '%s\n' "$out" | sed -n '/^### Delete/,/^### Keep/p' | grep -c '^| fleet/dev-\(1[123]-merged\|2[123]-closed\|3[123]-inmain\) |')" 9
  eq "v428 branches: the Keep table gives each reason" "$(printf '%s\n' "$out" | sed -n '/^### Keep/,$p' | grep '^| ' | sed -n '2,$p' | cut -d'|' -f2,3 | paste -sd';' - | sed 's/  */ /g')" \
    " fleet/dev-41-open | open PR https://github.com/acme/app/pull/41 ; fleet/dev-42-unmerged | no PR, 1 commit(s) not in main ; fleet/dev-9-cafebabe-theirs | fleet:cafebabe holds DEV-9 ; main | default branch ; release/v0.1.0 | release branch ; renovate/a | renovate branch ; renovate/b | renovate branch "
  gold branches "$out"
  # no rule: nothing is deleted and one line says how to add it
  jq -n '{permissions: {allow: ["Bash(ls:*)"]}}' >"$V428_SETTINGS"
  out="$("$SCRIPTS/branches.sh" "$V428_R" 2>/dev/null)"
  eq "v428 branches: without the permission rule nothing is deleted, and the first line says why" "$(v428_heads):$(printf '%s\n' "$out" | head -n 1 | grep -c 'Branch deletes are off: add Bash(git push origin --delete:\*) to permissions.allow')" "$before:1"
  # the rule present: exactly the 9 go
  jq -n --arg r "$DELETE_RULE_T" '{permissions: {allow: [$r]}}' >"$V428_SETTINGS"
  out="$("$SCRIPTS/branches.sh" "$V428_R" 2>/dev/null)"
  eq "v428 branches: a real run deletes exactly those 9" "$(v428_heads)" "fleet/dev-41-open,fleet/dev-42-unmerged,fleet/dev-9-cafebabe-theirs,main,release/v0.1.0,renovate/a,renovate/b"
  eq "v428 branches: and says so" "$(printf '%s\n' "$out" | head -n 1)" "Branches of $(basename "$V428_R"): deleted 9, kept 7."
  eq "v428 branches: each deleted branch is an event for the morning report" "$(v428_events_n branches_deleted)" 9
  # gh failing for a branch keeps it; a refused delete is a warning and a Keep row
  v428_fixture br2; v428_other_machine
  out="$(V428_GH_FAIL=fleet/dev-11-merged "$SCRIPTS/branches.sh" "$V428_R" 2>/dev/null)"
  eq "v428 branches: a branch whose PR state gh cannot read is kept" "$(printf '%s\n' "$out" | grep -c '| fleet/dev-11-merged | could not read PR state |')" 1
  eq "v428 branches: and only it, of the merged ones" "$(v428_heads | tr ',' '\n' | grep -c 'dev-1[0-9]-merged')" 1
  v428_fixture br3; v428_other_machine
  mkdir -p "$V428_ORIGIN/hooks"; printf '#!/bin/sh\nwhile read old new ref; do [ "$ref" = refs/heads/fleet/dev-21-closed ] && [ "$new" = 0000000000000000000000000000000000000000 ] && { echo "denied by hook" >&2; exit 1; }; done; exit 0\n' >"$V428_ORIGIN/hooks/pre-receive"; chmod +x "$V428_ORIGIN/hooks/pre-receive"
  out="$("$SCRIPTS/branches.sh" "$V428_R" 2>/dev/null)"
  eq "v428 branches: a refused delete is listed under Keep and the rest still go" "$(printf '%s\n' "$out" | head -n 1):$(printf '%s\n' "$out" | grep -c '| fleet/dev-21-closed | delete failed |')" "Branches of $(basename "$V428_R"): deleted 8, kept 8.:1"
  eq "v428 branches: never the default branch" "$(v428_heads | tr ',' '\n' | grep -cx main)" 1
  unset FLEET_NOW; v420_nolinear
}

v428_retire() { # retire deletes a team's stale remote branches and names the ones it keeps
  v420_state rt; v428_fixture rt; v428_other_machine; export FLEET_NOW=2026-10-29T10:00:00Z; unset HERDR_PANE_ID
  local R="$V428_R" out rc
  git -C "$R" checkout -q -b fleet/dev-62-work main; echo w >"$R/w.txt"; git -C "$R" add -A; v428_g -C "$R" commit -q -m work; git -C "$R" push -q origin fleet/dev-62-work 2>/dev/null; git -C "$R" checkout -q main
  git -C "$R" fetch -q origin
  rrow() { "$REG" add "$(jq -cn --arg t "$1" --arg r "$R" --arg b "$2" --arg s "$3" --arg pr "${4:-}" '{name: ($t + "/lead"), team: $t, tier: "Lead", status: "Done", herdr_ref: ($t + "-l"), pane: ("p" + $t), repo: $r, branch: $b, outcome: "Shipped"} + (if $pr != "" then {pr: $pr} else {} end) + (if $s != "" then {push_branch: $s} else {} end)')" >/dev/null; }
  rrow rt1 fleet/dev-21-closed "" https://github.com/acme/app/pull/21
  out="$("$SCRIPTS/retire.sh" rt1 2>"$T/v428-rt.err")"
  eq "v428 retire: a team whose PR was closed unmerged loses its remote branch, and the Retired line says so" \
    "$(v428_heads | tr ',' '\n' | grep -c 'dev-21-closed'):$(printf '%s\n' "$out" | head -n 1 | grep -c 'Branches: deleted 1, kept 0\.')" "0:1"
  rrow rt2 fleet/dev-62-work ""
  out="$("$SCRIPTS/retire.sh" rt2 2>"$T/v428-rt.err")"
  eq "v428 retire: a team with unmerged work and no PR keeps its branch, with the reason on the line and on stderr" \
    "$(v428_heads | tr ',' '\n' | grep -c 'dev-62-work'):$(printf '%s\n' "$out" | head -n 1 | grep -c 'Branches: deleted 0, kept 1 (fleet/dev-62-work: no PR, 1 commit(s) not in main)\.'):$(grep -c 'kept branch fleet/dev-62-work: no PR, 1 commit' "$T/v428-rt.err")" "1:1:1"
  # a branch another live team of this machine names is kept; the retiring team itself is exempt
  rrow rt3 fleet/dev-3-x fleet/dev-22-closed; "$REG" set rt3/lead status=Working >/dev/null
  rrow rt4 fleet/dev-22-closed ""
  out="$("$SCRIPTS/retire.sh" rt4 2>/dev/null)"
  eq "v428 retire: a branch a live team names is kept ('team rt3 is live') even with a closed PR" \
    "$(v428_heads | tr ',' '\n' | grep -c 'dev-22-closed'):$(printf '%s\n' "$out" | head -n 1 | grep -c 'fleet/dev-22-closed: team rt3 is live')" "1:1"
  # no permission rule: nothing is deleted, the line says the delete was skipped, and the retire still succeeds
  jq -n '{permissions: {allow: []}}' >"$V428_SETTINGS"
  rrow rt5 fleet/dev-23-closed ""
  out="$("$SCRIPTS/retire.sh" rt5 2>"$T/v428-rt.err")"; rc=$?
  eq "v428 retire: without the rule nothing is deleted, the retire still succeeds, and stderr says deletes are off" \
    "$rc:$(v428_heads | tr ',' '\n' | grep -c 'dev-23-closed'):$(grep -c 'Branch deletes are off' "$T/v428-rt.err"):$(printf '%s\n' "$out" | head -n 1 | grep -c 'dev-23-closed: delete skipped')" "0:1:1:1"
  rrow rt6 fleet/rt6/builder ""
  eq "v428 retire: a retire with no remote branches to report prints the old line" "$("$SCRIPTS/retire.sh" rt6 2>/dev/null | head -n 1)" "Retired rt6 (Shipped): PRs none. Nothing archived."
  unset FLEET_NOW; v420_nolinear
}

v428_tick_sweep() { # tick sweeps each repo in repos once a day, never wakes anyone, and the morning report lists the deletions
  v420_state sw; v428_fixture sw; v428_other_machine; gcfg 'linear_writes = "on"' "repos = [\"$V428_R\"]"
  local ev out n
  ev="$(v420_tick 2026-10-29T10:00:00Z)"
  eq "v428 sweep: the first tick of the day deletes the 9 stale branches" "$(v428_heads | tr ',' '\n' | grep -c 'dev-[0-9]*-\(merged\|closed\|inmain\)$')" 0
  eq "v428 sweep: and logs each as an event, with no wake for it" "$(v428_events_n branches_deleted):$(v420_evn "$ev" branches_deleted)" "9:0"
  git -C "$V428_R" push -q origin "main:refs/heads/fleet/dev-71-inmain" 2>/dev/null
  v420_tick 2026-10-29T11:00:00Z >/dev/null
  eq "v428 sweep: a second tick the same day does nothing" "$(git --git-dir="$V428_ORIGIN" rev-parse -q --verify refs/heads/fleet/dev-71-inmain >/dev/null && echo still)" still
  v420_tick 2026-10-30T10:00:00Z >/dev/null
  eq "v428 sweep: the next day sweeps again" "$(git --git-dir="$V428_ORIGIN" rev-parse -q --verify refs/heads/fleet/dev-71-inmain >/dev/null && echo still || echo gone)" gone
  out="$(TZ=UTC FLEET_NOW=2026-10-30T12:00:00Z "$SCRIPTS/metrics.sh" --morning --since 48h 2>/dev/null)"
  n="$(printf '%s\n' "$out" | sed -n '/^## Branches deleted/,/^## Boots/p' | grep -c '^- repo: fleet/')"
  eq "v428 sweep: the morning report lists the deletions under Branches deleted" "$n" 10
  eq "v428 sweep: with nothing deleted the section is left out" "$(TZ=UTC FLEET_NOW=2026-10-30T12:00:00Z "$SCRIPTS/metrics.sh" --morning --since 1h 2>/dev/null | grep -c 'Branches deleted')" 0
  # without the rule: nothing is deleted, the sweep is not recorded as done, and the warning comes once a day
  v428_fixture sw2; v428_other_machine; gcfg 'linear_writes = "on"' "repos = [\"$V428_R\"]"; jq -n '{permissions: {allow: []}}' >"$V428_SETTINGS"
  : >"$T/v428-sw.err"
  V420_ERR="$T/v428-sw.err" v420_tick 2026-10-29T10:00:00Z >/dev/null; V420_ERR="$T/v428-sw.err" v420_tick 2026-10-29T10:05:00Z >/dev/null
  eq "v428 sweep: without the rule nothing is deleted and the warning is given once that day" "$(v428_heads | tr ',' '\n' | grep -c 'dev-1[0-9]-merged'):$(grep -c 'branch sweep of .* skipped: Branch deletes are off' "$T/v428-sw.err")" "3:1"
  jq -n --arg r "$DELETE_RULE_T" '{permissions: {allow: [$r]}}' >"$V428_SETTINGS"
  v420_tick 2026-10-29T10:10:00Z >/dev/null
  eq "v428 sweep: once the rule is there the same day's next tick sweeps (the skipped one was not recorded)" "$(v428_heads | tr ',' '\n' | grep -c 'dev-1[0-9]-merged')" 0
  v420_nolinear
}

# ---- fleet run init / start: the one place permission settings are edited ------------------------------------------------
v428_answers() { printf '2\nanything\ncritical-path\nwhole-first\nallow\n10\n15\n10\n08:00\nnever\n%s' "$1" >"$T/v428-answers"; } # the 10 old answers, then the branch_delete line ('' = none)
v428_init() { FLEET_NOW=2026-10-29T10:00:00Z FLEET_RUN_ANSWERS="$T/v428-answers" "$SCRIPTS/run.sh" init 2>&1; }
v428_run() {
  v420_state ri; local S="$T/v428-ri-settings/settings.json" out
  local C="$FLEET_CONFIG_DIR"/config.toml
  mkdir -p "$(dirname "$S")"; export FLEET_CLAUDE_SETTINGS="$S"
  rule_n() { jq -r --arg r "$DELETE_RULE_T" '[(.permissions.allow // [])[] | select(. == $r)] | length' "$S"; }
  baks() { ls "$S".bak-* 2>/dev/null | wc -l | tr -d ' '; }
  # no explicit yes: an empty answer in a file (the default is yes), a short file (EOF), and no: the file is never touched
  printf '{"theme":"dark"}\n' >"$S"; cp "$S" "$T/v428-set.orig"
  v428_answers $'\n'; v428_init >/dev/null
  eq "v428 init: a default taken from an answers file (empty line) does not edit settings.json" "$(cmp -s "$S" "$T/v428-set.orig" && echo same):$(baks)" "same:0"
  v428_answers ''; v428_init >/dev/null
  eq "v428 init: EOF before the question does not edit it either" "$(cmp -s "$S" "$T/v428-set.orig" && echo same):$(baks)" "same:0"
  v428_answers $'no\n'; v428_init >/dev/null
  eq "v428 init: an explicit no leaves it byte-identical, with no backup" "$(cmp -s "$S" "$T/v428-set.orig" && echo same):$(baks):$(grep -c '^branch_delete = "no"' "$C")" "same:0:1"
  # an explicit yes: backup, the rule merged into a file with no permissions block, everything else kept
  v428_answers $'yes\n'; out="$(v428_init)"
  eq "v428 init: yes adds the rule to a file with no permissions block, keeps the other keys, and backs the original up" \
    "$(rule_n):$(jq -r .theme "$S"):$(baks):$(cmp -s "$S.bak-20261029" "$T/v428-set.orig" && echo backup-same):$(printf '%s\n' "$out" | grep -cF "Added $DELETE_RULE_T to $S. Backup: $S.bak-20261029.")" "1:dark:1:backup-same:1"
  eq "v428 init: the profile records the answer" "$(grep -c '^branch_delete = "yes"' "$C")" 1
  v428_answers $'y\n'; out="$(v428_init)"
  eq "v428 init: yes again (as y) leaves one rule, no new backup, and says it is already allowed" "$(rule_n):$(baks):$(printf '%s\n' "$out" | grep -c '^Already allowed')" "1:1:1"
  # existing allow entries stay, in order, and a second backup of the same day gets -2
  jq -n '{permissions: {allow: ["Bash(ls:*)", "Read"], deny: ["Bash(rm:*)"]}, model: "x"}' >"$S"; cp "$S" "$T/v428-set.orig2"
  v428_answers $'yes\n'; v428_init >/dev/null
  eq "v428 init: the rule is appended after the existing entries, deny and other keys stay, and the same-day backup gets -2" \
    "$(jq -c '.permissions.allow' "$S"):$(jq -c '.permissions.deny' "$S"):$(jq -r .model "$S"):$(cmp -s "$S.bak-20261029-2" "$T/v428-set.orig2" && echo backup2)" "[\"Bash(ls:*)\",\"Read\",\"$DELETE_RULE_T\"]:[\"Bash(rm:*)\"]:x:backup2"
  # invalid JSON is left untouched, with a warning
  printf '{ not json' >"$S"; cp "$S" "$T/v428-set.bad"
  v428_answers $'yes\n'; out="$(v428_init)"
  eq "v428 init: a settings file that is not valid JSON is left untouched, with a warning" "$(cmp -s "$S" "$T/v428-set.bad" && echo same):$(printf '%s\n' "$out" | grep -c 'not valid settings JSON')" "same:1"
  # a missing file is created
  rm -f "$S" "$S".bak-*; v428_answers $'yes\n'; out="$(v428_init)"
  eq "v428 init: a missing settings file is created with the rule, and nothing to back up" "$(rule_n):$(baks)" "1:0"
  # a symlink stays a symlink, the target gets the rule, the mode stays
  rm -f "$S" "$S".bak-*; printf '{"a":1}\n' >"$T/v428-real.json"; chmod 600 "$T/v428-real.json"; ln -s "$T/v428-real.json" "$S"
  v428_answers $'yes\n'; v428_init >/dev/null
  eq "v428 init: a symlinked settings.json is written through, still a link, mode kept" \
    "$([ -L "$S" ] && echo link):$(jq -r --arg r "$DELETE_RULE_T" '.permissions.allow | index($r) != null' "$T/v428-real.json"):$(ls -l "$T/v428-real.json" | cut -c1-10)" "link:true:-rw-------"
  # an answer that is not yes or no is refused
  v428_answers $'maybe\n'; v428_init >/dev/null; rc=$?
  eq "v428 init: an answer that is not yes or no is refused" "$rc" 1
  # run start: only a check, one fix line, nothing written
  rm -f "$S" "$S".bak-*; "$REG" add '{"name":"orchestrator","team":"orchestrator","tier":"Orchestrator","status":"Working","herdr_ref":"om","pane":"pom"}' >/dev/null
  v428_answers $'no\n'; v428_init >/dev/null
  bash -c '. "$1/common.sh"; cfg_write run branch_delete "\"yes\""' _ "$SCRIPTS"
  export TZ=UTC DF_GB=100; unset HERDR_PANE_ID
  out="$(FLEET_NOW=2026-10-29T08:00:00Z "$SCRIPTS/run.sh" start </dev/null 2>&1)"
  eq "v428 start: with deletes wanted and no rule it prints the one fix line, and writes no settings file" \
    "$(printf '%s\n' "$out" | grep -c "^Branch deletes are off: run fleet run init and answer yes, or add Bash(git push origin --delete:\*) to permissions.allow in $S\.\$"):$([ -e "$S" ] && echo exists || echo none)" "1:none"
  jq -n --arg r "$DELETE_RULE_T" '{permissions: {allow: [$r]}}' >"$S"
  out="$(FLEET_NOW=2026-10-29T08:00:01Z "$SCRIPTS/run.sh" start </dev/null 2>&1)"
  eq "v428 start: with the rule present there is no fix line" "$(printf '%s\n' "$out" | grep -c '^Branch deletes are off: run fleet')" 0
  eq "v428 show: lists branch_delete" "$("$SCRIPTS/run.sh" show | grep -c '^branch_delete: ')" 1
  unset FLEET_CLAUDE_SETTINGS
}

v428_house() { # DEV-736: the rule is in house.md and in the build briefs
  local h="$SCRIPTS/../rules/house.md" t="$SCRIPTS/../templates/build.json" f p
  f="$(grep -n 'Fixes <the issue' "$h" | head -n 1 | cut -d: -f1)"; p="$(grep -n '^- Every PR body has a `## In plain English` section' "$h" | head -n 1 | cut -d: -f1)"
  eq "v428 house: house.md has the In plain English rule right after the Fixes rule" "$((f + 1))" "$p"
  eq "v428 house: and says it comes after the issue-URL lines and before the technical summary, and that the lead posts it on the issue" \
    "$(grep -c 'right after the `Fixes` line and any other issue-URL lines, before the technical summary' "$h"):$(grep -c 'The lead posts the same section as one comment on the issue' "$h")" "1:1"
  eq "v428 house: the lead and builder briefs name the section" "$(jq -r '[.lead.brief, (.workers[] | select(.role == "builder") | .brief)] | map(select(contains("## In plain English"))) | length' "$t")" 2
}

v428_fixround() { # review round: F1 closed PR with later commits, F2 the owner's no, F3 the rule per repo
  local out R1 O1 R2 O2 S1
  # F1: a CLOSED PR whose head is not the branch tip keeps the branch (commits added after it closed); tip == head still goes
  v420_state fr; v428_fixture fr; v428_other_machine
  git -C "$V428_R" push -q origin "main:refs/heads/fleet/dev-24-closed" 2>/dev/null
  git -C "$V428_R" checkout -q -b fleet/dev-25-closed main; echo x >"$V428_R/x25.txt"; git -C "$V428_R" add -A; v428_g -C "$V428_R" commit -q -m later; git -C "$V428_R" push -q origin fleet/dev-25-closed 2>/dev/null; git -C "$V428_R" checkout -q main
  printf 'fleet/dev-24-closed CLOSED 24\nfleet/dev-25-closed CLOSED 25 0000000000000000000000000000000000000001\n' >>"$V428_PRS"; git -C "$V428_R" fetch -q origin
  out="$("$SCRIPTS/branches.sh" "$V428_R" --dry-run 2>/dev/null)"
  eq "v428 fix F1: a closed PR's branch with commits added after it closed is kept, with the reason" "$(printf '%s\n' "$out" | grep -c '| fleet/dev-25-closed | 1 commit(s) added after its PR closed |')" 1
  eq "v428 fix F1: and a closed PR whose head is the branch tip is still deleted" "$(printf '%s\n' "$out" | sed -n '/^### Delete/,/^### Keep/p' | grep -c 'fleet/dev-2[1234]-closed')" 4
  # F2: [run] branch_delete = "no": the tick sweep is silent, retire keeps with the reason, a hand-run fleet branches still deletes
  v420_state fn; v428_fixture fn; v428_other_machine; gcfg 'linear_writes = "on"' "repos = [\"$V428_R\"]" '[run]' 'branch_delete = "no"'
  local before; before="$(v428_heads)"; : >"$T/v428-fn.err"
  V420_ERR="$T/v428-fn.err" v420_tick 2026-10-29T10:00:00Z >/dev/null
  eq "v428 fix F2: with branch_delete = no the tick sweep deletes nothing, warns nothing, records nothing" \
    "$([ "$(v428_heads)" = "$before" ] && echo same):$(grep -c 'branch sweep' "$T/v428-fn.err"):$(jq -r '.branches_swept // {} | length' "$FLEET_STATE_DIR/tick.state.json")" "same:0:0"
  export FLEET_NOW=2026-10-29T10:00:00Z
  "$REG" add "$(jq -cn --arg r "$V428_R" '{name: "fn1/lead", team: "fn1", tier: "Lead", status: "Done", herdr_ref: "fn1-l", pane: "pfn1", repo: $r, branch: "fleet/dev-21-closed", outcome: "Shipped"}')" >/dev/null
  out="$("$SCRIPTS/retire.sh" fn1 2>/dev/null | head -n 1)"
  eq "v428 fix F2: retire deletes nothing and lists the branch as kept with the owner's no" \
    "$(v428_heads | tr ',' '\n' | grep -c 'dev-21-closed'):$(printf '%s\n' "$out" | grep -c 'Branches: deleted 0, kept 1 (fleet/dev-21-closed: branch deletes are off (fleet run init answer: no))')" "1:1"
  "$SCRIPTS/branches.sh" "$V428_R" >/dev/null 2>&1
  eq "v428 fix F2: fleet branches run by hand stays gated on the rule alone and deletes" "$(v428_heads | tr ',' '\n' | grep -c 'dev-21-closed')" 0
  unset FLEET_NOW
  # F3: one team over two repos: the rule is decided per repo (repo 2 has it in its own .claude/settings.json, repo 1 has none)
  v420_state f3; v428_fixture f3a; R1="$V428_R"; O1="$V428_ORIGIN"; S1="$V428_SETTINGS"; v428_fixture f3b; R2="$V428_R"; O2="$V428_ORIGIN"
  jq -n '{permissions: {allow: []}}' >"$S1"; mkdir -p "$R2/.claude"; jq -n --arg r "$DELETE_RULE_T" '{permissions: {allow: [$r]}}' >"$R2/.claude/settings.json"
  export FLEET_CLAUDE_SETTINGS="$S1" FLEET_NOW=2026-10-29T10:00:00Z; v428_other_machine
  local n
  for n in 1 2; do eval "R=\$R$n"
    "$REG" add "$(jq -cn --arg r "$R" --arg n "$n" '{name: ("f3/w" + $n), team: "f3", tier: "Worker", status: "Done", herdr_ref: ("f3-w" + $n), pane: ("pf3" + $n), repo: $r, branch: "fleet/dev-21-closed", outcome: "Shipped"}')" >/dev/null; done
  "$SCRIPTS/retire.sh" f3 >/dev/null 2>&1
  eq "v428 fix F3: repo 1 (no rule) keeps its branch, repo 2 (rule in its own settings) loses it" \
    "$(git --git-dir="$O1" rev-parse -q --verify refs/heads/fleet/dev-21-closed >/dev/null && echo kept):$(git --git-dir="$O2" rev-parse -q --verify refs/heads/fleet/dev-21-closed >/dev/null && echo kept || echo gone)" "kept:gone"
  unset FLEET_NOW; v420_nolinear
}

v428_smoke() { v428_takeover; v428_morning; v428_branches; v428_retire; v428_tick_sweep; v428_run; v428_house; v428_fixround; }
v428_full() { v428_smoke; }
