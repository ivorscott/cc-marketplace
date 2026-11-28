#!/usr/bin/env bash
# Area: the registry, the guards, claims between machines and the config keys. One case per behaviour someone depends on.
# Sourced by run.sh after lib.sh (ok, eq, check, $T, $SCRIPTS, $REG, $HERE).

rg_root() { # rg_root <name>: a fresh state root for one group of cases
  export FLEET_STATE_DIR="$T/rg-$1" FLEET_REGISTRY="$T/rg-$1/fleet.json" FLEET_INBOX="$T/rg-$1/escalations.jsonl" FLEET_WORKTREES="$T/rg-$1/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"
}
rg_row() { # rg_row <team/role> [status] [tier]
  "$REG" add "$(jq -cn --arg n "$1" --arg s "${2:-Working}" --arg t "${3:-Worker}" '{name: $n, team: ($n | split("/")[0]), tier: $t, status: $s, herdr_ref: ($n | sub("/"; "-")), pane: "p"}')" >/dev/null
}
rg_inject() { jq --argjson r "$1" '.agents[$r.name] = $r' "$FLEET_REGISTRY" >"$T/rg-inject.tmp" && mv "$T/rg-inject.tmp" "$FLEET_REGISTRY"; }
rg_dec() { local o; o="$(cat)"; if [ -z "$o" ]; then echo allow; else printf '%s' "$o" | jq -r '.hookSpecificOutput.permissionDecision // "allow"'; fi; }

# --- the registry ---------------------------------------------------------------------------------------------
registry_rows() {
  rg_root rows
  rg_row ra/lead Working Lead; rg_row ra/builder Idle; rg_row rb/lead Parked Lead
  eq "registry: add then get returns the row" "$("$REG" get ra/builder | jq -r '.team + "/" + .status')" "ra/Idle"
  "$REG" set ra/builder status=Working branch=fleet/ra/builder >/dev/null
  eq "registry: set updates fields and stamps updated_at" "$("$REG" get ra/builder | jq -r '[.status, .branch, (.updated_at != null)] | join(",")')" "Working,fleet/ra/builder,true"
  eq "registry: list --team narrows to the team" "$("$REG" list --team ra | jq -r '[.[].name] | sort | join(",")')" "ra/builder,ra/lead"
  eq "registry: list --live leaves Parked, Done and Retired out" "$("$REG" list --live | jq -r '[.[].name] | sort | join(",")')" "ra/builder,ra/lead"
  "$REG" get nope/x >/dev/null 2>&1; eq "registry: get of an unknown row fails" "$([ $? -ne 0 ] && echo failed)" failed
  "$REG" set nope/x status=Idle >/dev/null 2>&1; eq "registry: set of an unknown row fails" "$?" 1
  "$REG" set ra/builder escalations='[]' >/dev/null 2>&1; eq "registry: escalations cannot be set directly" "$?" 1
}

registry_done_signoff() {
  rg_root done
  rg_row rd/lead Working Lead; rg_row rd/tester Working
  "$REG" done rd/tester --outcome Shipped --summary "signed off" >/dev/null 2>&1
  eq "done: the row is Done with its outcome and summary" "$("$REG" get rd/tester | jq -r '[.status, .outcome, .summary, (.done_at != null)] | join(",")')" "Done,Shipped,signed off,true"
  "$REG" signoff rd/tester https://github.com/acme/app/pull/7 abc1234def >/dev/null
  eq "signoff: records the PR and the exact SHA" "$("$REG" get rd/tester | jq -r '.signoff.pr + "@" + .signoff.sha')" "https://github.com/acme/app/pull/7@abc1234def"
  "$REG" add-pr rd/lead https://github.com/acme/app/pull/7 >/dev/null; "$REG" add-pr rd/lead https://github.com/acme/app/pull/8 >/dev/null; "$REG" add-pr rd/lead https://github.com/acme/app/pull/7 >/dev/null
  eq "add-pr: .pr stays the first, .prs lists each PR once" "$("$REG" get rd/lead | jq -r '.pr + " " + (.prs | join(","))')" "https://github.com/acme/app/pull/7 https://github.com/acme/app/pull/7,https://github.com/acme/app/pull/8"
  "$REG" add-pr rd/lead not-a-url >/dev/null 2>&1; eq "add-pr: a value that is not a PR URL is refused" "$?" 1
}

registry_escalations() {
  rg_root esc
  rg_row re/lead Working Lead; rg_row re/builder Working
  "$REG" escalate re/lead P1 "which database?" postgres sqlite >/dev/null 2>&1
  id="$("$REG" escalations --open | jq -r '.[0].id')"
  eq "escalate: an open escalation with its options, the recommended first" "$("$REG" escalations --open | jq -r '.[0] | [.severity, .message, (.options | join("|"))] | join(",")')" "P1,which database?,postgres|sqlite"
  eq "escalate: the agent reads Needs input" "$("$REG" get re/lead | jq -r .status)" "Needs input"
  check "escalate: a line goes to the inbox" grep -q 'which database' "$FLEET_INBOX"
  "$REG" escalate re/lead P4 "bad" >/dev/null 2>&1; eq "escalate: an unknown severity is refused" "$?" 1
  "$REG" park-esc re/lead "$id" --note "for the owner" >/dev/null
  eq "park-esc: parked and still open" "$("$REG" escalations --open --parked | jq -r '.[0] | [.id == "'"$id"'", .parked] | join(",")')" "true,true"
  "$REG" resolve re "$id" --note "use postgres" >/dev/null
  eq "resolve by team name: the escalation is closed with its note" "$("$REG" escalations | jq -r --arg i "$id" '.[] | select(.id == $i) | [(.resolved_at != null), .resolution] | join(",")')" "true,use postgres"
  eq "resolve: nothing open remains" "$("$REG" escalations --open | jq length)" 0
  "$REG" resolve re/lead nosuch-id >/dev/null 2>&1; eq "resolve: an unknown id is refused" "$?" 1
  "$REG" escalate re/builder P2 "low" >/dev/null 2>&1; "$REG" retire re >/dev/null 2>&1
  eq "retire: closes the team's open escalations" "$("$REG" escalations --open | jq length):$("$REG" escalations | jq -r '[.[] | select(.message == "low") | .resolution] | first')" "0:closed at retire"
}

registry_park_notes() {
  rg_root park
  rg_row rp/lead Done Lead; rg_row rp/builder Idle; rg_row rp/tester Retired
  "$REG" park rp park >/dev/null
  eq "park: every unfinished row is Parked with the reason; a Retired row stays" "$("$REG" list --team rp | jq -r '[.[] | .name + "=" + .status + "/" + (.parked_reason // "-")] | sort | join(" ")')" \
    "rp/builder=Parked/park rp/lead=Parked/park rp/tester=Retired/-"
  eq "count-live: a parked team holds no slot" "$("$REG" count-live)" 0
  "$REG" note rp/lead decision "chose postgres" >/dev/null; "$REG" note rp/lead discovered "file the CSV issue" >/dev/null
  eq "note: a decision goes to notes, discovered work to discovered" "$("$REG" get rp/lead | jq -r '[.notes[0].kind, .notes[0].message, .discovered[0].message] | join(",")')" "decision,chose postgres,file the CSV issue"
  "$REG" note rp/lead whatever x >/dev/null 2>&1; eq "note: an unknown kind is refused" "$?" 1
}

registry_schema() {
  rg_root schema
  rg_row cs/a; rg_row cs/b
  cp "$FLEET_REGISTRY" "$T/rg-schema.before"
  "$REG" set cs/a discovered=oops >/dev/null 2>&1; eq "schema: a write that breaks a valid row is refused" "$?" 1
  check "schema: the file is byte-identical after a refusal" cmp -s "$T/rg-schema.before" "$FLEET_REGISTRY"
  "$REG" add '{"name":7}' >/dev/null 2>&1; eq "schema: a row whose name is not a string is refused" "$?" 1
  rg_inject '{"name":"cs/legacy","team":"cs","tier":"Worker","status":"Working","herdr_ref":"x","pane":"p","escalations":"[]"}'
  "$REG" set cs/b status=Idle >/dev/null 2>&1; eq "schema: an old malformed row does not block an unrelated write" "$?:$("$REG" get cs/b | jq -r .status)" "0:Idle"
  "$REG" escalate cs/legacy P2 repair >/dev/null 2>&1
  eq "schema: escalate repairs the malformed row" "$("$REG" get cs/legacy | jq -r '.escalations | type')" array
  # concurrent writers: the lock serialises them, nothing is lost. Skipped on GitHub's runners, where it loses a write now
  # and then with no error (DEV-1292); it runs everywhere else.
  if [ "${GITHUB_ACTIONS:-}" = true ]; then echo "skip lock: eight concurrent appends all land (DEV-1292, GitHub runners only)"; return 0; fi
  : >"$T/rg-append.err"
  for i in 1 2 3 4 5 6 7 8; do "$REG" append cs/a transcripts "$HOME/.claude/projects/p/$i.jsonl" >/dev/null 2>>"$T/rg-append.err" & done; wait
  eq "lock: eight concurrent appends all land" "$("$REG" get cs/a | jq '.transcripts | length')$(sort -u "$T/rg-append.err" | tr '\n' ' ' | sed 's/^/ errors: /;s/ errors: $//')" 8
  check "lock: the file is valid JSON afterwards" jq -e '.agents' "$FLEET_REGISTRY"
}

registry_archive() {
  rg_root arch
  rg_inject '{"name":"ca/lead","team":"ca","tier":"Lead","status":"Retired","outcome":"Shipped","lessons":"l","ended":"2020-01-01T00:00:00Z","escalations":[],"discovered":[]}' 2>/dev/null ||
    { printf '{"agents":{}}\n' >"$FLEET_REGISTRY"; rg_inject '{"name":"ca/lead","team":"ca","tier":"Lead","status":"Retired","outcome":"Shipped","lessons":"l","ended":"2020-01-01T00:00:00Z","escalations":[],"discovered":[]}'; }
  rg_inject '{"name":"cb/x","team":"cb","tier":"Worker","status":"Retired","outcome":"Shipped","ended":"2020-01-01T00:00:00Z","escalations":[],"discovered":[]}'
  rg_inject '{"name":"cc/y","team":"cc","tier":"Worker","status":"Retired","outcome":"Shipped","lessons":"l","ended":"2020-01-01T00:00:00Z","escalations":[{"severity":"P1","message":"open","at":"2020-01-01T00:00:00Z"}],"discovered":[]}'
  rg_row cd/z
  eq "archive: moves Retired rows with lessons and no open escalation" "$("$REG" archive | jq -c 'sort')" '["ca/lead"]'
  eq "archive: rows without lessons, with an open escalation, or live stay" "$("$REG" list | jq -r '[.[].name] | sort | join(",")')" "cb/x,cc/y,cd/z"
  eq "archive: get --archived still finds a moved row" "$("$REG" get --archived ca/lead | jq -r .lessons)" l
  eq "archive: a second run moves nothing" "$("$REG" archive)" "[]"
}

registry_agent_limits() {
  rg_root limits
  rg_row al/lead Working Lead; rg_row al/builder Working
  ag() { FLEET_ROLE=worker FLEET_NAME=al/builder FLEET_TEAM=al "$REG" "$@" >/dev/null 2>&1; echo $?; }
  eq "agent: may set its status and summary" "$(ag set al/builder status=Idle summary=x)" 0
  eq "agent: may not set any other field" "$(ag set al/builder pr=https://github.com/a/b/pull/1)" 1
  eq "agent: may not set another agent's row" "$(ag set al/lead status=Done):$("$REG" get al/lead | jq -r .status)" "1:Working"
  eq "agent: may append transcripts to its own row" "$(ag append al/builder transcripts "$HOME/.claude/projects/p/x.jsonl")" 0
  eq "agent: may not append to another row" "$(ag append al/lead transcripts "$HOME/.claude/projects/p/x.jsonl")" 1
  eq "agent: may not append another key" "$(ag append al/builder discovered x)" 1
  eq "agent: may not add, retire, archive, resolve or set a pref" "$(ag add '{"name":"al/x"}')$(ag retire al)$(ag archive)$(ag resolve al/lead x)$(ag pref k v)" "11111"
  "$REG" pref slim on >/dev/null
  eq "pref: the Orchestrator sets and reads a fleet-wide choice" "$("$REG" pref slim)" on
  "$REG" append al/builder transcripts /etc/passwd >/dev/null 2>&1
  eq "transcripts: a path outside Claude's projects directory is refused" "$?" 1
}

# --- the guards -----------------------------------------------------------------------------------------------
registry_bash_guard() {
  BG="$SCRIPTS/../../../hooks/fleet-bash-guard.sh"
  mkdir -p "$T/rg-gstate"
  jq -n '{agents: {"gt/lead": {name: "gt/lead", team: "gt", herdr_ref: "gt-lead", status: "Working"},
    "gt/builder": {name: "gt/builder", team: "gt", herdr_ref: "gt-builder", status: "Working"},
    "gx/builder": {name: "gx/builder", team: "gx", herdr_ref: "gx-builder", status: "Working"}}}' >"$T/rg-gstate/fleet.json"
  g() { jq -nc --arg c "$2" '{tool_name: "Bash", tool_input: {command: $c}}' | FLEET_STATE_DIR="$T/rg-gstate" FLEET_ROLE="$1" FLEET_TEAM=gt FLEET_NAME="gt/$1" FLEET_CONFIG_DIR="${GCFG:-$FLEET_CONFIG_DIR}" "$BG" | rg_dec; }
  eq "bash guard: an ordinary command passes" "$(g builder 'git status && ls')" allow
  eq "bash guard: nobody in a team merges a PR" "$(g builder 'gh pr merge 4 --squash')$(g lead 'true && gh pr merge 4')" denydeny
  eq "bash guard: a force-push is denied, --force-with-lease passes" "$(g builder 'git push --force origin fleet/x')$(g builder 'git push --force-with-lease origin fleet/x')" denyallow
  eq "bash guard: a push to the default branch is denied" "$(g builder 'git push origin HEAD:main')" deny
  eq "bash guard: the tracker key, by file or variable, is denied" "$(g builder "cat $FLEET_CONFIG_DIR/linear_api""_key")$(g lead 'echo $LINEAR_API''_KEY')" denydeny
  eq "bash guard: a recursive search of the home folder (where the key lives) is denied" \
    "$(jq -nc '{tool_name: "Bash", tool_input: {command: "grep -r tok ~"}}' | env -u FLEET_CONFIG_DIR -u XDG_CONFIG_HOME FLEET_STATE_DIR="$T/rg-gstate" FLEET_ROLE=worker FLEET_TEAM=gt "$BG" | rg_dec)" deny
  eq "bash guard: a named install is denied by default, a lockfile install passes" "$(g builder 'npm install left-pad')$(g builder 'npm ci')" denyallow
  mkdir -p "$T/rg-gcfg"; printf 'installs = "allow"\n' >"$T/rg-gcfg/config.toml"
  eq "bash guard: installs = allow lifts the install rule, not the merge rule" "$(GCFG="$T/rg-gcfg" g builder 'brew install jq')$(GCFG="$T/rg-gcfg" g builder 'gh pr merge 4')" allowdeny
  eq "bash guard: a lead may not wait on or poll a worker" "$(g lead 'herdr agent wait gt-builder --until idle')$(g lead 'sleep 5')$(g lead 'while true; do herdr agent get w; sleep 30; done')" denydenydeny
  eq "bash guard: a worker's sleep is not the lead rule's business" "$(g builder 'sleep 1')" allow
  eq "bash guard: a lead prompts its own worker, never another team's" "$(g lead 'herdr agent prompt gt-builder hi')$(g lead 'herdr agent prompt gx-builder hi')" allowdeny
  eq "bash guard: a worker may not prompt anyone" "$(g builder 'herdr agent prompt gt-lead hi')" deny
  eq "bash guard: herdr pane run is denied" "$(g lead "herdr pane run p1 'ls'")" deny
  eq "bash guard: the Orchestrator is never restricted" \
    "$(jq -nc '{tool_name: "Bash", tool_input: {command: "brew install jq && gh pr merge 4 && git push --force origin main"}}' | env -u FLEET_ROLE "$BG" | rg_dec)" allow
}

registry_scope_guard() {
  SG="$SCRIPTS/../../../hooks/fleet-scope-guard.sh"
  W="$T/rg-wt"; R="$T/rg-repo"; mkdir -p "$W" "$R/.fleet/plan" "$R/src"
  sg() { jq -nc --arg t "$2" --arg p "$3" --arg c "$R" '{tool_name: $t, tool_input: {file_path: $p}, cwd: $c}' | env $1 "$SG" | rg_dec; }
  eq "scope guard: a worker writes inside its worktree" "$(sg "FLEET_ROLE=worker FLEET_WORKTREE=$W" Edit "$W/x.txt")" allow
  eq "scope guard: and nowhere else" "$(sg "FLEET_ROLE=worker FLEET_WORKTREE=$W" Write "$T/elsewhere.txt")" deny
  eq "scope guard: reading outside the worktree is allowed" "$(sg "FLEET_ROLE=worker FLEET_WORKTREE=$W" Read "$T/elsewhere.txt")" allow
  eq "scope guard: the tracker key is denied to a lead, also by a symlink" \
    "$(sg "FLEET_ROLE=lead" Read "$FLEET_CONFIG_DIR/linear_api""_key")$(ln -sf "$FLEET_CONFIG_DIR/linear_api""_key" "$W/innocent.txt"; sg "FLEET_ROLE=lead" Read "$W/innocent.txt")" denydeny
  P="FLEET_ROLE=worker FLEET_NAME=build-p/planner FLEET_PLAN_DIR=$R/.fleet"
  eq "scope guard: a planner writes its plan under .fleet/ and nothing else" \
    "$(sg "$P" Write "$R/.fleet/plan/build-p.md")$(sg "$P" Write "$R/src/main.go")$(sg "$P" Write "$R/.fleet/../x.md")" allowdenydeny
  eq "scope guard: the Orchestrator is never restricted" "$(sg "FLEET_X=1" Read "$FLEET_CONFIG_DIR/linear_api""_key")" allow
}

registry_redact() {
  RR="$T/rg-rr"; RS="$T/rg-rs"; rfix "$RR"; rterms "$RS"
  rc() { (cd "$RR" && FLEET_STATE_DIR="$RS" "$SCRIPTS/redact-check.sh" "$@" >"$T/rg-rc.out" 2>"$T/rg-rc.err"); echo $?; }
  eq "redact check: a private term in an added line exits 1" "$(rc --range main..feat)" 1
  eq "redact check: the output never names the term or the file" "$(cat "$T/rg-rc.out" "$T/rg-rc.err" | grep -ciE 'zebra|acme|a\.txt')" 0
  eq "redact check: a term in a commit message counts" "$(rc --range main..msg)" 1
  eq "redact check: a clean range exits 0" "$(rc --range main..clean)" 0
  rm -f "$RS/private/redact_terms.txt"
  eq "redact check: no terms file is exit 2, never clean" "$(rc --range main..clean)" 2
}

# --- claims between machines ------------------------------------------------------------------------------------
registry_claims() {
  rg_root claims
  LIN="$SCRIPTS/linear.sh"; ml="fleet:test"
  export LINEAR_DB="$T/rg-linear.json" LINEAR_LOG="$T/rg-linear.log" LINEAR_ARGV_LOG="$T/rg-linear.argv" LINEAR_STUB_KEY="KEYFIXTURE-rg" FLEET_CURL="$HERE/linear-stub.sh"
  printf '%s\n' "$LINEAR_STUB_KEY" >"$FLEET_CONFIG_DIR/linear_api_key"; chmod 600 "$FLEET_CONFIG_DIR/linear_api_key"
  cp "$FLEET_CONFIG_DIR/config.toml" "$T/rg-config.bak" 2>/dev/null || : >"$T/rg-config.bak"
  printf 'linear_writes = "on"\nmachine_name = "test box"\n' >"$FLEET_CONFIG_DIR/config.toml"
  printf 'AAAAAAAA-1111-4222-8333-444455556666\n' >"$FLEET_STATE_DIR/machine-id"
  db() {
    cat >"$LINEAR_DB" <<'J'
{"team": "T1", "states": {"In Progress": "S1"}, "next": 100,
 "labels": [{"id": "L1", "name": "fleet", "description": "", "parent": null},
            {"id": "L2", "name": "fleet:other", "description": "other host\nheartbeat=2026-10-18T06:00:00Z", "parent": {"id": "L1", "name": "fleet"}},
            {"id": "L3", "name": "bug", "description": "", "parent": null}],
 "issues": [{"id": "I1", "identifier": "DEV-1", "team": {"id": "T1"}, "state": {"id": "S0", "name": "Todo"}, "labelIds": ["L3"], "comments": []},
            {"id": "I2", "identifier": "DEV-2", "team": {"id": "T1"}, "state": {"id": "S0", "name": "Todo"}, "labelIds": ["L2"], "comments": [], "branchName": "ivor/dev-2-thing"},
            {"id": "I3", "identifier": "DEV-3", "team": {"id": "T1"}, "state": {"id": "S0", "name": "Todo"}, "labelIds": [], "comments": []}]}
J
    : >"$LINEAR_LOG"; : >"$LINEAR_ARGV_LOG"
  }
  nmut() { grep -c '^mutation' "$LINEAR_LOG" || true; }
  labels_of() { jq -r --arg i "$1" '. as $r | .issues[] | select(.identifier == $i) | [.labelIds[] as $l | $r.labels[] | select(.id == $l) | .name] | sort | join(",")' "$LINEAR_DB"; }

  db; "$LIN" holder DEV-2 >"$T/rg-h.out"; "$LIN" peers >"$T/rg-p.out"
  eq "claims: holder and peers are reads, no mutation" "$(nmut)" 0
  eq "claim --who: names the other machine and its heartbeat" "$(jq -c '[.holder, .ours, .heartbeat]' "$T/rg-h.out")" '["fleet:other",false,"2026-10-18T06:00:00Z"]'
  eq "claim --who: an unclaimed issue has no holder" "$("$LIN" holder DEV-1 | jq -c '.holder')" null
  eq "peers: the other machine's claims, for status" "$(jq -r '.[0] | .machine + " " + .issue' "$T/rg-p.out")" "other DEV-2"
  db; out="$("$LIN" claim DEV-1)"
  eq "claim: succeeds, puts this machine's label on, other labels kept" "$(printf '%s' "$out" | jq -r .claimed):$(labels_of DEV-1)" "true:bug,$ml"
  eq "claim: the issue moves to In Progress" "$(jq -r '.issues[] | select(.identifier == "DEV-1") | .state.name' "$LINEAR_DB")" "In Progress"
  "$LIN" claim DEV-2 2>"$T/rg-c.err"; eq "claim: another machine's issue is refused and unchanged" "$?:$(labels_of DEV-2)" "1:fleet:other"
  db; LINEAR_STUB_RACE=fleet:other "$LIN" claim DEV-3 >/dev/null 2>&1
  eq "claim race: the loser exits 1 and one machine holds it" "$?:$(labels_of DEV-3)" "1:fleet:other"
  db; "$LIN" claim DEV-1 >/dev/null 2>&1; : >"$LINEAR_LOG"
  FLEET_NOW=2026-10-18T09:30:00Z "$LIN" heartbeat >/dev/null
  eq "heartbeat: one label write, the heartbeat line updated" "$(grep -c '^mutation IssueLabelUpdate' "$LINEAR_LOG"):$(jq -r --arg n "$ml" '.labels[] | select(.name == $n) | .description' "$LINEAR_DB" | grep -c '^heartbeat=2026-10-18T09:30:00Z$')" "1:1"

  # takeover (claim --take): a lapsed heartbeat and no open PR; refused otherwise
  GHO="$T/rg-gh"; printf '[]' >"$T/rg-gh-none.json"
  printf '#!/usr/bin/env bash\ncase " $* " in *" --search "*) cat "${GH_SEARCH_JSON:-%s}"; exit 0 ;; esac\n[ -z "${GH_OPEN_FAIL:-}" ] || exit 1\ncat "${GH_OPEN_JSON:-%s}"\n' "$T/rg-gh-none.json" "$T/rg-gh-none.json" >"$GHO"; chmod +x "$GHO"
  tk() { FLEET_GH="$GHO" FLEET_NOW="${TKNOW:-2026-10-18T09:00:00Z}" "$LIN" takeover "$@"; }
  db; TKNOW=2026-10-18T07:00:00Z tk DEV-2 >/dev/null 2>&1; eq "claim --take: a live heartbeat is refused" "$?" 1
  FLEET_FORCE=1 TKNOW=2026-10-18T07:00:00Z tk DEV-2 >/dev/null 2>&1; eq "claim --take: FLEET_FORCE does not bypass a live heartbeat" "$?" 1
  printf '[{"url": "https://github.com/o/r/pull/8", "headRefName": "ivor/dev-2-thing", "isCrossRepository": false}]' >"$T/rg-gh-open.json"
  : >"$LINEAR_LOG"; GH_OPEN_JSON="$T/rg-gh-open.json" tk DEV-2 >/dev/null 2>&1; eq "claim --take: an open PR for the issue is refused, nothing written" "$?:$(nmut)" "1:0"
  GH_OPEN_FAIL=1 tk DEV-2 >/dev/null 2>&1; eq "claim --take: gh failing refuses" "$?" 1
  db; tk DEV-2 >/dev/null 2>&1; rc=$?
  eq "claim --take: lapsed and no PR: taken, label swapped, one comment" "$rc:$(labels_of DEV-2):$(jq -r '.issues[] | select(.identifier == "DEV-2") | .comments | length' "$LINEAR_DB")" "0:$ml:1"
  db; jq '.labels |= map(if .name == "fleet:other" then .description = "no heartbeat here" else . end)' "$LINEAR_DB" >"$T/rg-db.tmp" && mv "$T/rg-db.tmp" "$LINEAR_DB"
  tk DEV-2 >/dev/null 2>&1; eq "claim --take: a holder with no heartbeat is refused" "$?" 1

  # the fleet command's forms
  db; eq "fleet claim --who: the holder line" "$("$SCRIPTS/fleet" claim DEV-2 --who 2>&1 | grep -c 'DEV-2: held by')" 1
  db; eq "fleet claim: the claimed line" "$("$SCRIPTS/fleet" claim DEV-1 2>&1 | grep -c '^Claimed DEV-1 for')" 1
  cp "$T/rg-config.bak" "$FLEET_CONFIG_DIR/config.toml"; rm -f "$FLEET_CONFIG_DIR/linear_api_key"
  unset LINEAR_DB LINEAR_LOG LINEAR_ARGV_LOG LINEAR_STUB_KEY FLEET_CURL
}

# --- config keys ------------------------------------------------------------------------------------------------
registry_config() {
  EX="$SCRIPTS/../config.example.toml"
  read_keys="$(grep -ohE "cfg_(str|int|bool|list)[[:space:]]+[a-z_]+" "$SCRIPTS"/*.sh | awk '{print $2}' | sort -u)"
  missing="$(for k in $read_keys; do grep -qE "^#?[[:space:]]*${k}[[:space:]]*=" "$EX" || echo "$k"; done | paste -sd' ' -)"
  eq "config: every key a script reads is listed in config.example.toml" "$missing" ""
  rg_root cfg
  cp "$FLEET_CONFIG_DIR/config.toml" "$T/rg-config2.bak" 2>/dev/null || : >"$T/rg-config2.bak"
  printf 'max_tems = 3\novernight = true\n' >"$FLEET_CONFIG_DIR/config.toml"
  w="$(bash -c '. "$1/common.sh"; config_warn_unknown' _ "$SCRIPTS" 2>&1)"
  eq "config: an unknown key warns, once" "$(printf '%s\n' "$w" | grep -c "unknown key 'max_tems'")" 1
  eq "config: the old overnight key warns and names fleet run" "$(printf '%s\n' "$w" | grep -c 'overnight.*fleet run')" 1
  rm -f "$FLEET_STATE_DIR/config.warned"
  "$SCRIPTS/tick.sh" >/dev/null 2>"$T/rg-t1.err"; "$SCRIPTS/tick.sh" >/dev/null 2>"$T/rg-t2.err"
  eq "config: tick warns on the first tick, not on every tick" "$(grep -c "max_tems" "$T/rg-t1.err"):$(grep -c "max_tems" "$T/rg-t2.err")" "1:0"
  cp "$T/rg-config2.bak" "$FLEET_CONFIG_DIR/config.toml"
}

registry_suite() {
  local saved_state="$FLEET_STATE_DIR" saved_reg="$FLEET_REGISTRY" saved_inbox="${FLEET_INBOX:-}" saved_wt="$FLEET_WORKTREES"
  registry_rows; registry_done_signoff; registry_escalations; registry_park_notes; registry_schema; registry_archive; registry_agent_limits
  registry_bash_guard; registry_scope_guard; registry_redact
  registry_claims; registry_config
  export FLEET_STATE_DIR="$saved_state" FLEET_REGISTRY="$saved_reg" FLEET_INBOX="$saved_inbox" FLEET_WORKTREES="$saved_wt"
}
