#!/usr/bin/env bash
# 4.2.0: the cases for fleet run and its parts. Sourced by run.sh, which gives it the helpers (ok, eq, check, REG,
# SCRIPTS, the herdr shim, gcfg, rfix, rterms). v420_smoke runs the critical subset (CI), v420_full every case. Each
# case builds its own state root under $T/v420-<name>; generic names only.
v420_state() { # v420_state <name>: a fresh state root, no herdr agent state, no config
  export FLEET_STATE_DIR="$T/v420-$1" FLEET_REGISTRY="$T/v420-$1/fleet.json" FLEET_INBOX="$T/v420-$1/escalations.jsonl" FLEET_WORKTREES="$T/v420-$1/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; rm -f "$AS"/*; gcfg
}

v420_redact_gate() { # the redact check gates only public repos
  v420_state redact
  local R="$T/v420-redact-repo" S="$T/v420-redact-terms" out rc
  rfix "$R"; rterms "$S"; git -C "$R" remote add origin https://github.com/acme/app.git
  printf '#!/usr/bin/env bash\ncase "$*" in "repo view acme/app"*) [ -n "${GH_VIS:-}" ] || exit 1; echo "$GH_VIS" ;; *) exit 1 ;; esac\n' >"$T/v420-gh"; chmod +x "$T/v420-gh"
  rr() { (cd "$R" && FLEET_GH="$T/v420-gh" FLEET_STATE_DIR="$S" "$SCRIPTS/redact-check.sh" --range main..feat 2>/dev/null); echo "rc=$?"; }
  eq "v420 redact: a public repo is checked" "$(GH_VIS=PUBLIC rr | paste -sd' ' -)" "Redact check main..feat: 1 matches. rc=1"
  eq "v420 redact: a private repo is skipped, exit 0, even with a match in the range" "$(GH_VIS=PRIVATE rr | paste -sd' ' -)" "Redact check main..feat: skipped (private repo). rc=0"
  eq "v420 redact: an internal repo is skipped too" "$(GH_VIS=INTERNAL rr | paste -sd' ' -)" "Redact check main..feat: skipped (private repo). rc=0"
  eq "v420 redact: a visibility gh cannot read counts as public" "$(GH_VIS='' rr | paste -sd' ' -)" "Redact check main..feat: 1 matches. rc=1"
  gcfg 'public_repos = ["acme/app"]'
  eq "v420 redact: public_repos wins over what gh says" "$(GH_VIS=PRIVATE rr | paste -sd' ' -)" "Redact check main..feat: 1 matches. rc=1"
  gcfg 'private_repos = ["acme/app"]'
  eq "v420 redact: private_repos is read before gh is asked" "$(GH_VIS='' rr | paste -sd' ' -)" "Redact check main..feat: skipped (private repo). rc=0"
  gcfg
  rm -rf "$S/private"
  eq "v420 redact: a public repo with no terms file is still exit 2, never clean" "$(GH_VIS=PUBLIC rr | tail -1)" "rc=2"
  eq "v420 redact: a private repo needs no terms file" "$(GH_VIS=PRIVATE rr | tail -1)" "rc=0"
}

v420_run_init() { # fleet run init writes the [run] profile; a re-run shows the saved answers as defaults
  v420_state init
  local C="$FLEET_CONFIG_DIR/config.toml" out rc
  printf '# my notes\nmax_teams = 5\nlabel_prefix = "fleet:"\n\n[context_window]\n"claude-opus-5-5" = 200000\n' >"$C"
  out="$("$SCRIPTS/run.sh" init </dev/null 2>&1)"; rc=$?
  eq "v420 run init: without a terminal it refuses and lists the questions, writing nothing" \
    "$rc:$(printf '%s' "$out" | grep -c 'Teams to keep running'):$(grep -c '^\[run\]' "$C")" "1:1:0"
  printf '2\nparent DEV-9\n\n\nallow\n\n20\n\n07:30\n17:00\n' >"$T/v420-answers"
  out="$(FLEET_RUN_ANSWERS="$T/v420-answers" "$SCRIPTS/run.sh" init 2>&1)"; rc=$?
  eq "v420 run init: scripted answers are saved to [run], and the reply says so" "$rc:$(printf '%s' "$out" | tail -1)" "0:Run profile saved: 2 teams (2 can run), installs allow. Written to $C."
  eq "v420 run init: the profile holds the answers and the defaults" \
    "$(bash -c '. "$1/common.sh"; printf "%s|%s|%s|%s|%s|%s" "$(run_int teams 0)" "$(run_str work x)" "$(run_str order x)" "$(run_int merge_push_mins 0)" "$(run_str report_at x)" "$(run_str stop x)"' _ "$SCRIPTS")" \
    "2|parent:DEV-9|critical-path|20|07:30|17:00"
  eq "v420 run init: max_teams follows the team count, installs is allowed, and the rest of the file is as it was" \
    "$(grep -c '^max_teams = 2$' "$C"):$(grep -c '^max_teams = 5' "$C"):$(grep -c '^installs = "allow"$' "$C"):$(grep -c '^# my notes$' "$C"):$(grep -c '^label_prefix = "fleet:"$' "$C"):$(grep -c '^"claude-opus-5-5" = 200000$' "$C")" "1:0:1:1:1:1"
  eq "v420 run init: the top-level keys sit above the first table" "$(awk '/^\[/ {t = 1} !t && /^(max_teams|installs)/ {n++} END {print n}' "$C")" 2
  eq "v420 run show: prints the saved answers" "$("$SCRIPTS/run.sh" show | sed -n '1,2p;9,10p' | paste -sd, -)" "teams: 2,work: parent DEV-9,report_at: 07:30,stop: 17:00"
  printf '\n\n\n\n\n\n\n\n\n\n' >"$T/v420-answers"; cp "$C" "$T/v420-before"
  FLEET_RUN_ANSWERS="$T/v420-answers" "$SCRIPTS/run.sh" init >"$T/v420-out" 2>&1
  eq "v420 run init: a re-run shows the saved answers as the defaults, and Enter keeps them" "$(grep -c 'Teams to keep running \[2\]' "$T/v420-out"):$(grep -c 'Morning report time (local, HH:MM) \[07:30\]' "$T/v420-out"):$(cmp -s "$C" "$T/v420-before" && echo same)" "1:1:same"
  printf 'x\n' >"$T/v420-answers"; FLEET_RUN_ANSWERS="$T/v420-answers" "$SCRIPTS/run.sh" init >/dev/null 2>&1
  eq "v420 run init: an answer that is not one is refused, and the profile stays" "$?:$(cmp -s "$C" "$T/v420-before" && echo same)" "1:same"
  printf '3\nanything\ncritical-path\nwhole-first\nask\n10\n15\n10\n08:00\nnever\n' >"$T/v420-answers"
  FLEET_RUN_ANSWERS="$T/v420-answers" "$SCRIPTS/run.sh" init >/dev/null 2>&1
  eq "v420 run init: choosing ask removes installs from the top level" "$(grep -c '^installs' "$C")" 0
  out="$(bash -c '. "$1/common.sh"; config_warn_unknown' _ "$SCRIPTS" 2>&1)"
  eq "v420 run init: every key it writes is listed in config.example.toml (no unknown-key warning)" "$out" ""
  printf '[run]\nbogus = 1\n' >>"$C"
  gold run "$("$SCRIPTS/run.sh" show)"
  eq "v420 run init: an unknown key in [run] is warned about" "$(bash -c '. "$1/common.sh"; config_warn_unknown' _ "$SCRIPTS" 2>&1 | grep -c "unknown key 'bogus' in \[run\]")" 1
  gcfg
}

v420_run_collide() { # a [run] key never answers a top-level reader, and an allowed install passes the guard
  v420_state collide
  local C="$FLEET_CONFIG_DIR/config.toml" BGH="$SCRIPTS/../../../hooks/fleet-bash-guard.sh"
  printf 'max_teams = 4\n\n[run]\nmax_teams = 9\nmachines = 3\novernight = true\nlabel_prefix = "x:"\n' >"$C"
  eq "v420 config: the top-level readers ignore the same keys inside [run]" \
    "$(bash -c '. "$1/common.sh"; printf "%s|%s|%s|%s" "$(cfg_int max_teams 0)" "$(cfg_int machines 1)" "$(cfg_bool overnight false)" "$(cfg_str label_prefix d)"' _ "$SCRIPTS")" "4|1|false|d"
  gcfg
  guard() { jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | FLEET_STATE_DIR="$FLEET_STATE_DIR" FLEET_ROLE=worker FLEET_TEAM=build-ft "$BGH" | jq -r '.hookSpecificOutput.permissionDecision // empty'; }
  eq "v420 installs: before init, a named install is denied" "$(guard 'npm install left-pad')" deny
  printf '3\nanything\ncritical-path\nwhole-first\nallow\n10\n15\n10\n08:00\nnever\n' >"$T/v420-answers"
  FLEET_RUN_ANSWERS="$T/v420-answers" "$SCRIPTS/run.sh" init >/dev/null 2>&1
  eq "v420 installs: after init chose allow, the same install passes the guard" "$(guard 'npm install left-pad'):x" ":x"
  gcfg
}

v420_linear() { # a fake Linear with DEV-1 In Progress (labelled fleet:test) and the extra issues given as a JSON array
  local kf="linear_api""_key"
  export LINEAR_STUB_KEY=KEYFIXTURE-v420 LINEAR_DB="$FLEET_STATE_DIR/linear.json" LINEAR_LOG="$FLEET_STATE_DIR/linear.log" FLEET_CURL="$HERE/linear-stub.sh"
  : >"$LINEAR_LOG"
  jq -n --argjson extra "${1:-[]}" '{team: "T1", states: {Done: "S3", Todo: "S2", Verify: "S4"}, next: 100, labels: [{id: "L0", name: "fleet", description: "", parent: null},
      {id: "L2", name: "fleet:test", description: "heartbeat=2026-10-29T09:55:00Z", parent: {id: "L0", name: "fleet"}}],
    issues: ([{id: "I1", identifier: "DEV-1", team: {id: "T1"}, state: {id: "S1", name: "In Progress"}, labelIds: ["L2"], comments: []}] + $extra)}' >"$LINEAR_DB"
  printf 'KEYFIXTURE-v420\n' >"$FLEET_CONFIG_DIR/$kf"; chmod 600 "$FLEET_CONFIG_DIR/$kf"; gcfg 'linear_writes = "on"'
}
v420_nolinear() { rm -f "$FLEET_CONFIG_DIR/linear_api""_key"; unset LINEAR_STUB_KEY LINEAR_DB LINEAR_LOG FLEET_CURL; gcfg; }

v420_verify() { # Verify only for a real hands-on check; the list, and the expiry
  v420_state verify; export FLEET_NOW=2026-10-29T10:00:00Z
  local o
  v420_linear; "$REG" add '{"name":"vt-a/lead","team":"vt-a","tier":"Lead","status":"Done","herdr_ref":"vt-a-l","pane":"p1","issue":"DEV-1","outcome":"Shipped","summary":"all done"}' >/dev/null
  o="$("$SCRIPTS/retire.sh" vt-a --outcome Shipped --verify 2>/dev/null | head -n 1)"
  eq "v420 verify: --verify with no UNVERIFIED step goes to Done, and the Retired line says so" \
    "$(jq -r '.issues[0].state.name' "$LINEAR_DB"):$(printf '%s' "$o" | grep -c 'Issue → Done. No UNVERIFIED step, so Done, not Verify.$')" "Done:1"
  v420_linear; "$REG" add '{"name":"vt-b/lead","team":"vt-b","tier":"Lead","status":"Done","herdr_ref":"vt-b-l","pane":"p2","issue":"DEV-1","outcome":"Shipped","summary":"merged; UNVERIFIED: a live run against the vendor"}' >/dev/null
  "$SCRIPTS/retire.sh" vt-b --outcome Shipped --verify >/dev/null 2>&1
  eq "v420 verify: --verify with an UNVERIFIED step in a row's summary lands in Verify" "$(jq -r '.issues[0].state.name' "$LINEAR_DB")" Verify
  # the list: ages, the line to check, and the expiry
  v420_linear '[{"id":"I2","identifier":"DEV-2","team":{"id":"T1"},"state":{"id":"S4","name":"Verify"},"labelIds":[],"title":"old one","updatedAt":"2026-10-21T10:00:00Z"},
    {"id":"I3","identifier":"DEV-3","team":{"id":"T1"},"state":{"id":"S4","name":"Verify"},"labelIds":[],"title":"new one","updatedAt":"2026-10-27T10:00:00Z"}]'
  "$REG" add '{"name":"vt-c/lead","team":"vt-c","tier":"Lead","status":"Retired","herdr_ref":"vt-c-l","pane":"p3","issue":"DEV-3","summary":"ok; UNVERIFIED: walk through the form by hand"}' >/dev/null
  o="$("$SCRIPTS/linear.sh" verify-list)"
  eq "v420 verify: verify-list gives age, what to check and the expiry" "$(jq -r '[.[] | "\(.issue):\(.age_days):\(.expiry):\(.check)"] | join("|")' <<<"$o")" \
    "DEV-2:8:ask:see the issue|DEV-3:2:fresh:UNVERIFIED: walk through the form by hand"
  eq "v420 verify: verify-list writes nothing" "$(grep -c '^mutation' "$LINEAR_LOG")" 0
  "$SCRIPTS/linear.sh" verify-sweep >/dev/null
  eq "v420 verify: the first sweep asks once and moves nothing" "$(jq -r '.issues[1].state.name' "$LINEAR_DB"):$(jq -r 'keys | join(",")' "$FLEET_STATE_DIR/verify.asked.json")" "Verify:DEV-2"
  eq "v420 verify: the next list says close" "$("$SCRIPTS/linear.sh" verify-list | jq -r '.[0].expiry')" close
  "$SCRIPTS/linear.sh" verify-sweep >/dev/null
  eq "v420 verify: the next sweep moves it to Done with a comment, and forgets it" \
    "$(jq -r '.issues[1].state.name' "$LINEAR_DB"):$(jq -r '.issues[1].comments | length' "$LINEAR_DB"):$(jq -r 'keys | length' "$FLEET_STATE_DIR/verify.asked.json")" "Done:1:0"
  v420_nolinear; unset FLEET_NOW
}

v420_claims() { # two machines claiming one issue at once: one boots, the other stands down before any agent starts
  v420_state claims; export FLEET_NOW=2026-10-29T10:00:00Z FLEET_CLAIM_SETTLE_SECS=0
  local kf="linear_api""_key" out rc
  race_db() { # race_db <peer's claim time>: the peer's label carries its claim of DEV-1 at that time
    v420_linear
    jq --arg t "$1" '.states["In Progress"] = "S1" | .labels += [{id: "L1", name: "fleet:peera", description: ("heartbeat=2026-10-29T09:59:00Z\nclaimed=DEV-1@" + $t), parent: {id: "L0", name: "fleet"}}]
      | .issues[0].labelIds = [] ' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  }
  race_db 2026-10-29T09:59:59Z
  out="$(LINEAR_STUB_ALSO=fleet:peera "$SCRIPTS/linear.sh" claim DEV-1 2>&1)"; rc=$?
  eq "v420 claim: a rival whose claim is earlier wins: this side stands down (exit 4), takes its label off, and says so" \
    "$rc:$(jq -r '.issues[0].labelIds | join(",")' "$LINEAR_DB"):$(printf '%s' "$out" | grep -c 'stood down on DEV-1: fleet:peera claimed it first.*No agent was started')" "4:L1:1"
  race_db 2026-10-29T10:00:01Z
  out="$(LINEAR_STUB_ALSO=fleet:peera "$SCRIPTS/linear.sh" claim DEV-1 2>&1)"; rc=$?
  eq "v420 claim: with the earlier claim this side keeps it, exit 0" "$rc:$(printf '%s' "$out" | jq -r '.claimed')" "0:true"
  race_db 2026-10-29T10:00:00Z
  LINEAR_STUB_ALSO=fleet:peera "$SCRIPTS/linear.sh" claim DEV-1 >/dev/null 2>&1; rc=$?
  eq "v420 claim: the same second goes to the lowest machine key, so fleet:peera beats fleet:test" "$rc" 4
  race_db 2026-10-29T10:00:00Z
  "$SCRIPTS/linear.sh" claim DEV-1 >/dev/null 2>&1; rc=$?
  eq "v420 claim: no rival label, a plain claim" "$rc" 0
  # next.sh does not move a team when the claim stood down
  v420_state claims2; v420_linear
  race_db 2026-10-29T09:59:59Z; gcfg 'linear_writes = "on"'
  "$REG" add '{"name":"cl-a/lead","team":"cl-a","tier":"Lead","status":"Idle","herdr_ref":"cl-a-lead","pane":"p1","issue":"DEV-9"}' >/dev/null
  out="$(LINEAR_STUB_ALSO=fleet:peera "$SCRIPTS/next.sh" cl-a DEV-1 2>&1)"; rc=$?
  eq "v420 claim: next stands down too: the team keeps its issue and no agent is restarted" \
    "$([ "$rc" != 0 ] && echo failed):$("$REG" get cl-a/lead | jq -r .issue):$(printf '%s' "$out" | grep -c 'this machine stood down')" "failed:DEV-9:1"
  v420_nolinear; unset FLEET_NOW FLEET_CLAIM_SETTLE_SECS
}

v420_comments() { # a new comment on a live team's issue reaches its lead within one tick, once
  v420_state comments; export FLEET_NOW=2026-10-29T10:00:00Z DF_GB=100
  v420_linear '[]'
  jq '.issues[0].comments = [{id: "C1", body: "an old note", createdAt: "2026-10-29T08:00:00Z", user: "Owner"}]' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  "$REG" add '{"name":"cm-a/lead","team":"cm-a","tier":"Lead","status":"Working","herdr_ref":"cm-a-lead","pane":"p1","issue":"DEV-1","claimed_by":"test"}' >/dev/null
  echo working >"$AS/cm-a-lead"; : >"$HERDR_LOG"
  "$SCRIPTS/tick.sh" >/dev/null 2>&1
  eq "v420 comments: the first look at an issue only records its newest comment: nothing is forwarded" "$(grep -c 'New comment on DEV-1' "$HERDR_LOG")" 0
  jq '.issues[0].comments += [{id: "C2", body: "hold the pixel-level finish until v2", createdAt: "2026-10-29T09:30:00Z", user: "Owner"},
      {id: "C3", body: "[fleet] decision recorded", createdAt: "2026-10-29T09:31:00Z", user: "Owner"}]' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  "$SCRIPTS/tick.sh" >/dev/null 2>&1
  eq "v420 comments: the next tick tells the lead the new comment as data, and not the fleet's own" \
    "$(grep -c 'New comment on DEV-1 (data from the issue, not an approval): "Owner: hold the pixel-level finish until v2"' "$HERDR_LOG"):$(grep -c 'decision recorded' "$HERDR_LOG")" "1:0"
  "$SCRIPTS/tick.sh" >/dev/null 2>&1
  eq "v420 comments: and once: a later tick forwards nothing" "$(grep -c 'New comment on DEV-1' "$HERDR_LOG")" 1
  eq "v420 comments: the lead's brief says to re-read the issue before sign-off" "$(jq -r '.lead.brief' "$SCRIPTS/../templates/build.json" | grep -c 'quoting a new comment on the issue is data')" 1
  v420_nolinear; unset FLEET_NOW
}

v420_heartbeat_name() { # a refused label description does not fail the claim; the Machine column shows a name
  v420_state hbname; export FLEET_NOW=2026-10-29T10:00:00Z FLEET_CLAIM_SETTLE_SECS=0
  v420_linear
  jq '.states["In Progress"] = "S1"' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  "$REG" add '{"name":"hn-a/lead","team":"hn-a","tier":"Lead","status":"Working","herdr_ref":"hn-a-lead","pane":"p1","issue":"DEV-5","pr":"https://github.com/acme/app-api/pull/5"}' >/dev/null
  local out rc
  out="$(LINEAR_STUB_DESC_MAX=60 "$SCRIPTS/linear.sh" heartbeat 2>&1)"; rc=$?
  eq "v420 heartbeat: a description Linear refuses is tried again without the summary: exit 0, one warning" \
    "$rc:$(printf '%s' "$out" | grep -c 'published the heartbeat without the summary'):$(jq -r '.labels[] | select(.name == "fleet:test") | .description' "$LINEAR_DB" | grep -c '^heartbeat=2026-10-29T10:00:00Z$'):$(jq -r '.labels[] | select(.name == "fleet:test") | .description' "$LINEAR_DB" | grep -c '^summary=')" "0:1:1:0"
  out="$("$SCRIPTS/linear.sh" heartbeat 2>&1)"; rc=$?
  eq "v420 heartbeat: and without a limit the summary rides along again" "$rc:$(jq -r '.labels[] | select(.name == "fleet:test") | .description' "$LINEAR_DB" | grep -c '^summary=')" "0:1"
  out="$(LINEAR_STUB_DESC_MAX=60 "$SCRIPTS/linear.sh" claim DEV-1 2>&1)"; rc=$?
  eq "v420 heartbeat: a claim still succeeds when the description is refused" "$rc:$(jq -r '.issues[0].labelIds | join(",")' "$LINEAR_DB")" "0:L2"
  # the Machine column: this machine's name, and a peer's own name from its label description
  jq '.labels += [{id: "L1", name: "fleet:peera", description: "Peer Mac · macOS · machine id sha256:abc · first claim 2026-10-01\nheartbeat=2026-10-29T09:55:00Z\nsummary=[{\"t\":\"hn-p\",\"i\":\"DEV-30\",\"s\":\"Working\"}]", parent: {id: "L0", name: "fleet"}}]
    | .issues += [{id: "I30", identifier: "DEV-30", team: {id: "T1"}, state: {id: "S", name: "In Progress"}, labelIds: ["L1"], comments: []}]' "$LINEAR_DB" >"$LINEAR_DB.t" && mv "$LINEAR_DB.t" "$LINEAR_DB"
  gcfg 'linear_writes = "on"' 'machine_name = "Desk Mac"'
  out="$("$SCRIPTS/status.sh" 2>/dev/null)"
  eq "v420 status: the Machine column shows the machine's name, this one's and a peer's, not the key" \
    "$(printf '%s\n' "$out" | grep '^| hn-a ' | cut -d'|' -f3 | tr -d ' '):$(printf '%s\n' "$out" | grep '^| hn-p ' | cut -d'|' -f3 | sed 's/^ //; s/ $//')" "DeskMac:Peer Mac"
  gcfg 'linear_writes = "on"'
  eq "v420 status: without a machine_name, FLEET_MACHINE (the key override) is the name" "$("$SCRIPTS/status.sh" 2>/dev/null | grep '^| hn-a ' | cut -d'|' -f3 | tr -d ' ')" "test"
  v420_nolinear; unset FLEET_NOW FLEET_CLAIM_SETTLE_SECS
}

v420_overlap() { # the overlap check at plan time: files against open PRs and live teams of the same repo only
  v420_state overlap
  local R="$T/v420-ov-repo" O="$T/v420-ov-other" out
  rm -rf "$R" "$O"; mkdir -p "$R/.fleet/plan" "$O"
  git init -q -b main "$R"; git -C "$R" remote add origin https://github.com/acme/app.git
  git init -q -b main "$O"; git -C "$O" remote add origin https://github.com/acme/other.git
  # gh answers `pr list --repo acme/app` with $V420_PRS and any other repo with a PR on the same path
  printf '#!/usr/bin/env bash\ncase "$*" in\n  *"pr list"*"--repo acme/app"*) cat "$V420_PRS" ;;\n  *"pr list"*"--repo acme/other"*) echo '"'"'[{"number":99,"url":"https://github.com/acme/other/pull/99","headRefName":"x","files":[{"path":"src/a.go"}]}]'"'"' ;;\n  *) echo "[]" ;;\nesac\n' >"$T/v420-gh"; chmod +x "$T/v420-gh"
  export FLEET_GH="$T/v420-gh" V420_PRS="$T/v420-prs.json"
  echo '[{"number":7,"url":"https://github.com/acme/app/pull/7","headRefName":"fleet/dev-7-x","files":[{"path":"src/a.go"},{"path":"docs/x.md"}]}]' >"$V420_PRS"
  mkplan() { local t="$1"; shift; { printf 'Plan\n\n## Files:\n'; for f in "$@"; do printf -- '- `%s` (a note)\n' "$f"; done; printf '\nHow to verify: x\n'; } >"$R/.fleet/plan/$t.md"; }
  "$REG" add "$(jq -cn --arg r "$R" '{name:"ov-a/lead",team:"ov-a",tier:"Lead",status:"Working",herdr_ref:"ov-a-lead",pane:"p1",repo:$r,issue:"DEV-1"}')" >/dev/null
  mkplan ov-a src/a.go src/b.go
  out="$("$SCRIPTS/overlap.sh" ov-a)"; gold overlap "$out"
  eq "v420 overlap: a plan that shares much with an open PR in the same repo waits for it" "$(printf '%s' "$out" | head -n 1):$(printf '%s' "$out" | sed -n 2p)" "wait #7:Overlap: #7 touches src/a.go."
  mkplan ov-a src/a.go src/b.go src/c.go src/d.go
  eq "v420 overlap: a small overlap builds now and is marked merge-after" "$("$SCRIPTS/overlap.sh" ov-a | head -n 1)" "merge-after #7"
  mkplan ov-a src/b.go src/c.go
  eq "v420 overlap: no overlap builds at once, even with another team live in the same repo" "$("$SCRIPTS/overlap.sh" ov-a | head -n 1)" "none"
  "$REG" add "$(jq -cn --arg r "$R" '{name:"ov-b/lead",team:"ov-b",tier:"Lead",status:"Working",herdr_ref:"ov-b-lead",pane:"p2",repo:$r,issue:"DEV-2"}')" >/dev/null
  mkplan ov-b src/c.go
  eq "v420 overlap: a live team in the repo with no PR yet is waited on, by name" "$("$SCRIPTS/overlap.sh" ov-a | head -n 1)" "wait team ov-b"
  "$REG" retire ov-b >/dev/null 2>&1; rm -f "$R/.fleet/plan/ov-b.md"
  mkplan ov-a src/a.go src/q.go
  echo '[{"number":99,"url":"https://github.com/acme/app/pull/99","headRefName":"x","files":[{"path":"lib/z.go"}]}]' >"$V420_PRS"
  eq "v420 overlap: the same path in a different repo never counts" "$("$SCRIPTS/overlap.sh" ov-a | head -n 1)" "none"
  out="$(FLEET_PEERS_JSON='[{"machine":"peera","summary":[{"t":"far","s":"Working","f":["acme/other:src/a.go"]}]}]' "$SCRIPTS/overlap.sh" ov-a --json)"
  eq "v420 overlap: another machine's team is read from its published summary, and only its files in this repo" "$(jq -r .answer <<<"$out")" none
  out="$(FLEET_PEERS_JSON='[{"machine":"peera","summary":[{"t":"far","s":"Working","f":["acme/app:src/a.go"]}]}]' "$SCRIPTS/overlap.sh" ov-a --json)"
  eq "v420 overlap: a peer's team on this repo with the same path is an overlap" "$(jq -r '.answer + " " + .ref' <<<"$out")" "wait far (peera)"
  out="$(FLEET_PEERS_JSON='[]' "$SCRIPTS/overlap.sh" "$R/.fleet/plan/ov-a.md" 2>&1)"
  eq "v420 overlap: a plan file path works too" "$(printf '%s' "$out" | head -n 1)" none
  printf 'no block here\n' >"$R/.fleet/plan/ov-a.md"; "$SCRIPTS/overlap.sh" ov-a >/dev/null 2>&1
  eq "v420 overlap: a plan with no Files: block cannot be checked: exit 1, never none" "$?" 1
  # the summary publishes a team's plan files (repo-qualified) while it has no PR
  mkplan ov-a src/a.go src/b.go
  eq "v420 overlap: fleet_summary publishes the plan files of a team with no PR" \
    "$(bash -c '. "$1/common.sh"; fleet_summary' _ "$SCRIPTS" | jq -r '.[0].f | join(",")')" "acme/app:src/a.go,acme/app:src/b.go"
  # tick tells the lead once when the planner is Done
  "$REG" add "$(jq -cn --arg r "$R" '{name:"ov-a/planner",team:"ov-a",tier:"Worker",status:"Done",herdr_ref:"ov-a-planner",pane:"p3",repo:$r,issue:"DEV-1"}')" >/dev/null
  echo '[]' >"$V420_PRS"; echo working >"$AS/ov-a-lead"; : >"$HERDR_LOG"; export FLEET_NOW=2026-10-29T10:00:00Z DF_GB=100
  "$SCRIPTS/tick.sh" >/dev/null 2>&1; "$SCRIPTS/tick.sh" >/dev/null 2>&1
  eq "v420 overlap: tick tells the lead the answer once, when the planner is Done" "$(grep -c 'Overlap check: none' "$HERDR_LOG")" 1
  unset FLEET_GH V420_PRS FLEET_NOW
}

v420_tick() { # run one tick at a fixed time; the events it printed
  FLEET_NOW="$1" ${V420_X:+bash -x} "$SCRIPTS/tick.sh" 2>>"${V420_ERR:-/dev/null}"
}
v420_evn() { # v420_evn <events json> <type>: how many events of the type
  printf '%s' "${1:-[]}" | jq -r --arg t "$2" '[.[]? | select(.type == $t)] | length' 2>/dev/null || echo 0
}

v420_usage() { # a usage limit stops new boots, is reported once, and running teams carry on
  v420_state usage; export DF_GB=100
  local tr="$HOME/.claude/projects/v420/usage.jsonl" ev o t0=2026-10-29T10:00:00Z; mkdir -p "$(dirname "$tr")"
  printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"Claude usage limit reached. Your limit will reset at 3pm."}]}}' >"$tr"
  "$REG" add "$(jq -cn --arg t "$tr" '{name:"us-a/builder",team:"us-a",tier:"Worker",status:"Idle",herdr_ref:"us-a-builder",pane:"pus",issue:"DEV-1",transcript:$t}')" >/dev/null
  "$REG" add '{"name":"us-b/lead","team":"us-b","tier":"Lead","status":"Working","herdr_ref":"us-b-lead","pane":"pb","issue":"DEV-2"}' >/dev/null
  echo working >"$AS/us-b-lead"
  "$REG" orchestrator here >/dev/null 2>&1; "$REG" set orchestrator target_teams=3 >/dev/null 2>&1
  ev="$(v420_tick "$t0")"
  eq "v420 usage: agents stopped by a usage limit are reported once, as one usage_limit and no needs_input" "$(v420_evn "$ev" usage_limit):$(v420_evn "$ev" needs_input):$(v420_evn "$ev" slot_free)" "1:0:0"
  eq "v420 usage: the backoff runs 15 minutes" "$(jq -r '.usage_until' "$FLEET_STATE_DIR/tick.state.json")" "$(jq -rn --arg t "$t0" '($t | fromdateiso8601) + 900')"
  ev="$(v420_tick 2026-10-29T10:01:00Z)"
  eq "v420 usage: and not again on the next tick, and still no slot_free: no retry storm" "$(v420_evn "$ev" usage_limit):$(v420_evn "$ev" slot_free)" "0:0"
  o="$(FLEET_NOW=2026-10-29T10:02:00Z "$SCRIPTS/boot.sh" build us "$T" "x" 2>&1)"
  eq "v420 usage: boot refuses during the backoff" "$(printf '%s' "$o" | grep -c "usage limit, so no team starts until 2026-10-29T10:15:00Z")" 1
  eq "v420 usage: the running team is untouched" "$("$REG" get us-b/lead | jq -r .status)" Working
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"back at it"}]}}' >"$tr"; "$REG" set us-a/builder status=Idle >/dev/null
  ev="$(v420_tick 2026-10-29T10:20:00Z)"
  eq "v420 usage: once the agents recover and the backoff ran out, slot_free comes back" "$(v420_evn "$ev" slot_free):$(jq -r '.usage_active' "$FLEET_STATE_DIR/tick.state.json")" "1:false"
  unset DF_GB
}

v420_status_changes() { # one table per window, one batched ready push in merge order
  v420_state status; export DF_GB=100 FLEET_GH="$QD/gh-shim"
  qfresh v420st; export FLEET_STATE_DIR="$QD/state.v420st" FLEET_REGISTRY="$QD/state.v420st/fleet.json"; rm -f "$AS"/*
  local ev t
  "$REG" add '{"name":"st-a/lead","team":"st-a","tier":"Lead","status":"Working","herdr_ref":"st-a-lead","pane":"p1","issue":"DEV-1"}' >/dev/null; echo working >"$AS/st-a-lead"
  ev="$(v420_tick 2026-10-29T10:00:00Z)"
  eq "v420 status: the first tick only records the table: nothing is sent" "$(v420_evn "$ev" status_changed)" 0
  ev="$(v420_tick 2026-10-29T10:30:00Z)"
  eq "v420 status: a quiet stretch produces no status_changed at all" "$(v420_evn "$ev" status_changed)" 0
  for t in 10:31:00 10:32:00 10:33:00; do
    "$REG" add "$(jq -cn --arg n "st-$t" '{name:($n + "/lead"),team:$n,tier:"Lead",status:"Working",herdr_ref:("l" + $n),pane:("p" + $n),issue:"DEV-9"}')" >/dev/null; echo working >"$AS/lst-$t"
    ev="$(v420_tick "2026-10-29T$t""Z")"
    eq "v420 status: the first change after a quiet stretch is sent at once, the ones inside the window wait ($t)" "$(v420_evn "$ev" status_changed)" "$([ "$t" = 10:31:00 ] && echo 1 || echo 0)"
  done
  ev="$(v420_tick 2026-10-29T10:41:00Z)"
  eq "v420 status: the two changes inside the window make one status_changed, at the next window" "$(v420_evn "$ev" status_changed)" 1
  ev="$(v420_tick 2026-10-29T10:42:00Z)"
  eq "v420 status: and nothing more until something changes again" "$(v420_evn "$ev" status_changed)" 0
  # two PRs becoming ready send one batched push, in merge order
  qpr app-api 20 fleet/dev-20-a main 2026-10-29T08:00:00Z '["a.go"]' x; qpr app-api 21 fleet/dev-21-b main 2026-10-29T09:00:00Z '["b.go"]' y
  qteam rd-a app-api 20 DEV-20 aaaaaaa20; qteam rd-b app-api 21 DEV-21 aaaaaaa21
  ev="$(v420_tick 2026-10-29T11:00:00Z)"
  eq "v420 status: two PRs becoming ready send one status_changed carrying both, in merge order" \
    "$(v420_evn "$ev" status_changed):$(printf '%s' "$ev" | jq -r '[.[] | select(.type == "status_changed") | .ready] | first')" "1:2 ready: merge #20, then #21"
  eq "v420 status: the notice is the push text" "$(grep -c 'Ready to merge: 2 ready: merge #20, then #21.' "$FLEET_STATE_DIR/notices.log")" 1
  "$REG" add '{"name":"st-z/lead","team":"st-z","tier":"Lead","status":"Working","herdr_ref":"st-z-lead","pane":"pz","issue":"DEV-30"}' >/dev/null
  ev="$(v420_tick 2026-10-29T11:12:00Z)"
  eq "v420 status: a table change with the same ready set pushes no ready text" "$(printf '%s' "$ev" | jq -r '[.[] | select(.type == "status_changed") | .ready // ""] | first // "none"')" ""
  unset DF_GB FLEET_GH
}

v420_failure_push() { # a failed agent is pushed at once, once, and other teams carry on
  v420_state failpush; export DF_GB=100
  printf '#!/usr/bin/env bash\necho "$1" >>"%s/alerts"\n' "$FLEET_STATE_DIR" >"$T/v420-alert"; chmod +x "$T/v420-alert"
  gcfg "alert_cmd = \"$T/v420-alert\""
  "$REG" add '{"name":"fp-a/builder","team":"fp-a","tier":"Worker","status":"Failed","herdr_ref":"fp-a-builder","pane":"pa","issue":"DEV-1"}' >/dev/null
  "$REG" add '{"name":"fp-b/lead","team":"fp-b","tier":"Lead","status":"Working","herdr_ref":"fp-b-lead","pane":"pb","issue":"DEV-2"}' >/dev/null
  echo working >"$AS/fp-b-lead"; echo idle >"$AS/fp-a-builder"
  FLEET_NOW=2026-10-29T10:00:00Z "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  FLEET_NOW=2026-10-29T10:05:00Z "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  eq "v420 failure: one push for the failed agent, however many ticks" "$(grep -c 'Alert: agent fp-a/builder failed. Run fleet status.' "$FLEET_STATE_DIR/alerts" 2>/dev/null || echo 0)" 1
  eq "v420 failure: the other team is untouched" "$("$REG" get fp-b/lead | jq -r .status)" Working
  gcfg; unset DF_GB
}

v420_quiet() { # a quiet hour of loop ticks prints nothing and wakes no one
  v420_state quiet; export DF_GB=100
  "$REG" add '{"name":"qh-a/lead","team":"qh-a","tier":"Lead","status":"Working","herdr_ref":"qh-a-lead","pane":"p1","issue":"DEV-1"}' >/dev/null; echo working >"$AS/qh-a-lead"
  local out="" t
  FLEET_NOW=2026-10-29T09:00:00Z "$SCRIPTS/loop-tick.sh" >/dev/null 2>&1
  : >"$FLEET_STATE_DIR/wakes.log" 2>/dev/null || true
  for t in 09:10:00 09:20:00 09:30:00 09:40:00 09:50:00 10:00:00; do out="$out$(FLEET_NOW="2026-10-29T$t""Z" "$SCRIPTS/loop-tick.sh" 2>&1)"; done
  eq "v420 quiet: an hour of loop ticks with nothing changed prints nothing and writes no wake" "$(printf '%s' "$out" | wc -c | tr -d ' '):$(wc -l <"$FLEET_STATE_DIR/wakes.log" | tr -d ' ')" "0:0"
  unset DF_GB
}

v420_fix() { # a fix on an open PR goes over the slot limits; a new issue or a feature team does not
  qfresh v420fix; export FLEET_STATE_DIR="$QD/state.v420fix" FLEET_REGISTRY="$QD/state.v420fix/fleet.json" FLEET_INBOX="$QD/state.v420fix/escalations.jsonl" FLEET_WORKTREES="$QD/state.v420fix/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; rm -f "$AS"/*; git init -q -b main "$QD/repo-rv" 2>/dev/null
  export FLEET_GH="$QD/gh-shim" PROMPT_SEQ=1; gcfg "teams_per_repo = 1" "max_teams = 1"
  local o rc
  v413_agent fx-live/lead Lead Working; "$REG" set fx-live/lead "repo=$QD/repo-rv" >/dev/null; echo working >"$AS/fx-live-lead"
  qpr app-api 90 fleet/dev-90-x main 2026-10-29T08:00:00Z '["a.go"]' x CONFLICTING
  v413_revive_team fx-a Parked 90
  o="$("$SCRIPTS/tell.sh" fx-a "fix the conflict" 2>&1)"; rc=$?
  eq "v420 fix: a parked team whose PR conflicts comes back over max_teams and teams_per_repo, with no FLEET_FORCE" \
    "$rc:$(printf '%s' "$o" | grep -c '(revived)$'):$("$REG" list --team fx-a | jq -r '[.[].fixing] | unique | join(",")')" "0:1:true"
  eq "v420 fix: status counts it apart" "$(DF_GB=100 "$SCRIPTS/status.sh" 2>/dev/null | grep -c ' · 1 fixing$')" 1
  qpr app-api 91 fleet/dev-91-x main 2026-10-29T08:00:00Z '["b.go"]' x
  v413_revive_team fx-b Parked 91; "$REG" signoff fx-b/tester https://github.com/acme/app-api/pull/91 aaaaaaa91 >/dev/null
  o="$("$SCRIPTS/tell.sh" fx-b "back to work" 2>&1)"; rc=$?
  eq "v420 fix: a parked feature team with a healthy PR still respects the limits" \
    "$([ "$rc" != 0 ] && echo refused):$(printf '%s' "$o" | grep -c 'max_teams=1'):$("$REG" list --team fx-b | jq -r '[.[].status] | unique | join(",")')" "refused:1:Parked"
  o="$(DF_GB=100 "$SCRIPTS/boot.sh" build nx "$QD/repo-rv" "a new issue" 2>&1)"; rc=$?
  eq "v420 fix: and a new issue is refused while the fix does not use a slot but the live team does" "$([ "$rc" != 0 ] && echo refused):$(printf '%s' "$o" | grep -c 'max_teams=1')" "refused:1"
  qpr app-api 92 fleet/dev-92-x main 2026-10-29T08:00:00Z '["c.go"]' x; jq '.statusCheckRollup = [{__typename: "CheckRun", status: "COMPLETED", conclusion: "FAILURE"}]' "$QGHD/app-api-92.json" >"$QD/f.json" && mv "$QD/f.json" "$QGHD/app-api-92.json"
  v413_revive_team fx-c Done 92
  "$SCRIPTS/tell.sh" fx-c "fix the red CI" >/dev/null 2>&1
  eq "v420 fix: red CI on an open PR is a fix too" "$("$REG" list --team fx-c | jq -r '[.[].fixing] | unique | join(",")')" true
  qpr app-api 93 fleet/dev-93-x main 2026-10-29T08:00:00Z '["d.go"]' x
  v413_revive_team fx-d Done 93; "$REG" signoff fx-d/tester https://github.com/acme/app-api/pull/93 bbbbbbb93 >/dev/null
  "$SCRIPTS/tell.sh" fx-d "head moved" >/dev/null 2>&1
  eq "v420 fix: so is a head the tester has not signed" "$("$REG" list --team fx-d | jq -r '[.[].fixing] | unique | join(",")')" true
  eq "v420 fix: none of the fixes took a slot" "$(bash -c '. "$1/common.sh"; live_team_count' _ "$SCRIPTS")" 1
  "$SCRIPTS/park.sh" fx-a >/dev/null 2>&1
  eq "v420 fix: parking the team clears the mark" "$("$REG" list --team fx-a | jq -r '[.[].fixing // "none"] | unique | join(",")')" none
  unset PROMPT_SEQ FLEET_GH; gcfg
}

v420_report() { # deferred items become linked issues; the morning report fires at the profile time and lists them
  qfresh v420rp; export FLEET_STATE_DIR="$QD/state.v420rp" FLEET_REGISTRY="$QD/state.v420rp/fleet.json" FLEET_INBOX="$QD/state.v420rp/escalations.jsonl" FLEET_WORKTREES="$QD/state.v420rp/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR" "$QD/rpcwd"; rm -f "$AS"/*
  export FLEET_GH="$QD/gh-shim" DF_GB=100 TZ=UTC
  local o ev body="Fixes DEV-1

Deferred:
- review the onboarding copy
- decide on the export name

Done."
  v420_linear '[{"id":"I2","identifier":"DEV-2","team":{"id":"T1"},"state":{"id":"S4","name":"Verify"},"labelIds":[],"title":"old one","updatedAt":"2026-10-20T10:00:00Z"}]'
  "$REG" add "$(jq -cn --arg c "$QD/rpcwd" '{name: "orchestrator", team: "orchestrator", tier: "Orchestrator", status: "Working", herdr_ref: "om", pane: "pom", cwd: $c}')" >/dev/null
  qpr app-api 70 fleet/dev-1-x main 2026-10-29T08:00:00Z '["a.go"]' "$body"
  qteam rp-a app-api 70 DEV-1 aaaaaaa70; "$REG" add '{"name":"rp-a/lead","team":"rp-a","tier":"Lead","status":"Working","herdr_ref":"rp-a-lead","pane":"plead","issue":"DEV-1","pr":"https://github.com/acme/app-api/pull/70"}' >/dev/null
  o="$("$SCRIPTS/defer.sh" rp-a 2>&1)"; gold defer "$(printf '%s' "$o" | sed 's/NEW-[0-9]*/NEW-N/')"
  eq "v420 defer: a PR that defers two things files two issues, linked to the PR" \
    "$(printf '%s\n' "$o" | grep -c '^Deferred NEW-'):$(jq -r '[.issues[] | select(.identifier | startswith("NEW-")) | .attachments[0]] | unique | join(",")' "$LINEAR_DB"):$(grep -c '^mutation IssueCreate' "$LINEAR_LOG")" "2:https://github.com/acme/app-api/pull/70:2"
  eq "v420 defer: each is recorded on the lead" "$("$REG" get rp-a/lead | jq -r '[.notes[] | select(.kind == "deferred") | .message | split(" → ")[0]] | join("|")')" "review the onboarding copy|decide on the export name"
  "$SCRIPTS/defer.sh" rp-a >/dev/null 2>&1
  eq "v420 defer: and once: running it again files nothing more" "$(grep -c '^mutation IssueCreate' "$LINEAR_LOG")" 2
  # the morning report: at the profile time only, once a day, with the deferred items and the Verify item
  gcfg 'linear_writes = "on"' '[run]' 'report_at = "08:00"'
  ev="$(TZ=UTC FLEET_NOW=2026-10-29T07:59:00Z "$SCRIPTS/tick.sh" 2>/dev/null)"
  eq "v420 report: before the profile time there is no report" "$(v420_evn "$ev" morning_report)" 0
  ev="$(TZ=UTC FLEET_NOW=2026-10-29T08:00:00Z "$SCRIPTS/tick.sh" 2>/dev/null)"
  local mr="$QD/rpcwd/reports/fleet-morning-2026-10-29.md"
  eq "v420 report: at the profile time it is written and woken with, once" "$(v420_evn "$ev" morning_report):$(head -n 1 "$mr")" "1:# Morning report 2026-10-29"
  eq "v420 report: Needs your eyes lists each deferred item with its issue" "$(awk '/^## Needs your eyes/ {on = 1; next} /^## / {on = 0} on' "$mr" | grep -c 'deferred (rp-a/lead): .* → NEW-')" 2
  eq "v420 report: and the Verify item, with what to check and the question" "$(grep -c '^- Verify DEV-2 (8 days old): check see the issue. Still worth checking?' "$mr")" 1
  ev="$(TZ=UTC FLEET_NOW=2026-10-29T09:00:00Z "$SCRIPTS/tick.sh" 2>/dev/null)"
  eq "v420 report: not again the same day" "$(v420_evn "$ev" morning_report)" 0
  eq "v420 report: the Verify item is asked once, not moved" "$(jq -r '.issues[] | select(.identifier == "DEV-2") | .state.name' "$LINEAR_DB"):$(jq -r 'keys | join(",")' "$FLEET_STATE_DIR/verify.asked.json")" "Verify:DEV-2"
  ev="$(TZ=UTC FLEET_NOW=2026-10-30T08:00:00Z "$SCRIPTS/tick.sh" 2>/dev/null)"
  eq "v420 report: the next day's report announces the close, and the item is Done with a comment" \
    "$(v420_evn "$ev" morning_report):$(grep -c 'No answer since the last report: moved to Done' "$QD/rpcwd/reports/fleet-morning-2026-10-30.md"):$(jq -r '.issues[] | select(.identifier == "DEV-2") | .state.name' "$LINEAR_DB"):$(jq -r '.issues[] | select(.identifier == "DEV-2") | .comments | length' "$LINEAR_DB")" "1:1:Done:1"
  v420_nolinear; unset FLEET_GH DF_GB TZ
}

v420_run_start() { # fleet run start reads the profile and asks nothing; the stop condition ends it; the rules come back from the profile
  v420_state runstart; export TZ=UTC DF_GB=100; unset HERDR_PANE_ID
  local C="$FLEET_CONFIG_DIR/config.toml" out rc
  "$REG" add '{"name":"orchestrator","team":"orchestrator","tier":"Orchestrator","status":"Working","herdr_ref":"om","pane":"pom"}' >/dev/null
  out="$("$SCRIPTS/run.sh" start </dev/null 2>&1)"; rc=$?
  eq "v420 run start: without a profile it says to run init, and starts nothing" "$rc:$(printf '%s' "$out" | grep -c 'Run fleet run init once'):$("$REG" get orchestrator | jq -r '.run_active // "none"')" "1:1:none"
  printf '2\nparent DEV-9\n\n\nallow\n\n20\n\n07:30\n10:00\n' >"$T/v420-answers"
  FLEET_RUN_ANSWERS="$T/v420-answers" "$SCRIPTS/run.sh" init >/dev/null 2>&1
  out="$("$SCRIPTS/run.sh" start </dev/null 2>&1)"; rc=$?
  eq "v420 run start: with a profile it asks nothing and says what it keeps running" "$rc:$(printf '%s' "$out" | head -n 1):$(printf '%s' "$out" | grep -c '?')" "0:Run started: keeping 2 teams on parent DEV-9 work, critical-path order. Loop: not installed (not touched here).:0"
  eq "v420 run start: the Orchestrator row holds the target and the active mark" "$("$REG" get orchestrator | jq -r '[.target_teams, .run_active] | join(",")')" "2,true"
  eq "v420 run start: the rules it prints come from the profile (teams, work, intervals, report time, stop)" \
    "$(printf '%s' "$out" | grep -c 'Keep 2 teams running.*work: parent DEV-9\|every 10 minutes at most\|every 20 minutes at most\|morning report at 07:30\|^- Stop: 10:00')" 3
  eq "v420 run start: and the human-only list is in them" "$(printf '%s' "$out" | grep -c 'merging, production, infrastructure applies, secrets and branch protection')" 1
  eq "v420 run status: running, with the target" "$("$SCRIPTS/run.sh" status)" "Run: running. Target 2 teams, 0 live. Profile: saved."
  (cd "$T" && HERDR_PANE_ID=pt "$REG" orchestrator here >/dev/null 2>&1) || true
  eq "v420 run start: after a context compaction run show gives the rules back, and the mark survives a re-registration" "$("$SCRIPTS/run.sh" show | head -n 1):$("$REG" get orchestrator | jq -r .run_active)" "teams: 2:true"
  FLEET_NOW=2026-10-29T09:59:00Z "$SCRIPTS/tick.sh" >/dev/null 2>&1
  eq "v420 run start: before the stop time it keeps going" "$("$REG" get orchestrator | jq -r '[.target_teams, .run_active] | join(",")')" "2,true"
  FLEET_NOW=2026-10-29T10:00:00Z "$SCRIPTS/tick.sh" >/dev/null 2>&1
  eq "v420 run start: at the stop time it ends quietly: target 0, no longer active" "$("$REG" get orchestrator | jq -r '[.target_teams, (.run_active // "")] | join(",")')" "0,"
  "$SCRIPTS/run.sh" start >/dev/null 2>&1; out="$("$SCRIPTS/run.sh" stop 2>&1)"
  eq "v420 run stop: no new teams, and it says so" "$out:$("$REG" get orchestrator | jq -r .target_teams)" "Run stopped: no new teams start; running teams carry on.:0"
  unset TZ DF_GB
}

v420_decide() { # a lead's escalation is decided, recorded and reported without a human; the human's own is parked
  v420_state decide; export FLEET_NOW=2026-10-29T10:00:00Z
  v420_linear
  jq '.issues[0].identifier = "DEV-1"' "$LINEAR_DB" >/dev/null
  "$REG" add '{"name":"dc-a/lead","team":"dc-a","tier":"Lead","status":"Working","herdr_ref":"dc-a-lead","pane":"p1","issue":"DEV-1"}' >/dev/null; echo working >"$AS/dc-a-lead"
  "$REG" escalate dc-a/lead P1 "which database?" "use postgres" sqlite >/dev/null 2>&1
  local id out; id="$("$REG" escalations --open | jq -r '.[0].id')"; : >"$HERDR_LOG"
  out="$("$SCRIPTS/decide.sh" dc-a "$id" 2>&1)"
  eq "v420 decide: the recommended option is taken and said" "$out" "Decided dc-a/lead: which database? → use postgres."
  gold decide "$out"
  eq "v420 decide: the lead is told, the escalation resolved with the decision, the note kept" \
    "$(grep -c 'Decision (taken for the owner, who can overrule it on the issue): use postgres' "$HERDR_LOG"):$("$REG" escalations --open | jq length):$("$REG" escalations | jq -r '.[0].resolution'):$("$REG" get dc-a/lead | jq -r '[.notes[] | select(.kind == "decision") | .message] | join("|")')" "1:0:use postgres:which database? → use postgres"
  eq "v420 decide: it is commented on the issue, marked as the fleet's" "$(jq -r '.issues[0].comments[0].body' "$LINEAR_DB" | grep -c '^\[fleet\] Decision taken on the owner.s behalf: which database? → use postgres')" 1
  eq "v420 decide: and the morning report lists it under Decisions taken" "$(TZ=UTC "$SCRIPTS/metrics.sh" --morning 2>/dev/null | awk '/^## Decisions taken/ {on = 1; next} /^## / {on = 0} on' | grep -c 'dc-a/lead: which database? → use postgres')" 1
  "$REG" escalate dc-a/lead P1 "may I merge the PR to main myself?" yes no >/dev/null 2>&1
  id="$("$REG" escalations --open | jq -r '.[0].id')"; : >"$HERDR_LOG"
  out="$("$SCRIPTS/decide.sh" dc-a/lead "$id" 2>&1)"
  eq "v420 decide: merging is the human's: parked, not approved, with one push" \
    "$(printf '%s' "$out" | grep -c '^Parked dc-a/lead: .* Left for the owner.$'):$(grep -c '^notification show' "$HERDR_LOG"):$(grep -c 'yes' "$HERDR_LOG"):$("$REG" get dc-a/lead | jq -r '[.notes[] | select(.kind == "parked")] | length')" "1:1:0:1"
  eq "v420 decide: the escalation is closed so nothing waits" "$("$REG" escalations --open | jq length)" 0
  "$REG" escalate dc-a/lead P0 "something is on fire" >/dev/null 2>&1; id="$("$REG" escalations --open | jq -r '.[0].id')"
  eq "v420 decide: a P0 is parked too" "$("$SCRIPTS/decide.sh" dc-a "$id" 2>&1 | grep -c '^Parked ')" 1
  eq "v420 decide: the report lists what was parked under Needs your eyes" "$(TZ=UTC "$SCRIPTS/metrics.sh" --morning 2>/dev/null | awk '/^## Needs your eyes/ {on = 1; next} /^## / {on = 0} on' | grep -c '^- parked for you (dc-a/lead)')" 2
  v420_nolinear; unset FLEET_NOW
}

v420_smoke() { # the critical cases, CI (V420_ONLY="name name" runs just those, to debug one)
  local f
  for f in v420_redact_gate v420_run_init v420_run_collide v420_verify v420_claims v420_comments v420_heartbeat_name v420_overlap v420_usage v420_status_changes v420_failure_push v420_quiet v420_fix v420_report v420_run_start v420_decide; do
    case " ${V420_ONLY:-$f} " in *" $f "*) "$f" ;; esac
  done
}
v420_full() { # every case
  v420_smoke
}
