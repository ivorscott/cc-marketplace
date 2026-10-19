#!/usr/bin/env bash
# One Orchestrator tick: everything that changed since the last tick, as one JSON array.
# A quiet tick prints nothing and exits 0; the Orchestrator's whole reply to it is one line.
# Supersedes watch.sh for the Orchestrator loop (watch.sh stays for humans).
#
#   tick.sh [--team T]
#
# Events (each has type, team, name; url where a PR exists). Each is reported once; what has
# been reported lives in $FLEET_STATE_DIR/tick.state.json.
#   stalled, dead   status.sh says Stalled or Zombie, on the transition only
#   escalation      an open escalation not yet reported (keyed by agent name and escalation id)
#   pr_opened       a live builder on a fleet/ branch has an open PR the row doesn't know yet
#                   (gh pr list --head, even when the builder skipped its done step): recorded as
#                   the row's pr, the lead is told to start the tester. Once per PR.
#   pr_ready        the row's PR is open, mergeable, checks green (or none exist and the repo is in
#                   no_pr_ci in config.toml), the tester's signed-off SHA is the PR head, and the
#                   body has no "DO NOT MERGE", "merge order" or "before/after". Once per (PR, head SHA).
#   pr_merged       the row's PR was merged; the Orchestrator answers with next.sh. Once per PR.
#   repo_without_team  a repo in config.toml `repos` with no live team, when it becomes so
#   disk, disk_ok   free disk crossed below warn_free_gb, and recovered
#   claim_takeover  a team's issue now carries another machine's label (once per team, issue and holder)
#   claims_unavailable  teams hold issues but no Linear key is configured (once)
#   claims_readonly     teams hold issues and a key exists, but linear_writes = off (once)
# With a key and linear_writes allowing it, every tick makes ONE heartbeat mutation (linear.sh heartbeat);
# with a key, one read per claimed issue (holder), Done rows included. Tick never runs linear.sh migrate.
# Once a week (ISO week, in the state file) tick also runs `registry.sh archive`.
# One tick at a time: tick.lock (mkdir; pid and start time inside). A tick that finds a live, recent lock
# exits 0 quietly; a stale one (dead pid, or older than tick_lock_stale_secs, default 900) is broken.
# PR state is read with `gh pr view` / `gh pr list` (FLEET_GH), read-only. A gh failure for one PR is logged on
# stderr and skips that PR for this tick; no gh on PATH is one warning and no PR events.
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"

team=""
while [ $# -gt 0 ]; do
  case "$1" in
    --team) team="${2:?--team needs a name}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

# --- one tick at a time -------------------------------------------------------------------------------
# An mkdir lock (no flock on macOS) around the whole tick, from the state read to the state write, with the
# holder's pid and start time inside. Held by a live, recent tick: this one exits 0, quietly (tick_skipped
# on stderr). Stale (pid gone, or older than tick_lock_stale_secs, default 900): broken with a warning.
lockdir="$FLEET_STATE_DIR/tick.lock"
mkdir -p "$FLEET_STATE_DIR"
if ! mkdir "$lockdir" 2>/dev/null; then
  holder_pid="$(cat "$lockdir/pid" 2>/dev/null || true)"; holder_at="$(cat "$lockdir/started" 2>/dev/null || true)"
  stale=false
  now_e="$(date +%s)"
  stale_secs="$(cfg_int tick_lock_stale_secs 900)"
  if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then stale=true; fi
  case "$holder_at" in "" | *[!0-9]*) ;; *) [ $((now_e - holder_at)) -gt "$stale_secs" ] && stale=true ;; esac
  if $stale; then
    warn "breaking a stale tick lock (pid ${holder_pid:-unknown}, started ${holder_at:-unknown})"
    rm -rf "$lockdir"
    mkdir "$lockdir" 2>/dev/null || { printf 'fleet: tick_skipped: another tick took the lock\n' >&2; exit 0; }
  else
    printf 'fleet: tick_skipped: another tick holds %s (pid %s)\n' "$lockdir" "${holder_pid:-unknown}" >&2; exit 0
  fi
fi
printf '%s\n' "$$" >"$lockdir/pid"; date +%s >"$lockdir/started"
ghtmp=""
cleanup() { rm -rf "$lockdir"; if [ -n "$ghtmp" ]; then rm -f "$ghtmp"; fi; }
trap cleanup EXIT

FLEET_TICK_ID="$(now)-$$"; export FLEET_TICK_ID # one tick, one Linear viewer read (linear.sh caches by it)
state="$(tick_state)"
events="[]"
add_events() { events="$(jq -cn --argjson a "$events" --argjson b "$1" '$a + $b')"; }

# --- claims: heartbeat, takeover -------------------------------------------------------
# One heartbeat mutation per tick, however many issues are claimed (linear.sh heartbeat), and only when
# linear_writes allows it (off is the default: one claims_readonly event, the first time only). Without a
# key nothing is called: one claims_unavailable event, once. Tick never migrates; that is a release step.
# Done rows count: a team waiting on a merge keeps its claim.
claim_rows="$("$registry" list ${team:+--team "$team"} | jq -c '[.[] | select((.issue // "") != "" and .tier != "Orchestrator" and .status != "Retired")]')"
heartbeat() {
  local rows_n; rows_n="$(printf '%s' "$claim_rows" | jq length)"
  if "$FLEET_SCRIPTS/linear.sh" has-key >/dev/null 2>&1; then
    if [ "$(linear_writes)" = off ]; then
      if [ "$rows_n" != 0 ] && [ "$(printf '%s' "$state" | jq -r '.claims_readonly_emitted // false')" != true ]; then
        add_events '[{"type": "claims_readonly", "team": "", "name": "", "detail": "linear_writes = off; no heartbeat is written, takeover checks still read"}]'
        state="$(jq -cn --argjson st "$state" '$st + {claims_readonly_emitted: true}')"
      fi
    else
      [ "$rows_n" = 0 ] ||
        "$FLEET_SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1 || warn "linear.sh heartbeat failed"
    fi
  elif [ "$rows_n" != 0 ] && [ "$(printf '%s' "$state" | jq -r '.claims_unavailable_emitted // false')" != true ]; then
    add_events '[{"type": "claims_unavailable", "team": "", "name": "", "detail": "no Linear key; heartbeat and takeover checks are off"}]'
    state="$(jq -cn --argjson st "$state" '$st + {claims_unavailable_emitted: true}')"
  fi
}
# A team of ours whose issue now carries another machine's label was taken over: report it once.
claims_taken_over() {
  "$FLEET_SCRIPTS/linear.sh" has-key >/dev/null 2>&1 || return 0
  local t i h
  while IFS=$'\t' read -r t i; do
    [ -n "$i" ] || continue
    h="$("$FLEET_SCRIPTS/linear.sh" holder "$i" 2>/dev/null)" || { warn "could not read the holder of $i"; continue; }
    printf '%s' "$h" | jq -e '.holder != null and (.ours | not)' >/dev/null 2>&1 || continue
    h="$(printf '%s' "$h" | jq -r .holder)"
    if [ "$(printf '%s' "$state" | jq --arg k "$t|$i|$h" '(.takeover_emitted // []) | index($k) == null')" = true ]; then
      add_events "$(jq -cn --arg t "$t" --arg i "$i" --arg h "$h" '[{type: "claim_takeover", team: $t, name: ($t + "/lead"), issue: $i, holder: $h}]')"
      state="$(jq -cn --argjson st "$state" --arg k "$t|$i|$h" '$st + {takeover_emitted: ((($st.takeover_emitted // []) + [$k]) | unique)}')"
    fi
  done < <(printf '%s' "$claim_rows" | jq -r '[.[] | [.team, .issue]] | unique[] | @tsv')
}
heartbeat
claims_taken_over

# --- stalled / dead -------------------------------------------------------------------------
targs=(); [ -n "$team" ] && targs=(--team "$team")
if rows="$("$FLEET_SCRIPTS/status.sh" ${targs[@]+"${targs[@]}"} --json 2>/dev/null)" && printf '%s' "$rows" | jq -e 'type == "array"' >/dev/null 2>&1; then
  add_events "$(jq -cn --argjson rows "$rows" --argjson st "$state" '
    [$rows[] | select(.tier != "Orchestrator" and (.status == "Stalled" or .status == "Zombie") and (($st.status // {})[.name] != .status))
      | {type: (if .status == "Zombie" then "dead" else "stalled" end), team, name, status}
        + (if (.pr // "") != "" then {url: .pr} else {} end)]')"
  state="$(jq -cn --argjson st "$state" --argjson rows "$rows" '$st + {status: (($st.status // {}) + ([$rows[] | {(.name): .status}] | add // {}))}')"
else
  warn "status.sh failed; no stalled/dead events this tick"
fi

# --- escalations ------------------------------------------------------------------------------
esc="$("$registry" escalations --open ${team:+--team "$team"})"
add_events "$(jq -cn --argjson e "$esc" --argjson st "$state" '
  [$e[] | select(((.name + "|" + .id) as $k | ($st.escalations_emitted // []) | index($k)) == null)
    | {type: "escalation", team, name, id, severity, message, at}]')"
state="$(jq -cn --argjson st "$state" --argjson e "$esc" '
  $st + {escalations_emitted: ((($st.escalations_emitted // []) + [$e[] | .name + "|" + .id]) | unique)}')"

# --- PR discovery: a builder's PR found by its fleet/ branch -------------------------------------
if command -v "$FLEET_GH" >/dev/null 2>&1; then
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    bname="$(printf '%s' "$b" | jq -r .name)"; bbranch="$(printf '%s' "$b" | jq -r .branch)"; brepo="$(printf '%s' "$b" | jq -r '.repo // ""')"
    if [ ! -d "$brepo" ]; then warn "cannot look for $bname's PR: repo '$brepo' is not a directory"; continue; fi
    if ! found="$(cd "$brepo" && "$FLEET_GH" pr list --head "$bbranch" --json number,url,headRefOid,state 2>/dev/null)"; then
      warn "gh could not list PRs for $bbranch"; continue
    fi
    purl="$(printf '%s' "$found" | jq -r '[.[]? | select(.state == "OPEN")] | first | .url // ""' 2>/dev/null)" || purl=""
    [ -n "$purl" ] || continue
    "$registry" set "$bname" pr="$purl" >/dev/null || continue
    bteam="$(printf '%s' "$b" | jq -r .team)"; told=true
    "$FLEET_SCRIPTS/tell.sh" "$bteam/lead" "PR $purl is open; start the tester" >/dev/null 2>&1 || { told=false; warn "could not tell $bteam/lead about $purl"; }
    if [ "$(printf '%s' "$state" | jq --arg u "$purl" '(.pr_opened_emitted // []) | index($u) == null')" = true ]; then
      add_events "$(jq -cn --arg t "$bteam" --arg n "$bname" --arg u "$purl" --argjson told "$told" '[{type: "pr_opened", team: $t, name: $n, url: $u, lead_told: $told}]')"
      state="$(jq -cn --argjson st "$state" --arg u "$purl" '$st + {pr_opened_emitted: ((($st.pr_opened_emitted // []) + [$u]) | unique)}')"
    fi
  done < <("$registry" list ${team:+--team "$team"} | jq -c '.[] | select(.tier == "Worker" and .status != "Retired" and (.pr // "") == "" and ((.branch // "") | startswith("fleet/")))')
fi

# --- pull requests ----------------------------------------------------------------------------
# A malformed row (pr, repo or signoff of the wrong type) is skipped with a warning; it never aborts the tick.
# Only a tester row of the PR's own team can sign a PR off.
all_rows="$("$registry" list ${team:+--team "$team"})"
badrows="$(printf '%s' "$all_rows" | jq -r '[.[] | select(type == "object") | select(((.pr // "") | type) != "string" or ((.repo // "") | type) != "string"
  or (.signoff != null and ((.signoff | type) != "object" or ((.signoff.sha // "") | type) != "string")) ) | (.name // "?" | tostring)] | join(", ")')"
[ -z "$badrows" ] || warn "skipping malformed row(s) for PR checks: $badrows"
prs="$(printf '%s' "$all_rows" | jq -c '
  [.[] | select(type == "object") | select(((.pr // "") | type) == "string" and ((.repo // "") | type) == "string"
      and (.signoff == null or ((.signoff | type) == "object" and ((.signoff.sha // "") | type) == "string")))
    | select(.status != "Retired" and (.pr // "") != "")]
  | group_by(.pr) | map(. as $g | {pr: .[0].pr, team: .[0].team, name: .[0].name, repo: (.[0].repo // ""),
      signoff: ([$g[] | select((.signoff | objects | .sha) != null and ((.name // "") | endswith("/tester")) and .team == $g[0].team) | .signoff.sha] | first // null)})')"
if [ "$(printf '%s' "$prs" | jq length)" != 0 ]; then
  if ! command -v "$FLEET_GH" >/dev/null 2>&1; then
    warn "$FLEET_GH not found; no PR events this tick"
  else
    no_ci="$(config_list no_pr_ci)"
    ghtmp="$(mktemp)"
    while IFS= read -r p; do
      url="$(printf '%s' "$p" | jq -r .pr)"
      if ! j="$(forge_pr_json "$url" 2>"$ghtmp")"; then
        warn "gh could not read $url: $(head -1 "$ghtmp")"; continue
      fi
      if ! printf '%s' "$j" | jq -e 'type == "object" and (.state | type == "string")' >/dev/null 2>&1; then
        warn "gh returned no PR state for $url"; continue
      fi
      ev="$(jq -cn --argjson p "$p" --argjson g "$j" --argjson st "$state" --argjson noci "$no_ci" '
        ($p.repo | split("/") | last) as $base
        | ($p.pr | sub("^https?://[^/]+/"; "") | sub("/(pull|merge_requests)/.*$"; "")) as $slug
        | (($noci | index($base)) != null or ($noci | index($slug)) != null or ($noci | index($p.repo)) != null) as $nociok
        | ($g.statusCheckRollup // []) as $checks
        | ($checks | map(if .__typename == "StatusContext" or (.conclusion == null and .state != null)
              then (if .state == "SUCCESS" then "ok" elif (.state == "PENDING" or .state == "EXPECTED") then "pending" else "red" end)
              else (if .status != "COMPLETED" then "pending"
                    elif (.conclusion | IN("SUCCESS", "NEUTRAL", "SKIPPED")) then "ok" else "red" end) end)) as $cs
        | (if ($cs | length) == 0 then (if $nociok then "none" else "unknown" end)
           elif ($cs | index("red")) then "red" elif ($cs | index("pending")) then "pending" else "green" end) as $ci
        | ($p.signoff // "" | ascii_downcase) as $so | ($g.headRefOid // "" | ascii_downcase) as $head
        | ($so != "" and $head != "" and ($head | startswith($so))) as $signed
        | (($g.body // "") | test("DO NOT MERGE|merge order|before/after"; "i")) as $held
        | if $g.state == "MERGED" then
            (if (($st.pr_merged_emitted // []) | index($p.pr)) == null then {type: "pr_merged", team: $p.team, name: $p.name, url: $p.pr} else null end)
          elif $g.state == "OPEN" and $g.mergeable == "MERGEABLE" and ($ci == "green" or $ci == "none") and $signed and ($held | not)
               and (($st.pr_ready_emitted // []) | index($p.pr + "@" + $head)) == null
          then {type: "pr_ready", team: $p.team, name: $p.name, url: $p.pr, sha: $head, ci: $ci}
          else null end')"
      [ "$ev" != "null" ] || continue
      add_events "[$ev]"
      case "$(printf '%s' "$ev" | jq -r .type)" in
        pr_merged) state="$(jq -cn --argjson st "$state" --arg u "$url" '$st + {pr_merged_emitted: ((($st.pr_merged_emitted // []) + [$u]) | unique)}')" ;;
        pr_ready) state="$(jq -cn --argjson st "$state" --argjson e "$ev" '$st + {pr_ready_emitted: ((($st.pr_ready_emitted // []) + [$e.url + "@" + $e.sha]) | unique)}')" ;;
      esac
    done < <(printf '%s' "$prs" | jq -c '.[]')
    rm -f "$ghtmp"; ghtmp=""
  fi
fi

# --- repos without a team ---------------------------------------------------------------------
live="$("$registry" list --live | jq -c '[.[] | select(.tier != "Orchestrator") | .repo // ""]')"
bare="$(jq -cn --argjson r "$(config_list repos)" --argjson live "$live" '
  [$r[] | . as $x | select(([$live[] | select(. == $x or (split("/") | last) == ($x | split("/") | last))] | length) == 0)]')"
add_events "$(jq -cn --argjson b "$bare" --argjson st "$state" '
  [$b[] | select((($st.repo_idle_emitted // []) | index(.)) == null) | {type: "repo_without_team", team: "", name: ., repo: .}]')"
state="$(jq -cn --argjson st "$state" --argjson b "$bare" '$st + {repo_idle_emitted: $b}')"

# --- disk ---------------------------------------------------------------------------------------
if free="$(free_gb)"; then
  warn_at="$(warn_free_gb)"; was="$(printf '%s' "$state" | jq -r '.disk // "ok"')"; now_d=ok
  [ "$free" -ge "$warn_at" ] || now_d=low
  if [ "$now_d" != "$was" ]; then
    add_events "$(jq -cn --arg t "$([ "$now_d" = low ] && echo disk || echo disk_ok)" --argjson f "$free" --argjson w "$warn_at" \
      '[{type: $t, team: "", name: "disk", free_gb: $f, warn_free_gb: $w}]')"
  fi
  state="$(jq -cn --argjson st "$state" --arg d "$now_d" '$st + {disk: $d}')"
fi

# --- weekly archive ------------------------------------------------------------------------------
week="$(date +%G-W%V)"
if [ "$(printf '%s' "$state" | jq -r '.archive_week // ""')" != "$week" ]; then
  "$registry" archive >/dev/null 2>&1 || warn "weekly archive failed"
  state="$(jq -cn --argjson st "$state" --arg w "$week" '$st + {archive_week: $w}')"
fi

tick_state_write "$state"
[ "$(printf '%s' "$events" | jq length)" = 0 ] || printf '%s\n' "$events"
