#!/usr/bin/env bash
# 4.2.9 cases (DEV-743: fleet hold and unhold). Sourced by run.sh after v428.sh, which gives it the helpers (ok, eq, check,
# gold, REG, SCRIPTS, T, gcfg) and the merge queue fixtures (qfresh, qpr, qteam, q, QD). No network: gh is the queue shim,
# and every PR url is made up.

V429_API=https://github.com/acme/app-api/pull
v429_gh() { FLEET_GH="$QD/gh-shim" "$@"; }
v429_ready() { # v429_ready: the ready PR urls of the queue, as #N, comma-joined
  q | jq -r '[.ready[].url | sub(".*/pull/"; "#")] | join(",")'
}
v429_tick() { rm -f "$FLEET_STATE_DIR/tick.state.json"; FLEET_NOW=2026-10-29T10:00:00Z FLEET_GH="$QD/gh-shim" "$SCRIPTS/tick.sh" 2>/dev/null; }

v429_hold() { # hold and unhold: the file, the replies, the refusals
  qfresh h429a; qpr app-api 7 fleet/dev-7-a main 2026-10-20T10:00:00Z '["a.go"]' x; qpr app-web 7 fleet/dev-8-b main 2026-10-20T10:00:00Z '["b.ts"]' x
  qpr app-api 9 fleet/dev-9-c main 2026-10-20T10:00:00Z '["c.go"]' x
  qteam h1 app-api 7 DEV-7 aaaaaaa7; qteam h2 app-web 7 DEV-8 aaaaaaa7; qteam h3 app-api 9 DEV-9 aaaaaaa9
  local out rc
  out="$("$SCRIPTS/hold.sh" "$V429_API/9" --note "wait for the release" 2>&1)"
  gold hold "$out"
  eq "v429 hold: a PR URL with a note is held, and the file keeps the note" "$(jq -r --arg u "$V429_API/9" '.[$u].note' "$FLEET_STATE_DIR/holds.json")" "wait for the release"
  eq "v429 hold: the registry's #N resolves to the one PR of that number" "$("$SCRIPTS/hold.sh" '#9' --note "second note" >/dev/null 2>&1; jq -r --arg u "$V429_API/9" '.[$u].note' "$FLEET_STATE_DIR/holds.json")" "second note"
  "$SCRIPTS/hold.sh" 9 --note "bare number" >/dev/null 2>&1
  eq "v429 hold: a bare number works and holding again replaces the note, one entry" "$(jq -r 'to_entries | map(.value.note) | join(",")' "$FLEET_STATE_DIR/holds.json")" "bare number"
  "$SCRIPTS/hold.sh" "$V429_API/9" >/dev/null 2>&1; rc=$?
  eq "v429 hold: --note is required" "$rc" 1
  "$SCRIPTS/hold.sh" "$V429_API/9" --note "  " >/dev/null 2>&1; rc=$?
  eq "v429 hold: an empty note is refused too" "$rc" 1
  out="$("$SCRIPTS/hold.sh" '#7' --note x 2>&1)"; rc=$?
  eq "v429 hold: #N that two repos share is refused, naming both" "$rc:$(printf '%s' "$out" | grep -c 'app-api/pull/7, https://github.com/acme/app-web/pull/7')" "1:1"
  out="$("$SCRIPTS/hold.sh" '#404' --note x 2>&1)"; rc=$?
  eq "v429 hold: an unknown #N is refused" "$rc:$(printf '%s' "$out" | grep -c 'no PR #404')" "1:1"
  FLEET_ROLE=builder "$SCRIPTS/hold.sh" "$V429_API/7" --note x >/dev/null 2>&1; rc=$?
  eq "v429 hold: an agent (FLEET_ROLE set) may not hold" "$rc:$(jq -r 'has("https://github.com/acme/app-api/pull/7")' "$FLEET_STATE_DIR/holds.json")" "1:false"
  FLEET_ROLE=builder "$SCRIPTS/hold.sh" unhold "$V429_API/9" >/dev/null 2>&1; rc=$?
  eq "v429 hold: nor may it unhold" "$rc:$(jq -r 'has("'"$V429_API"'/9")' "$FLEET_STATE_DIR/holds.json")" "1:true"
  out="$("$SCRIPTS/fleet" unhold '#9' 2>&1)"
  gold unhold "$out"
  eq "v429 hold: fleet unhold is an alias of hold.sh unhold and clears the file entry" "$(jq -r 'length' "$FLEET_STATE_DIR/holds.json")" 0
  "$SCRIPTS/hold.sh" unhold "$V429_API/9" >/dev/null 2>&1; rc=$?
  eq "v429 hold: unholding a PR that is not held is refused" "$rc" 1
  eq "v429 hold: fleet help lists hold and unhold" "$("$SCRIPTS/fleet" help | grep -c '^| `\(hold\|unhold\)` ')" 2
  eq "v429 hold: hold and unhold are logged" "$(jq -rs '[.[] | select(.type == "hold" or .type == "unhold")] | length' "$FLEET_STATE_DIR/events.jsonl")" 4
}

v429_queue() { # the merge queue: a held PR is on_hold, not ready, not not_ready; its dependent waits for it
  qfresh h429b; qpr app-api 1 fleet/dev-1-a main 2026-10-20T10:00:00Z '["a.go"]' x; qpr app-api 2 fleet/dev-2-b main 2026-10-21T10:00:00Z '["b.go"]' "Merge after #1"
  qpr app-api 3 fleet/dev-3-c main 2026-10-22T10:00:00Z '["c.go"]' x
  qteam q1 app-api 1 DEV-1 aaaaaaa1; qteam q2 app-api 2 DEV-2 aaaaaaa2; qteam q3 app-api 3 DEV-3 aaaaaaa3
  eq "v429 queue: with no hold the three PRs are ready, the dependent after its parent" "$(v429_ready)" "#1,#2,#3"
  "$SCRIPTS/hold.sh" "$V429_API/1" --note "wait for the release" >/dev/null 2>&1
  eq "v429 queue: a held PR is not ready, and the PR that merges after it waits" "$(v429_ready)" "#3"
  eq "v429 queue: it is in on_hold with its note, and in no not_ready" "$(q | jq -r '[.on_hold[] | "\(.url | sub(".*/pull/"; "#"))=\(.note)"] | join(",")'):$(q | jq -r '[.not_ready[] | "\(.url | sub(".*/pull/"; "#"))=\(.missing | join("+"))"] | join(",")')" \
    "#1=wait for the release:#2=waits for app-api #1"
  eq "v429 queue: the queue prints it as On hold with the note, not as Not ready" "$(render_queue_out | grep -c '^On hold: .*pull/1.* - wait for the release$'):$(render_queue_out | grep -c '^Not ready: .*pull/1')" "1:0"
  eq "v429 queue: a hold shows at once, the kept queue is not used past it" "$(FLEET_GH="$QD/gh-shim" bash -c '. "$1/common.sh"; fleet_queue | jq -r "[.on_hold[].url | sub(\".*/pull/\"; \"#\")] | join(\",\")"' _ "$SCRIPTS")" "#1"
  "$SCRIPTS/hold.sh" unhold "$V429_API/1" >/dev/null 2>&1
  eq "v429 queue: after unhold it is ready again, in its place" "$(v429_ready)" "#1,#2,#3"
  eq "v429 queue: and on_hold is empty" "$(q | jq -c .on_hold)" "[]"
  # status and the team table: the team's PR is on hold, not "merge the PR"
  "$SCRIPTS/hold.sh" "$V429_API/3" --note "after the freeze" >/dev/null 2>&1
  local st; st="$(FLEET_GH="$QD/gh-shim" bash -c '. "$1/common.sh"; render_table --queue "$(FLEET_GH="$2" "$1/queue.sh")"' _ "$SCRIPTS" "$QD/gh-shim" 2>/dev/null)"
  eq "v429 status: a held team's needs says on hold with the note, not merge the PR" "$(printf '%s\n' "$st" | grep '^| q3 ' | grep -c 'on hold: after the freeze'):$(printf '%s\n' "$st" | grep '^| q3 ' | grep -c 'merge the PR')" "1:0"
  eq "v429 status: an unheld team still says merge the PR" "$(printf '%s\n' "$st" | grep '^| q1 ' | grep -c 'merge the PR')" "1"
  gold merge-queue-on-hold "$(q | jq -c . | { read -r j; bash -c '. "$1/common.sh"; render_queue "$2"' _ "$SCRIPTS" "$j"; })"
  "$SCRIPTS/hold.sh" unhold "$V429_API/3" >/dev/null 2>&1
}
render_queue_out() { q | { read -r j; bash -c '. "$1/common.sh"; render_queue "$2"' _ "$SCRIPTS" "$j"; }; }

v429_tick_cases() { # tick: no pr_ready for a held PR; an unhold fires it again, even when it fired before the hold
  qfresh h429c; qpr app-api 5 fleet/dev-5-a main 2026-10-20T10:00:00Z '["a.go"]' x
  qteam t5 app-api 5 DEV-5 aaaaaaa5
  local n
  "$SCRIPTS/hold.sh" "$V429_API/5" --note "not yet" >/dev/null 2>&1
  eq "v429 tick: a held PR emits no pr_ready" "$(v429_tick | jq -s '[.[][]? | select(.type == "pr_ready")] | length')" 0
  "$SCRIPTS/hold.sh" unhold "$V429_API/5" >/dev/null 2>&1
  eq "v429 tick: after unhold the PR is ready and pr_ready fires" "$(FLEET_NOW=2026-10-29T10:01:00Z v429_gh "$SCRIPTS/tick.sh" 2>/dev/null | jq -s '[.[][]? | select(.type == "pr_ready")] | length')" 1
  eq "v429 tick: and not again on the next tick" "$(FLEET_NOW=2026-10-29T10:02:00Z v429_gh "$SCRIPTS/tick.sh" 2>/dev/null | jq -s '[.[][]? | select(.type == "pr_ready")] | length')" 0
  "$SCRIPTS/hold.sh" "$V429_API/5" --note "again" >/dev/null 2>&1
  FLEET_NOW=2026-10-29T10:03:00Z v429_gh "$SCRIPTS/tick.sh" >/dev/null 2>&1
  eq "v429 tick: a hold drops the PR from the emitted list, so an unhold re-arms it" "$(jq -r --arg u "$V429_API/5" '[(.pr_ready_emitted // [])[] | select(startswith($u))] | length' "$FLEET_STATE_DIR/tick.state.json")" 0
  "$SCRIPTS/hold.sh" unhold "$V429_API/5" >/dev/null 2>&1
  n="$(FLEET_NOW=2026-10-29T10:04:00Z v429_gh "$SCRIPTS/tick.sh" 2>/dev/null | jq -s '[.[][]? | select(.type == "pr_ready")] | length')"
  eq "v429 tick: the second unhold fires pr_ready again, though it fired before the hold" "$n" 1
  # a pr_ready notice nobody has seen yet is dropped once the PR is held
  "$SCRIPTS/hold.sh" "$V429_API/5" --note "late" >/dev/null 2>&1
  eq "v429 tick: an unshown pr_ready notice for a PR that is now held is not shown" "$(printf '%s\n' "$(bash -c '. "$1/common.sh"; notices_show' _ "$SCRIPTS")" | grep -c 'Ready to merge')" 0
}

v429_overlap() { # overlap: a held PR never makes a plan wait; an unheld one still does
  qfresh h429d
  local R="$T/v429-ov-repo" out
  rm -rf "$R"; mkdir -p "$R/.fleet/plan"
  git init -q -b main "$R"; git -C "$R" remote add origin https://github.com/acme/app-api.git
  "$REG" add "$(jq -cn --arg r "$R" '{name:"ho-a/lead",team:"ho-a",tier:"Lead",status:"Working",herdr_ref:"ho-a-lead",pane:"p1",repo:$r,issue:"DEV-1"}')" >/dev/null
  { printf 'Plan\n\n## Files:\n'; printf -- '- `src/a.go`\n- `src/b.go`\n'; printf '\nHow to verify: x\n'; } >"$R/.fleet/plan/ho-a.md"
  printf '#!/usr/bin/env bash\ncat "$V429_PRS"\n' >"$T/v429-gh"; chmod +x "$T/v429-gh"
  export FLEET_GH="$T/v429-gh" V429_PRS="$T/v429-prs.json"
  jq -n '[{number: 7, url: "https://github.com/acme/app-api/pull/7", headRefName: "fleet/dev-7-x", body: "Fixes it", files: [{path: "src/a.go"}]},
          {number: 8, url: "https://github.com/acme/app-api/pull/8", headRefName: "fleet/dev-8-x", body: "Fixes it", files: [{path: "src/b.go"}]}]' >"$V429_PRS"
  eq "v429 overlap: with nothing held an overlapping PR makes the plan wait" "$(FLEET_PEERS_JSON='[]' "$SCRIPTS/overlap.sh" ho-a | head -n 1)" "wait #7"
  "$SCRIPTS/hold.sh" "$V429_API/7" --note "wait for the release" >/dev/null 2>&1
  eq "v429 overlap: a held PR is skipped, the next overlapping one is waited on" "$(FLEET_PEERS_JSON='[]' "$SCRIPTS/overlap.sh" ho-a | head -n 1)" "wait #8"
  "$SCRIPTS/hold.sh" "$V429_API/8" --note "also held" >/dev/null 2>&1
  eq "v429 overlap: with both held the answer is none, not wait" "$(FLEET_PEERS_JSON='[]' "$SCRIPTS/overlap.sh" ho-a | head -n 1)" "none"
  "$SCRIPTS/hold.sh" unhold "$V429_API/7" >/dev/null 2>&1; "$SCRIPTS/hold.sh" unhold "$V429_API/8" >/dev/null 2>&1
  eq "v429 overlap: after unhold the PR makes the plan wait again" "$(FLEET_PEERS_JSON='[]' "$SCRIPTS/overlap.sh" ho-a | head -n 1)" "wait #7"
  jq -n '[{number: 7, url: "https://github.com/acme/app-api/pull/7", headRefName: "fleet/dev-7-x", body: "Fixes it\n\nHold: until the release", files: [{path: "src/a.go"}, {path: "src/b.go"}]}]' >"$V429_PRS"
  out="$(FLEET_PEERS_JSON='[]' "$SCRIPTS/overlap.sh" ho-a | head -n 1)"
  eq "v429 overlap: a PR whose body has a Hold: line is ignored too (a hold made on another machine)" "$out" "none"
  unset FLEET_GH V429_PRS
}

v429_morning() { # the morning report lists a held PR under On hold, not under Ready to merge
  qfresh h429e; qpr app-api 1 fleet/dev-1-a main 2026-10-20T10:00:00Z '["a.go"]' x; qpr app-api 3 fleet/dev-3-c main 2026-10-22T10:00:00Z '["c.go"]' x
  qteam m1 app-api 1 DEV-1 aaaaaaa1; qteam m3 app-api 3 DEV-3 aaaaaaa3
  local out; out="$(TZ=UTC FLEET_NOW=2026-10-24T09:00:00Z v429_gh "$SCRIPTS/metrics.sh" --morning 2>/dev/null)"
  eq "v429 morning: with no hold there is no On hold section" "$(printf '%s\n' "$out" | grep -c '^## On hold')" 0
  "$SCRIPTS/hold.sh" "$V429_API/1" --note "wait for the release" >/dev/null 2>&1
  out="$(TZ=UTC FLEET_NOW=2026-10-24T09:00:00Z v429_gh "$SCRIPTS/metrics.sh" --morning 2>/dev/null)"
  gold morning-report-on-hold "$out"
  eq "v429 morning: the held PR is under ## On hold with its note" "$(printf '%s\n' "$out" | awk '/^## /{s=$0} s == "## On hold"' | grep -c 'pull/1.*wait for the release')" 1
  eq "v429 morning: and not under ## Ready to merge" "$(printf '%s\n' "$out" | awk '/^## /{s=$0} s == "## Ready to merge"' | grep -c 'pull/1')" 0
  eq "v429 morning: the other PR is still ready" "$(printf '%s\n' "$out" | awk '/^## /{s=$0} s == "## Ready to merge"' | grep -c 'pull/3')" 1
}

v429_version() { # the version is one number everywhere: plugin.json, the marketplace entry and a README "What changed" section
  local v; v="$(jq -r .version "$SCRIPTS/../../../.claude-plugin/plugin.json")"
  eq "v429 version: plugin.json and the marketplace agree, and the README has the What changed section of that version" \
    "$(jq -r '.plugins[] | select(.name == "developer") | .version' "$SCRIPTS/../../../../../.claude-plugin/marketplace.json"):$(grep -c "^## What changed in $v\$" "$SCRIPTS/../README.md")" "$v:1"
}

v429_smoke() {
  local f
  for f in v429_hold v429_queue v429_tick_cases v429_overlap v429_morning v429_version; do
    case " ${V429_ONLY:-$f} " in *" $f "*) "$f" ;; esac
  done
}
v429_full() { v429_smoke; }
