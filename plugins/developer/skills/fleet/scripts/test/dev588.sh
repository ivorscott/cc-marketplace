#!/usr/bin/env bash
# DEV-588 (4.1.3): the cases for the seven fixes. Sourced by run.sh, which gives it the helpers (ok, eq, check, REG, SCRIPTS,
# the herdr shim, qfresh/qpr/qteam, gcfg). d588 smoke runs the critical subset, d588 full runs every case. Each case builds its
# own state root under $T/d588-<name>; generic names only.
d588_state() { # d588_state <name>: a fresh state root, no herdr agent state
  export FLEET_STATE_DIR="$T/d588-$1" FLEET_REGISTRY="$T/d588-$1/fleet.json" FLEET_INBOX="$T/d588-$1/escalations.jsonl" FLEET_WORKTREES="$T/d588-$1/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; rm -f "$AS"/*
}
d588_agent() { # d588_agent <team/role> <tier> <status> [key=value ...]: a registry row, herdr_ref <team>-<role>
  local n="$1" t="$2" st="$3"; shift 3
  "$REG" add "$(jq -cn --arg n "$n" --arg tier "$t" --arg st "$st" '{name: $n, team: ($n | split("/")[0]), tier: $tier, status: $st,
    herdr_ref: ($n | sub("/"; "-")), pane: ("p" + ($n | sub("/"; "-"))), issue: "DEV-1"}')" >/dev/null
  [ $# -eq 0 ] || "$REG" set "$n" "$@" >/dev/null
}

d588_seed_esc() { # d588_seed_esc <name> <escalations json>: put escalations on a row (add starts a row with none)
  jq --arg n "$1" --argjson e "$2" '.agents[$n].escalations = $e | .agents[$n].escalation = "P1" | .agents[$n].status = "Needs input"' "$FLEET_REGISTRY" >"$FLEET_REGISTRY.tmp" && mv "$FLEET_REGISTRY.tmp" "$FLEET_REGISTRY"
}

d588_escalation_ids() {
  d588_state esc
  d588_agent build-x/lead Lead Working; d588_agent build-y/lead Lead Working
  export FLEET_NOW=2026-10-29T10:00:00Z
  "$REG" escalate build-x/lead P1 "which one?" a b >/dev/null 2>&1; "$REG" escalate build-y/lead P1 "which other?" >/dev/null 2>&1
  "$REG" escalate build-x/lead P2 "and another" >/dev/null 2>&1
  eq "dev588-2 escalate: three escalations in one second on two agents have three distinct ids" \
    "$("$REG" escalations | jq -r '[.[].id] | unique | length')" 3
  eq "dev588-2 escalate: the ids count up per second across agents" "$("$REG" escalations | jq -r '[.[].id] | sort | join(",")')" \
    "20261029T100000Z-1,20261029T100000Z-2,20261029T100000Z-3"
  id_y="$("$REG" escalations --team build-y | jq -r '.[0].id')"
  "$REG" resolve build-y/lead "$id_y" --note done >/dev/null 2>&1
  eq "dev588-2 resolve: one id closes one agent's escalation and leaves the other agent's open" \
    "$("$REG" escalations --open | jq -r '[.[].name] | sort | join(",")')" "build-x/lead,build-x/lead"
  # a legacy row (no id) still resolves by its `at`, and its derived id does not collide with a new one
  d588_agent build-z/lead Lead Working; d588_seed_esc build-z/lead '[{"severity":"P1","message":"old","at":"2026-10-29T10:00:00Z"}]'
  "$REG" escalate build-z/lead P2 "new" >/dev/null 2>&1
  eq "dev588-2 escalate: a legacy id-less row counts, so the next id does not repeat" "$("$REG" escalations --team build-z | jq -r '[.[].id] | unique | length')" 2
  "$REG" resolve build-z/lead 2026-10-29T10:00:00Z >/dev/null 2>&1
  eq "dev588-2 resolve: a legacy escalation still resolves by its at" "$("$REG" escalations --team build-z | jq -r '[.[] | select(.resolved_at == null)] | length')" 1
  unset FLEET_NOW
}

d588_bare_team() {
  d588_state tell
  d588_agent build-x/lead Lead Working herdr_ref=x-lead; d588_agent build-x/builder Worker Idle herdr_ref=x-builder
  out="$("$SCRIPTS/tell.sh" build-x "focus on tokens" 2>&1)"; rc=$?
  eq "dev588-3 tell: a bare team name reaches the team's lead" "$rc:$(told "$out"):$(printf '%s' "$out" | grep -c 'build-x/lead')" "0:true:1"
  echo gone >"$AS/no-such-team"; out="$("$SCRIPTS/tell.sh" no-such-team "x" 2>&1)"; rc=$?
  eq "dev588-3 tell: an unknown name gets no respawn advice" "$rc:$(printf "%s" "$out" | grep -c Respawn)" "2:0"
  echo gone >"$AS/no-such-team"; out="$("$SCRIPTS/tell.sh" no-such-team "x" 2>&1)"
  eq "dev588-3 tell: and says to run fleet status" "$(printf '%s' "$out" | grep -c 'fleet status')" 1
  echo gone >"$AS/x-builder"; out="$("$SCRIPTS/tell.sh" build-x/builder "x" 2>&1)"; rc=$?
  eq "dev588-3 tell: a registered agent herdr lost still gets the respawn hint" "$rc:$(printf '%s' "$out" | grep -c 'fleet respawn build-x/builder')" "2:1"
  rm -f "$AS"/*
  FLEET_NOW=2026-10-29T11:00:00Z "$REG" escalate build-x/lead P1 "which?" a b >/dev/null 2>&1
  id="$("$REG" escalations --open | jq -r '.[0].id')"
  out="$("$REG" resolve build-x "$id" --note a 2>&1)"; rc=$?
  eq "dev588-3 resolve: a team name closes the escalation open on its lead" "$rc:$("$REG" escalations --open | jq length):$(printf '%s' "$out" | grep -c 'build-x/lead')" "0:0:1"
  # the same id open on two agents of the team (old duplicate ids): the error names both
  d588_agent build-d/lead Lead Working; d588_agent build-d/builder Worker Working
  for n in build-d/lead build-d/builder; do d588_seed_esc $n '[{"id":"dup-1","severity":"P1","message":"m","at":"2026-10-29T09:00:00Z"}]'; done
  out="$("$REG" resolve build-d dup-1 2>&1)"; rc=$?
  eq "dev588-3 resolve: an id open on two agents is an error naming both" "$rc:$(printf '%s' "$out" | grep -c 'build-d/lead, build-d/builder')" "1:1"
  out="$("$REG" note build-x decision "x" 2>&1)"
  eq "dev588-3 registry: a team name where an agent is wanted says to use its lead that wants an agent" "$(printf '%s' "$out" | grep -c "'build-x' is a team; did you mean 'build-x/lead'")" "1"
}

d588_notices() {
  d588_state ntc
  local A=https://github.com/o/r/pull/1 B=https://github.com/o/r/pull/2
  d588_agent build-x/lead Lead Working "pr=$A"; d588_agent build-y/lead Lead Working "pr=$B"
  nadd() { bash -c '. "$1/common.sh"; notice_add "$2" "$3"' _ "$SCRIPTS" "$1" "$2"; } # nadd <text> <event json>
  nshow() { bash -c '. "$1/common.sh"; notices_show' _ "$SCRIPTS"; }
  ev() { jq -cn --arg t "$1" --arg tm "$2" --arg u "$3" --arg s "${4:-}" '{type: $t, team: $tm, url: $u} + (if $s != "" then {sha: $s} else {} end)'; }
  nadd "READY A" "$(ev pr_ready build-x "$A" aaa1111)"; nadd "CONFLICT A" "$(ev pr_conflicting build-x "$A")"
  eq "dev588-5 notices: a ready notice and a later conflict for the same PR show only the conflict" "$(nshow)" "CONFLICT A"
  nadd "READY A" "$(ev pr_ready build-x "$A" aaa1111)"; nadd "MERGED A" "$(ev pr_merged build-x "$A")"
  eq "dev588-5 notices: a ready notice and a later merge show only the merge" "$(nshow)" "MERGED A"
  nadd "READY A1" "$(ev pr_ready build-x "$A" aaa1111)"; nadd "READY A2" "$(ev pr_ready build-x "$A" bbb2222)"
  eq "dev588-5 notices: two ready notices at different heads show only the newer" "$(nshow)" "READY A2"
  nadd "CONFLICT A" "$(ev pr_conflicting build-x "$A")"; nadd "READY A" "$(ev pr_ready build-x "$A" ccc3333)"
  eq "dev588-5 notices: a conflict followed by a ready (the fix landed) shows only the ready" "$(nshow)" "READY A"
  nadd "READY A" "$(ev pr_ready build-x "$A" aaa1111)"; nadd "CONFLICT B" "$(ev pr_conflicting build-y "$B")"
  eq "dev588-5 notices: another PR's notice leaves a ready one alone" "$(nshow)" "$(printf 'READY A\n\nCONFLICT B')"
  nadd "READY A" "$(ev pr_ready build-x "$A" aaa1111)"; nshow >/dev/null; nadd "CONFLICT A" "$(ev pr_conflicting build-x "$A")"
  eq "dev588-5 notices: one already shown stays shown, and the later conflict still shows" "$(nshow)" "CONFLICT A"
  eq "dev588-5 notices: the head sha is kept in the log" "$(grep -c '"sha":"ccc3333"' "$FLEET_STATE_DIR/notices.log" | sed 's/^[1-9][0-9]*$/kept/')" kept
}

d588_parked_needs() {
  d588_state park
  local A=https://github.com/o/r/pull/1 B=https://github.com/o/r/pull/2 C=https://github.com/o/r/pull/3
  d588_agent pk-a/lead Lead Parked "pr=$A" parked_reason=signed-off; d588_agent pk-a/builder Worker Parked "pr=$A" parked_reason=signed-off
  d588_agent dn-b/lead Lead Done "pr=$B"; d588_agent dn-b/builder Worker Done "pr=$B"
  d588_agent pk-c/lead Lead Parked parked_reason=park
  d588_agent pk-d/lead Lead Parked "pr=$C" parked_reason=park
  rt() { bash -c '. "$1/common.sh"; shift; render_table "$@"' _ "$SCRIPTS" "$@"; }
  cell() { printf '%s\n' "$1" | awk -F' *\\| *' -v t="$2" '$2 == t {print $7}'; } # the Needs you cell of a team
  Q1="$(jq -cn --arg a "$A" --arg b "$B" '{ready: [{n: 1, url: $a, after: "—"}, {n: 2, url: $b, after: "—"}], not_ready: [], notes: []}')"
  o="$(rt --queue "$Q1")"
  eq "dev588-4 table: a parked signed-off team says what a Done one says" "$(cell "$o" pk-a):$(cell "$o" dn-b)" "merge the PR:merge the PR"
  eq "dev588-4 table: a parked team with no PR stays -, and so does one whose PR is not in the queue" "$(cell "$o" pk-c):$(cell "$o" pk-d)" "-:-"
  Q2="$(jq -cn --arg a "$A" --arg b "$B" '{ready: [{n: 1, url: $b, after: "—"}, {n: 2, url: $a, after: "rebase after #2"}], not_ready: [], notes: []}')"
  o="$(rt --queue "$Q2")"
  eq "dev588-4 table: the queue's after text shows for a parked team" "$(cell "$o" pk-a)" "rebase after #2"
  Q3="$(jq -cn --arg a "$A" --arg b "$B" '{ready: [{n: 1, url: $a, after: "—"}, {n: 2, url: $b, after: "merge after #1"}], not_ready: [], notes: []}')"
  eq "dev588-4 table: and for a Done team" "$(cell "$(rt --queue "$Q3")" dn-b)" "merge after #1"
  o="$(rt)"
  eq "dev588-4 table: with no queue a parked team shows merge the PR when it was parked at sign-off" "$(cell "$o" pk-a):$(cell "$o" pk-d)" "merge the PR:-"
  eq "dev588-4 table: the State column still says Parked" "$(printf '%s\n' "$o" | awk -F' *\\| *' '$2 == "pk-a" {print $6}')" "Parked"
}

. "$HERE/dev588-status.sh"
. "$HERE/dev588-retire.sh"

d588_installs() {
  d588_state inst; d588_agent n1/lead Lead Working
  hr() { bash -c '. "$1/common.sh"; house_rules n1/lead' _ "$SCRIPTS"; }
  gcfg
  eq "dev588 installs: unset, today's install text stays word for word" \
    "$(hr | grep -cF -- "$(grep '^- Installing is allowed' "$SCRIPTS/../rules/house.md")"):$(hr | grep -c 'Install what the work needs yourself')" "1:0"
  gcfg 'installs = "allow"'
  eq "dev588 installs: allow, the rule says to install, list each install and commit a dependency with its lockfile" \
    "$(hr | grep -c 'Install what the work needs yourself. List each install in your report (what, where, why). A new project dependency goes in its own commit together with its lockfile change'):$(hr | grep -c 'an approved install is run by the owner')" "1:0"
  gcfg 'installs = "deny"'
  eq "dev588 installs: any other value is the default" "$(hr | grep -c 'an approved install is run by the owner')" 1
  gcfg
}

d588_version() {
  eq "dev588 version: plugin.json reads 4.1.3, and the README has its What changed section" \
    "$(jq -r .version "$SCRIPTS/../../../.claude-plugin/plugin.json"):$(grep -c '^## What changed in 4.1.3' "$SCRIPTS/../README.md")" "4.1.3:1"
}

d588_smoke() { # the critical cases, CI
  d588_version
  d588_installs
  d588_escalation_ids
  d588_bare_team
  d588_notices
  d588_parked_needs
  d588_all_machines
  d588_conflict_catchup
  d588_retire
  d588_revive
  d588_slots
}
d588_full() { # every case
  d588_smoke
  d588_summary_publish
}
