#!/usr/bin/env bash
# One Orchestrator tick: everything that changed since the last tick, as one JSON array.
# A quiet tick prints nothing and exits 0; the Orchestrator's whole reply to it is one line.
# Run by loop-tick.sh from launchd (schedule.sh); the Orchestrator calls it itself only when no schedule is installed.
#
#   tick.sh [--team T]
#
# A Parked team (park.sh) is skipped throughout: no nudge, no respawn, no Stalled or Zombie, no PR discovery, and it
# still covers its repo for repo_without_team. Its claim is kept, so the heartbeat goes on. Its PR is still read: a
# merge is a pr_merged, and a conflict after another PR's merge unparks it (pr_conflicting).
# Each event that wakes the Orchestrator (WAKE_TYPES in common.sh) also gets its reply rendered once into
# $FLEET_STATE_DIR/notices.log (references/output.md); `fleet status` prints the ones not shown yet.
# Events (each has type, team, name; url where a PR exists). Each is reported once; what has
# been reported lives in $FLEET_STATE_DIR/tick.state.json.
#   stalled         still Stalled a tick after the nudge (a newly Stalled agent gets one nudge, no event)
#   failed          a row went Failed (a restart or a brief that did not arrive), once on the transition
#   dead            status.sh says Zombie, on the transition; the row is also respawned (respawn.sh) within
#                   a budget, and the second death inside the window escalates P1 instead
#   needs_input     an agent stopped by an API error (expired login); status_detail on its row says which
#   brief_failed    a brief never arrived (the row stays Failed): tick re-sent its pointer once and that did
#                   not arrive either. Once per (agent, brief file)
#   stale_version   a team has an agent on an older plugin version than the one installed (its row's
#                   plugin_version); switching it at the next `next.sh` waits for the user's go (a decision).
#                   Once per (team, installed version)
#   weekly_summary  the ISO week changed (its notice runs metrics.sh, which writes reports/fleet-metrics-<date>.md);
#                   the first tick ever only records the week
#   escalation      an open escalation not yet reported (keyed by agent name and escalation id)
#   pr_opened       a team with no PR on any row has an open PR whose head branch it pushed (one gh pr list --state
#                   open per repo, common.sh head_team; even when the builder skipped its done step): recorded on the
#                   builder's row, the lead is told to start the tester. Once per PR.
#   pr_ready        the row's PR is open, mergeable, checks green (or none exist and the repo is in
#                   no_pr_ci in config.toml), the tester's signed-off SHA is the PR head, no body line starts with
#                   "Do not merge" or "Hold:", the PR is not a draft, and every PR its body says it merges after
#                   ("Merge after #N", "Depends on <url>", "Stacked on #N") is no longer open. Once per (PR, head SHA).
#                   While a team's PR is ready and every agent of the team is Done or Idle, on that tick or a later one,
#                   it is parked (park.sh --reason signed-off) to free its slot.
#   pr_merged       the row's PR was merged; the Orchestrator answers with next.sh. Once per PR. A team marked
#                   park --after-merge (or by focus) is parked by tick instead; the event says `parks`.
#   pr_conflicting  a PR that was ready (the tick before, or since while mergeable read unknown), or has a sign-off, is
#                   CONFLICTING: it leaves the merge queue and its lead is told to bring it up to date by merging
#                   main into it (a merge commit) and have the tester sign off again, naming the PRs merged since the
#                   last tick that share files with it (merged), or main when none. A team that is Parked, or has a
#                   Done or Zombie agent, is brought back first (catchup.sh), twice at most per PR, then a P1
#                   escalation. Once per (PR, head); `catchup_refused` when a cap kept it from coming back.
#   input_pending   text sits unsent in the input box of an idle agent (read from its screen, `input_line`): the row gets
#                   `input_flag`, once per (agent, text) a wake; nothing is sent or cleared (tell clears the box first)
#   repo_without_team  a repo in config.toml `repos` with no live team, when it becomes so
#   disk, disk_ok   free disk crossed below warn_free_gb, and recovered
#   slot_free       fewer live teams than target_teams (orchestrator row) and max_teams: the Orchestrator picks and
#                   boots. Once per (live count, target)
#   claim_takeover  a team's issue now carries another machine's label (once per team, issue and holder)
#   claim_lost      a team's issue that this machine claimed carries no machine label any more: another machine
#                   released it as lapsed (once per team and issue; not while linear_writes is off)
#   claim_released  another machine's lapsed claim with no open PR was released (linear.sh release --lapsed)
#   claim_held_pr   another machine's lapsed claim has an open PR, so it was left alone
#   claim_lapsed    another machine's claim lapsed (writes off, test mode) or has no heartbeat; left alone, read-only.
#                   The three claim_ events: once per (issue, holder, heartbeat); not with --team
# Not an event: a new comment on a live team's issue (from the owner or another machine; the fleet's own start "[fleet]")
#                   is told to that team's lead once, as quoted data (linear.sh comments), and the lead re-reads the issue.
#   usage_limit     agents stopped on the plan's usage limit: no boot until usage_until, once per episode (usage_guard)
#   status_changed  the status table or the set of PRs ready to merge changed, at most once per status_mins / merge_push_mins
#   claims_unavailable  teams hold issues but no Linear key is configured (once)
#   claims_readonly     teams hold issues and a key exists, but linear_writes = off (once)
# With a key and linear_writes allowing it, every tick makes ONE heartbeat mutation (linear.sh heartbeat), first of
# all, before herdr is checked and with or without claimed rows;
# with a key, one read per claimed issue (holder), Done rows included. Tick never runs linear.sh migrate.
# Once a week (ISO week, in the state file) tick also runs `registry.sh archive`.
# One tick at a time: tick.lock (mkdir; pid and start time inside). A tick that finds a held lock exits 0
# quietly (tick_skipped on stderr); a lock whose holder pid is no longer running is recovered.
# PR state is read with `gh pr view` / `gh pr list` (FLEET_GH), read-only. A gh failure for one PR is logged on
# stderr and skips that PR for this tick; no gh on PATH is one warning and no PR events.
set -euo pipefail
. "$(dirname "$0")/common.sh"
# Before anything that can end the tick (herdr down, a held lock, a registry read): the machine label's heartbeat is
# refreshed, so a claim made while the loop was off never reads as lapsed to another machine. Rows are not needed,
# and a failure only warns.
HB_DONE=0
if "$FLEET_SCRIPTS/linear.sh" has-key >/dev/null 2>&1 && [ "$(linear_writes)" != off ]; then
  HB_DONE=1
  "$FLEET_SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1 || warn "linear.sh heartbeat failed"
fi
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
# holder's pid and start time inside. Held: this tick exits 0, quietly (tick_skipped on stderr). The trap frees
# the lock on exit and on INT/TERM/HUP. SIGKILL or a power cut bypasses the trap, so a lock whose holder pid is
# no longer running is recovered (pid check only, never by age), under a short mutex so two ticks cannot both
# break it. A lock with no pid yet, or a live one, is left alone.
lockdir="$FLEET_STATE_DIR/tick.lock"
mkdir -p "$FLEET_STATE_DIR"
# pid_gone <pid>: true only when kill -0 says there is no such process. "Not permitted" (another user's
# process, or a sandbox that denies the probe) and any other answer count as alive, so a live lock is never broken.
pid_gone() { local e; e="$(kill -0 "$1" 2>&1)" && return 1; case "$e" in *"No such process"*) return 0 ;; *) return 1 ;; esac; }
if ! mkdir "$lockdir" 2>/dev/null; then
  lpid="$(cat "$lockdir/pid" 2>/dev/null || true)"
  if [[ "$lpid" =~ ^[0-9]+$ ]] && pid_gone "$lpid" && mkdir "$lockdir.recover" 2>/dev/null; then
    # Re-read under the mutex: another tick may have recovered it and taken a new lock meanwhile.
    if [ "$(cat "$lockdir/pid" 2>/dev/null || true)" = "$lpid" ]; then
      rm -rf "$lockdir"; printf 'fleet: tick_lock_recovered: the holder (pid %s) is gone\n' "$lpid" >&2
    fi
    rmdir "$lockdir.recover" 2>/dev/null || true
  fi
  if ! mkdir "$lockdir" 2>/dev/null; then
    printf 'fleet: tick_skipped: another tick holds %s (pid %s); remove it if no tick is running\n' "$lockdir" "$(cat "$lockdir/pid" 2>/dev/null || echo unknown)" >&2; exit 0
  fi
fi
printf '%s\n' "$$" >"$lockdir/pid"; date +%s >"$lockdir/started"
# Keys config.toml has and config.example.toml does not: warned about once per change of config.toml (its cksum in
# config.warned), not on every tick (loop.log). boot warns on every run.
cfg_ck="$({ cksum <"$FLEET_CONFIG_DIR/config.toml"; } 2>/dev/null | awk '{ print $1 }' || true)"
if [ "$cfg_ck" != "$(cat "$FLEET_STATE_DIR/config.warned" 2>/dev/null || true)" ]; then
  config_warn_unknown; printf '%s\n' "$cfg_ck" >"$FLEET_STATE_DIR/config.warned" 2>/dev/null || true
fi
ghtmp=""
FLEET_TICK_ID="$(now)-$$"; export FLEET_TICK_ID # one tick, one Linear viewer read (linear.sh caches by it)

# State and events live in files, never in argv (ARG_MAX). st_upd <jq args> '<program using $st>'
# replaces the state with the program's result.
# They sit in the state dir (private to this machine's fleet) and the trap is set before they exist.
STATE_FILE=""; EVENTS_FILE=""
cleanup() {
  rm -rf "$lockdir"
  [ -z "$STATE_FILE" ] || rm -f "$STATE_FILE" "$STATE_FILE.new"
  [ -z "$EVENTS_FILE" ] || rm -f "$EVENTS_FILE" "$EVENTS_FILE.new"
  if [ -n "$ghtmp" ]; then rm -f "$ghtmp"; fi
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM HUP
STATE_FILE="$(mktemp "$FLEET_STATE_DIR/.tick-state.XXXXXX")"; EVENTS_FILE="$(mktemp "$FLEET_STATE_DIR/.tick-events.XXXXXX")"
tick_state >"$STATE_FILE"; echo '[]' >"$EVENTS_FILE"
st_upd() {
  local n=$# prog; prog="${!n}"; set -- "${@:1:$((n - 1))}"
  jq -c "$@" ". as \$st | $prog" "$STATE_FILE" >"$STATE_FILE.new" && mv "$STATE_FILE.new" "$STATE_FILE"
}
add_events() { jq -c --slurpfile b <(printf '%s' "$1") '. + $b[0]' "$EVENTS_FILE" >"$EVENTS_FILE.new" && mv "$EVENTS_FILE.new" "$EVENTS_FILE"; }

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
      if [ "$rows_n" != 0 ] && [ "$(jq -r '.claims_readonly_emitted // false' "$STATE_FILE")" != true ]; then
        add_events '[{"type": "claims_readonly", "team": "", "name": "", "detail": "linear_writes = off; no heartbeat is written, takeover checks still read"}]'
        st_upd '$st + {claims_readonly_emitted: true}'
      fi
    else
      [ "$rows_n" = 0 ] || [ "$HB_DONE" = 1 ] ||
        "$FLEET_SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1 || warn "linear.sh heartbeat failed"
    fi
  elif [ "$rows_n" != 0 ] && [ "$(jq -r '.claims_unavailable_emitted // false' "$STATE_FILE")" != true ]; then
    add_events '[{"type": "claims_unavailable", "team": "", "name": "", "detail": "no Linear key; heartbeat and takeover checks are off"}]'
    st_upd '$st + {claims_unavailable_emitted: true}'
  fi
}
# A team of ours whose issue now carries another machine's label was taken over: report it once. One whose issue
# carries no machine label at all, while its rows say this machine claimed it (claimed_by), lost its claim: another
# machine's sweep released it as lapsed (this one slept past lease_hours), and our heartbeat never puts the label back.
# Report that once too (claim_lost), so this machine learns before someone else picks the issue; only while Linear
# writes are not off, since a team moved unclaimed carries no claimed_by.
claims_taken_over() {
  "$FLEET_SCRIPTS/linear.sh" has-key >/dev/null 2>&1 || return 0
  local t i c h writes; writes="$(linear_writes)"
  while IFS=$'\t' read -r t i c; do
    [ -n "$i" ] || continue
    h="$("$FLEET_SCRIPTS/linear.sh" holder "$i" 2>/dev/null)" || { warn "could not read the holder of $i"; continue; }
    if printf '%s' "$h" | jq -e '.holder == null' >/dev/null 2>&1; then
      [ -n "$c" ] && [ "$writes" != off ] || continue
      if [ "$(jq --arg k "$t|$i" '(.lost_emitted // []) | index($k) == null' "$STATE_FILE")" = true ]; then
        add_events "$(jq -cn --arg t "$t" --arg i "$i" '[{type: "claim_lost", team: $t, name: ($t + "/lead"), issue: $i}]')"
        st_upd --arg k "$t|$i" '$st + {lost_emitted: ((($st.lost_emitted // []) + [$k]) | unique)}'
      fi
      continue
    fi
    printf '%s' "$h" | jq -e '.holder != null and (.ours | not)' >/dev/null 2>&1 || continue
    h="$(printf '%s' "$h" | jq -r .holder)"
    if [ "$(jq --arg k "$t|$i|$h" '(.takeover_emitted // []) | index($k) == null' "$STATE_FILE")" = true ]; then
      add_events "$(jq -cn --arg t "$t" --arg i "$i" --arg h "$h" '[{type: "claim_takeover", team: $t, name: ($t + "/lead"), issue: $i, holder: $h}]')"
      st_upd --arg k "$t|$i|$h" '$st + {takeover_emitted: ((($st.takeover_emitted // []) + [$k]) | unique)}'
    fi
  done < <(printf '%s' "$claim_rows" | jq -r 'group_by(.team + "|" + .issue) | .[] | [.[0].team, .[0].issue, ([.[].claimed_by // empty | select(. != "")] | first // "")] | @tsv')
}
# Another machine's lapsed claim (linear.sh peers, read once; a fleet-wide check, so tick --team skips it). Only a
# heartbeat older than lease_hours is lapsed. With writes allowed and no open PR in any repo the fleet works in (the
# registry rows' repos and config.toml `repos`, by their origin remotes), linear.sh release --lapsed frees the
# issue (it checks both again): claim_released. An open PR is never touched: claim_held_pr. Writes off, test mode
# outside its team, or no repo to look in: claim_lapsed, read-only. A claim with no heartbeat is not proven lapsed:
# claim_lapsed only. Each once per (issue, holder, heartbeat); keys of claims no longer listed are dropped.
claims_lapsed() {
  [ -z "$team" ] || return 0
  "$FLEET_SCRIPTS/linear.sh" has-key >/dev/null 2>&1 || return 0
  local peers repos i m hb k ev url why proven lease err now_t
  peers="$("$FLEET_SCRIPTS/linear.sh" peers 2>/dev/null)" || { warn "could not read other machines' claims"; return 0; }
  repos="$({ "$registry" list | jq -r '.[] | .repo // empty'; config_list repos | jq -r '.[]'; } | sort -u | while IFS= read -r d; do
      [ ! -d "$d" ] || repo_slug "$d"; done | sort -u | paste -sd' ' -)" || repos=""
  now_t="${FLEET_NOW:-$(now)}"; err="$(mktemp "${TMPDIR:-/tmp}/fleet-tick-release.XXXXXX")"
  while IFS=$'\t' read -r i m hb; do
    [ -n "$i" ] || continue
    [ "$hb" != - ] || hb=""
    proven=0 # a live heartbeat is skipped; one that is no time is never proven lapsed
    if [ -n "$hb" ] && lease="$("$FLEET_SCRIPTS/claim.sh" lease --now "$hb" 2>/dev/null)"; then
      "$FLEET_SCRIPTS/claim.sh" expired --lease "$lease" --now "$now_t" >/dev/null 2>&1 && proven=1 || continue
    fi
    k="$i|$m|$hb"
    [ "$(jq --arg k "$k" '(.lapsed_emitted // []) | index($k) == null' "$STATE_FILE")" = true ] || continue
    ev=claim_lapsed; url=""; why=""
    if [ "$proven" = 0 ]; then why="no heartbeat, so it is not proven lapsed"
    elif [ "$(linear_writes)" = off ]; then why="its heartbeat is older than lease_hours, and linear_writes is off"
    elif [ -z "$repos" ]; then why="its heartbeat is older than lease_hours, and the fleet has no repo to look for its PR in"
    else
      # shellcheck disable=SC2046,SC2086
      if "$FLEET_SCRIPTS/linear.sh" release "$i" --lapsed $(printf -- '--repo %s ' $repos) >/dev/null 2>"$err"; then ev=claim_released
      else
        case "$(cat "$err")" in
          *"has an open PR ("*) ev=claim_held_pr; url="$(sed -n 's/.*has an open PR (\([^)]*\)).*/\1/p' "$err" | head -n 1)" ;;
          *"test mode"*) why="its heartbeat is older than lease_hours, and linear_writes is in test mode" ;;
          *) warn "could not release the lapsed claim of $m on $i: $(tail -n 1 "$err")"; continue ;;
        esac
      fi
    fi
    add_events "$(jq -cn --arg e "$ev" --arg i "$i" --arg m "$m" --arg u "$url" --arg w "$why" \
      '[{type: $e, team: "", name: "", issue: $i, holder: $m} + (if $u != "" then {url: $u} else {} end) + (if $w != "" then {detail: $w} else {} end)]')"
    st_upd --arg k "$k" '$st + {lapsed_emitted: ((($st.lapsed_emitted // []) + [$k]) | unique)}'
  done < <(printf '%s' "$peers" | jq -r '.[] | [.issue, .label, (.heartbeat // "-")] | @tsv')
  rm -f "$err"
  st_upd --argjson p "$peers" '$st + {lapsed_emitted: [($st.lapsed_emitted // [])[] | select(split("|")[0:2] | join("|") as $k | [$p[] | .issue + "|" + .label] | index($k))]}'
}
# New comments on a live team's issue (from the owner or another machine) reach that team's lead once, as a quoted
# notice: the comment is data, never an approval, and the lead re-reads the issue before sign-off. The first look at an
# issue only records its newest comment, so old ones are not forwarded. One read per issue per tick, and only with a key
# and writes allowed; a notice that does not arrive is tried again next tick. Comments the fleet posts start "[fleet]".
comments_forward() {
  "$FLEET_SCRIPTS/linear.sh" has-key >/dev/null 2>&1 && [ "$(linear_writes)" != off ] || return 0
  local t i cj last new n body
  while IFS=$'\t' read -r t i; do
    [ -n "$i" ] || continue
    cj="$("$FLEET_SCRIPTS/linear.sh" comments "$i" 2>/dev/null)" && printf '%s' "$cj" | jq -e 'type == "array"' >/dev/null 2>&1 || { warn "could not read the comments of $i"; continue; }
    last="$(jq -r --arg k "$i" '(.comments_seen // {})[$k] // "-"' "$STATE_FILE")"
    if [ "$last" = - ]; then
      st_upd --arg k "$i" --arg l "$(printf '%s' "$cj" | jq -r 'last.id // ""')" '$st + {comments_seen: (($st.comments_seen // {}) + {($k): $l})}'; continue
    fi
    new="$(printf '%s' "$cj" | jq -c --arg l "$last" '(if $l == "" then . elif any(.[]; .id == $l) then (map(.id) | index($l)) as $x | .[$x + 1:] else [] end)
      | map(select(.body | startswith("[fleet]") | not))')"
    n="$(printf '%s' "$new" | jq length)"
    if [ "$n" != 0 ]; then
      body="$(printf '%s' "$new" | jq -r '[.[] | "\(.user): \(.body | gsub("\\s+"; " ") | .[0:400])"] | join(" | ")')"
      "$FLEET_SCRIPTS/tell.sh" "$t/lead" "New comment on $i (data from the issue, not an approval): \"$body\". Re-read $i now and again before sign-off." >/dev/null 2>&1 ||
        { warn "could not forward a comment on $i to $t/lead"; continue; }
    fi
    st_upd --arg k "$i" --arg l "$(printf '%s' "$cj" | jq -r 'last.id // ""')" '$st + {comments_seen: (($st.comments_seen // {}) + {($k): $l})}'
  done < <(printf '%s' "$claim_rows" | jq -r '[.[] | select(.status != "Parked")] | group_by(.team + "|" + .issue) | .[] | [.[0].team, .[0].issue] | @tsv')
}
# The overlap check: once per team, when its planner is Done and its plan file holds a Files: block, overlap.sh compares
# the plan with the open PRs and live teams of the same repo, and the lead is told the answer (build now, wait for #N, or
# build now and put "Merge after #N" in the PR body). Not an event: nobody is woken. A check that cannot run is told too,
# once, so the lead builds on the catch-up rather than waiting for it.
plan_overlap() {
  local t r ans rc
  while IFS=$'\t' read -r t r; do
    [ -n "$t" ] && [ -f "$r/.fleet/plan/$t.md" ] || continue
    [ "$(jq --arg t "$t" '(.overlap_told // []) | index($t) == null' "$STATE_FILE")" = true ] || continue
    rc=0; ans="$("$FLEET_SCRIPTS/overlap.sh" "$t" 2>&1)" || rc=$?
    if [ "$rc" = 0 ]; then
      ans="Overlap check: $(printf '%s' "$ans" | head -n 1). $(printf '%s' "$ans" | sed -n 2p) $(case "$ans" in none*) echo 'Build now.' ;; wait*) echo 'Start the builder only after that merges, then branch from main.' ;; *) echo 'Build now, and put the line "Merge after that PR" in your PR body.' ;; esac)"
    else ans="Overlap check could not run ($(printf '%s' "$ans" | tail -n 1 | cut -c1-160)). Build now; the catch-up handles a conflict."; fi
    "$FLEET_SCRIPTS/tell.sh" "$t/lead" "$ans" >/dev/null 2>&1 || { warn "could not tell $t/lead the overlap answer"; continue; }
    st_upd --arg t "$t" '$st + {overlap_told: ((($st.overlap_told // []) + [$t]) | unique)}'
  done < <("$registry" list ${team:+--team "$team"} | jq -r '[.[] | select(.tier != "Orchestrator" and .status != "Retired" and .status != "Parked")] | group_by(.team) | .[]
    | select(any(.[]; (.name | endswith("/planner")) and .status == "Done")) | [.[0].team, ([.[].repo // empty | select(. != "")] | first // "")] | @tsv')
}
heartbeat
claims_taken_over
claims_lapsed
comments_forward
plan_overlap

# --- usage guard ----------------------------------------------------------------------------------
# Agents that stop on the plan's rate or usage limit (api_error_detail says "usage limit") start a backoff: usage_until in
# the state, no new boot and no slot_free while it runs (boot.sh refuses too), running teams carry on, and the Orchestrator
# is woken once (usage_limit) for the whole episode. Each hit after a backoff ended doubles the next one (usage_backoff_secs,
# 15 minutes at first, 4 hours at most): no retry storm. An episode ends when no agent is limited and the backoff has run
# out. These agents are not needs_input events: one wake covers them all.
usage_guard() { # usage_guard <number of agents stopped by a usage limit>
  local n="$1" until hits active secs
  until="$(jq -r '.usage_until // 0' "$STATE_FILE")"; hits="$(jq -r '.usage_hits // 0' "$STATE_FILE")"; active="$(jq -r '.usage_active // false' "$STATE_FILE")"
  if [ "$n" -gt 0 ]; then
    if [ "$now_epoch" -ge "$until" ]; then
      hits=$((hits + 1)); secs="$(const_int USAGE_BACKOFF_SECS 900)"
      if [ "$hits" -gt 5 ]; then secs=14400; else secs=$((secs << (hits - 1))); [ "$secs" -le 14400 ] || secs=14400; fi
      until=$((now_epoch + secs))
      st_upd --argjson u "$until" --argjson h "$hits" '$st + {usage_until: $u, usage_hits: $h, usage_active: true}'
      if [ "$active" != true ]; then
        add_events "$(jq -cn --argjson u "$until" '[{type: "usage_limit", team: "", name: "", until: ($u | todate), detail: "agents hit the plan usage limit"}]')"
      fi
    fi
  elif [ "$active" = true ] && [ -z "$team" ] && [ "$now_epoch" -ge "$until" ]; then
    st_upd '$st + {usage_active: false, usage_hits: 0, usage_until: 0}'
  fi
}

# --- stalled / dead -------------------------------------------------------------------------
# A newly Stalled agent gets ONE nudge through tell.sh (nudged_at on its row) and no event; still
# Stalled on a later tick: a `stalled` event, once. A Zombie on two ticks in a row is a `dead` event (once) and is
# respawned within a budget (respawn_max = 1 per respawn_window_hours = 6 per agent): every attempt, successful
# or not, spends it; once it is spent, one P1 escalation and no more respawns. Done and Retired rows are never touched.
now_iso="${FLEET_NOW:-$(now)}"; now_epoch="$(jq -rn --arg t "$now_iso" '$t | fromdateiso8601')"
targs=(); [ -n "$team" ] && targs=("$team")
# One `herdr agent list` first: when herdr itself is down, every row would read as Zombie, so a failed
# call skips classification and respawn for this tick.
if ! hd agent list >/dev/null 2>&1; then
  warn "herdr agent list failed; no classification or respawn this tick"
elif rows="$("$FLEET_SCRIPTS/status.sh" ${targs[@]+"${targs[@]}"} --json 2>/dev/null)" && printf '%s' "$rows" | jq -e 'type == "array"' >/dev/null 2>&1; then
  add_events "$(jq -cn --slurpfile rows <(printf '%s' "$rows") --slurpfile stf "$STATE_FILE" '$rows[0] as $rows
    | [$rows[] | select(.tier != "Orchestrator" and .status == "Failed" and (($stf[0].status // {})[.name] != .status))
      | {type: "failed", team, name, status}]')"
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    sname="$(printf '%s' "$r" | jq -r .name)"
    if [ -z "$(printf '%s' "$r" | jq -r '.nudged_at // ""')" ]; then
      "$FLEET_SCRIPTS/tell.sh" "$sname" "You went idle without running your done step. Run it now, or say what is missing." >/dev/null 2>&1 ||
        warn "could not nudge $sname"
      "$registry" set "$sname" nudged_at="$now_iso" >/dev/null || true
    elif [ "$(jq --arg n "$sname" '(.stalled_emitted // []) | index($n) == null' "$STATE_FILE")" = true ]; then
      add_events "$(printf '%s' "$r" | jq -c '[{type: "stalled", team, name, status} + (if (.pr // "") != "" then {url: .pr} else {} end)]')"
      st_upd --arg n "$sname" '$st + {stalled_emitted: ((($st.stalled_emitted // []) + [$n]) | unique)}'
    fi
  done < <(printf '%s' "$rows" | jq -c '.[] | select(.tier != "Orchestrator" and .status == "Stalled")')
  # An agent that is no longer Stalled may be nudged and reported again next time.
  while IFS= read -r sname; do
    [ -n "$sname" ] || continue
    "$registry" set "$sname" nudged_at= >/dev/null || true
    st_upd --arg n "$sname" '$st + {stalled_emitted: (($st.stalled_emitted // []) - [$n])}'
  done < <(printf '%s' "$rows" | jq -r '.[] | select(.tier != "Orchestrator" and .status != "Stalled" and ((.nudged_at // "") != "")) | .name')
  # An agent stopped by an API error (an expired login) shows Needs input with the reason (status.sh) and
  # is never nudged for stalling; it gets at most one "continue" every 30 minutes, which works as soon
  # as the user has run /login.
  while IFS=$'\t' read -r sname last; do
    [ -n "$sname" ] || continue
    if [ -n "$last" ] && [ $((now_epoch - $(jq -rn --arg t "$last" '$t | fromdateiso8601'))) -lt 1800 ]; then continue; fi
    "$FLEET_SCRIPTS/tell.sh" "$sname" "continue" --no-confirm >/dev/null 2>&1 || warn "could not send continue to $sname"
    "$registry" set "$sname" continued_at="$now_iso" >/dev/null || true
  done < <(printf '%s' "$rows" | jq -r '.[] | select(.tier != "Orchestrator" and .status == "Needs input" and (.status_detail // "") != "") | [.name, (.continued_at // "")] | @tsv')
  # needs_input: an agent stopped by an API error, once per (agent, reason); forgotten when it recovers.
  add_events "$(jq -cn --slurpfile rows <(printf '%s' "$rows") --slurpfile stf "$STATE_FILE" '$rows[0] as $rows
    | [$rows[] | (.name + "|" + (.status_detail // "")) as $k
      | select(.tier != "Orchestrator" and .status == "Needs input" and (.status_detail // "") != ""
        and .status_detail != "usage limit"
        and ((($stf[0].needs_input_emitted // []) | index($k)) == null))
      | {type: "needs_input", team, name, detail: .status_detail}]')"
  usage_guard "$(printf '%s' "$rows" | jq '[.[] | select(.tier != "Orchestrator" and .status == "Needs input" and (.status_detail // "") == "usage limit")] | length')"
  # Only the rows this tick read are re-derived: a --team tick keeps the other teams' keys.
  st_upd --slurpfile rows <(printf '%s' "$rows") '$rows[0] as $rows | [$rows[].name] as $seen
    | $st + {needs_input_emitted: ([($st.needs_input_emitted // [])[] | select(split("|")[0] as $n | $seen | index($n) | not)]
        + [$rows[] | select(.status == "Needs input" and (.status_detail // "") != "") | .name + "|" + .status_detail])}'
  # input_pending: text left unsent in the input box of an idle agent (not typed by the owner: a stray paste, or a
  # suggestion Claude Code put there) is recorded on the row (`input_flag`, 80 characters, which status shows) and raised
  # once per (agent, text). Nothing is sent and nothing cleared here: tell clears the box before it sends. An empty box
  # clears the field, and the key is forgotten so the same text can be reported again later.
  while IFS= read -r sname; do
    [ -n "$sname" ] || continue
    sref="$(printf '%s' "$rows" | jq -r --arg n "$sname" '.[] | select(.name == $n) | .herdr_ref // ""')"
    itext="$(input_line "$sref" | tr '\n' ' ' | sed 's/ *$//' | cut -c1-80)"
    ikey="$sname|$(printf '%s' "$itext" | cksum | awk '{print $1}')"
    if [ -n "$itext" ]; then
      "$registry" set "$sname" input_flag="$itext" >/dev/null 2>&1 || true
      if [ "$(jq --arg k "$ikey" '(.input_emitted // []) | index($k) == null' "$STATE_FILE")" = true ]; then
        add_events "$(printf '%s' "$rows" | jq -c --arg n "$sname" --arg t "$itext" '[.[] | select(.name == $n) | {type: "input_pending", team, name, detail: $t}]')"
      fi
      st_upd --arg n "$sname" --arg k "$ikey" '$st + {input_emitted: ((((($st.input_emitted // []) | map(select(startswith($n + "|") | not)))) + [$k]))}'
    else
      [ -z "$(printf '%s' "$rows" | jq -r --arg n "$sname" '.[] | select(.name == $n) | .input_flag // ""')" ] || "$registry" set "$sname" input_flag= >/dev/null 2>&1 || true
      st_upd --arg n "$sname" '$st + {input_emitted: (($st.input_emitted // []) | map(select(startswith($n + "|") | not)))}'
    fi
  done < <(printf '%s' "$rows" | jq -r '.[] | select(.tier != "Orchestrator" and (.status == "Idle" or .status == "Stalled" or .status == "Needs input")) | .name')
  # A brief that did not arrive: the row stays Failed (status.sh). Re-send the pointer to the same brief file
  # once; if that does not arrive either, one brief_failed event (a wake).
  while IFS=$'\t' read -r fname fbrief fresent fissue cissue; do
    [ -n "$fname" ] || continue
    # Re-send only the brief of the issue the row is on now (a brief for an issue it has left is never re-sent).
    if [ -z "$fresent" ] && [ -n "$fbrief" ] && [ -f "$fbrief" ] && [ "$fissue" = "$cissue" ]; then
      "$registry" set "$fname" brief_resent="$now_iso" >/dev/null 2>&1 || true
      # tell.sh brings the row back (lead Working, worker Idle) when the pointer arrives.
      if "$FLEET_SCRIPTS/tell.sh" "$fname" - --brief-file "$fbrief" >/dev/null 2>&1; then continue; fi
    fi
    if [ "$(jq --arg k "$fname|$fbrief" '(.brief_failed_emitted // []) | index($k) == null' "$STATE_FILE")" = true ]; then
      add_events "$(jq -cn --arg n "$fname" --arg f "$fbrief" '[{type: "brief_failed", team: ($n | split("/")[0]), name: $n, detail: $f}]')"
      st_upd --arg k "$fname|$fbrief" '$st + {brief_failed_emitted: ((($st.brief_failed_emitted // []) + [$k]) | unique)}'
    fi
  done < <(printf '%s' "$rows" | jq -r '.[] | select(.tier != "Orchestrator" and .status == "Failed" and (.brief_failed_at // "") != "")
    | [.name, (.last_brief // ""), (.brief_resent // ""), (.brief_failed_issue // ""), (.issue // "")] | @tsv')
  rwin="$(const_int RESPAWN_WINDOW_HOURS 6)"; rmax="$(const_int RESPAWN_MAX 1)"
  while IFS= read -r zname; do
    [ -n "$zname" ] || continue
    # Respawn needs Zombie on two ticks in a row: the state still holds the previous tick's status. The
    # `dead` event goes with that decision, once per death (dead_emitted, forgotten when the row recovers).
    [ "$(jq --arg n "$zname" '((.status // {})[$n]) == "Zombie"' "$STATE_FILE")" = true ] || continue
    if [ "$(jq --arg n "$zname" '(.dead_emitted // []) | index($n) == null' "$STATE_FILE")" = true ]; then
      add_events "$(printf '%s' "$rows" | jq -c --arg n "$zname" '[.[] | select(.name == $n) | {type: "dead", team, name, status} + (if (.pr // "") != "" then {url: .pr} else {} end)]')"
      st_upd --arg n "$zname" '$st + {dead_emitted: ((($st.dead_emitted // []) + [$n]) | unique)}'
    fi
    recent="$(jq -c --arg n "$zname" --argjson now "$now_epoch" --argjson w "$rwin" '((.respawns // {})[$n] // []) | map(select(. > $now - $w * 3600))' "$STATE_FILE")"
    if [ "$(printf '%s' "$recent" | jq length)" -ge "$rmax" ]; then
      ekey="$zname|$(printf '%s' "$recent" | jq 'max')"
      if [ "$(jq --arg k "$ekey" '(.respawn_escalated // []) | index($k) == null' "$STATE_FILE")" = true ]; then
        if [ "$(jq --arg n "$zname" '(.respawn_failed // []) | index($n) != null' "$STATE_FILE")" = true ]; then
          emsg="$zname could not be respawned in ${rwin}h"
        else emsg="$zname died twice in ${rwin}h"; fi
        "$registry" escalate "$zname" P1 "$emsg" >/dev/null 2>&1 || warn "could not escalate $zname"
        st_upd --arg k "$ekey" '$st + {respawn_escalated: ((($st.respawn_escalated // []) + [$k]) | unique)}'
      fi
    else
      # The attempt is recorded before respawn.sh runs, so a respawn that always fails still spends the budget.
      st_upd --arg n "$zname" --argjson now "$now_epoch" '$st + {respawns: (($st.respawns // {}) + {($n): ((($st.respawns // {})[$n] // []) + [$now])})}'
      if "$FLEET_SCRIPTS/respawn.sh" "$zname" >/dev/null 2>"$FLEET_STATE_DIR/respawn.err"; then
        st_upd --arg n "$zname" '$st + {respawn_failed: (($st.respawn_failed // []) - [$n])}'
      else
        warn "could not respawn $zname: $(head -n 1 "$FLEET_STATE_DIR/respawn.err" 2>/dev/null)"
        st_upd --arg n "$zname" '$st + {respawn_failed: ((($st.respawn_failed // []) + [$n]) | unique)}'
      fi
    fi
  done < <(printf '%s' "$rows" | jq -r '.[] | select(.tier != "Orchestrator" and .status == "Zombie") | .name')
  st_upd --slurpfile rows <(printf '%s' "$rows") '$rows[0] as $rows | $st + {status: (($st.status // {}) + ([$rows[] | {(.name): .status}] | add // {})),
    dead_emitted: (($st.dead_emitted // []) - [$rows[] | select(.status != "Zombie") | .name])}'
else
  warn "status.sh failed; no stalled/dead events this tick"
fi

# --- stale plugin version ------------------------------------------------------------------------------
# A team with a row booted (or restarted) by an older plugin than the one installed now. Its restart at the next
# `next.sh` (never mid-task) would switch it, and that waits for the user's go (next.sh and respawn.sh --restart
# refuse with exit 5 until it is recorded: registry.sh pref version_ok <installed>), so this asks, once per (team,
# installed version), naming the team's first stale row, the lead first, and asks nothing once the go is recorded.
iv="$(installed_version)"
if [ -n "$iv" ] && [ "$(version_ok)" != "$iv" ]; then
  vseen=" "
  while IFS=$'\t' read -r vname vteam pv; do
    [ -n "$vname" ] && [ -n "$pv" ] || continue
    version_gt "$iv" "$pv" || continue
    case "$vseen" in *" $vteam "*) continue ;; esac
    vseen="$vseen$vteam "
    if [ "$(jq --arg k "$vteam|$iv" '(.stale_emitted // []) | index($k) == null' "$STATE_FILE")" = true ]; then
      add_events "$(jq -cn --arg n "$vname" --arg t "$vteam" --arg p "$pv" --arg i "$iv" '[{type: "stale_version", team: $t, name: $n, from: $p, to: $i, detail: ("runs " + $p + ", installed " + $i + "; waits for the user'"'"'s go")}]')"
      st_upd --arg k "$vteam|$iv" '$st + {stale_emitted: ((($st.stale_emitted // []) + [$k]) | unique)}'
    fi
  done < <("$registry" list --live ${team:+--team "$team"} | jq -r '[.[] | select(.tier != "Orchestrator")] | sort_by(.team, (if .tier == "Lead" then 0 else 1 end), .name)[] | [.name, .team, (.plugin_version // "")] | @tsv')
fi

# --- blocked on a prompt ---------------------------------------------------------------------------------------
# An agent herdr reports blocked (Needs input with no API-error detail and no open escalation of its own) on two ticks
# in a row waits on a permission prompt nobody answers: one P1 escalation per blocked spell, which ends when it leaves
# blocked. No screen is read. Always on, overnight or not; a fleet-wide view, so tick --team skips it.
if [ -z "$team" ]; then
  blocked_now="$("$registry" list --live | jq -c '[.[] | select(.tier != "Orchestrator" and .status == "Needs input"
    and (.status_detail // "") == "" and (.escalation // "") == "") | .name]')"
  for bn in $(jq -r --argjson p "$(jq -c '.blocked_prev // []' "$STATE_FILE")" --argjson t "$(jq -c '.blocked_told // []' "$STATE_FILE")" \
    '.[] | select(. as $n | ($p | index($n)) != null and ($t | index($n)) == null)' <<<"$blocked_now"); do
    "$registry" escalate "$bn" P1 "blocked on a permission prompt: look at its pane" >/dev/null 2>&1 || warn "could not escalate $bn, blocked on a prompt"
    st_upd --arg n "$bn" '$st + {blocked_told: ((($st.blocked_told // []) + [$n]) | unique)}'
  done
  st_upd --argjson b "$blocked_now" '$st + {blocked_prev: $b, blocked_told: [($st.blocked_told // [])[] | select(. as $n | $b | index($n))]}'
fi

# --- escalations ------------------------------------------------------------------------------
esc="$("$registry" escalations --open ${team:+--team "$team"})"
add_events "$(jq -cn --slurpfile e <(printf '%s' "$esc") --slurpfile stf "$STATE_FILE" '$e[0] as $e
  | [$e[] | select(((.name + "|" + .id) as $k | ($stf[0].escalations_emitted // []) | index($k)) == null)
    | {type: "escalation", team, name, id, severity, message, options: (.options // []), at}]')"
st_upd --slurpfile e <(printf '%s' "$esc") '$e[0] as $e
  | $st + {escalations_emitted: ((($st.escalations_emitted // []) + [$e[] | .name + "|" + .id]) | unique)}'

# --- PR discovery: a team's PR found by its head branch -----------------------------------------------------
# A builder pushes fleet/<slug>, whatever its worktree's branch is called (boot records fleet/<team>/<role>). Each
# worker's branch is read from its worktree (git branch --show-current, falling back to the row) and written back to
# the row. Then one read-only `gh pr list --state open` per repo of the teams with no PR on any row: an open PR whose
# head one of those teams pushed (common.sh head_team: a row's branch, fleet/<team>/..., fleet/<issue key>-...) is
# recorded on that team's worker whose branch it is, else its builder, the lead is told to start the tester, and
# pr_opened fires once per PR. Only same-repository PRs count (the list also returns fork PRs, and the repo is public).
if command -v "$FLEET_GH" >/dev/null 2>&1; then
  while IFS=$'\t' read -r bname rowbranch bwt; do
    [ -n "$bname" ] || continue
    bbranch=""; if [ -n "$bwt" ] && [ -d "$bwt" ]; then bbranch="$(git -C "$bwt" branch --show-current 2>/dev/null || true)"; fi
    case "$bbranch" in fleet/*) [ "$bbranch" = "$rowbranch" ] || "$registry" set "$bname" branch="$bbranch" >/dev/null || warn "could not write $bname's branch back" ;; esac
  done < <("$registry" list ${team:+--team "$team"} | jq -r '.[] | select(.tier == "Worker" and .status != "Retired" and .status != "Parked" and (.pr // "") == "")
    | [.name, (.branch // ""), (.worktree // "")] | @tsv')
  drows="$("$registry" list | jq -c '[.[] | select(type == "object" and .status != "Retired" and .tier != "Orchestrator")]')"
  # the teams to look for: not parked and a worker on a fleet/ branch (what boot gives a builder). A team that has a PR
  # is looked at too: a second PR for its issue is recorded next to the first (registry.sh add-pr).
  dteams="$(jq -c --arg only "$team" '[group_by(.team)[] | select(($only == "" or .[0].team == $only) and all(.[]; .status != "Parked")
    and any(.[]; .tier == "Worker" and ((.branch // "") | startswith("fleet/")))) | .[0].team]' <<<"$drows")"
  while IFS= read -r brepo; do
    [ -n "$brepo" ] || continue
    if [ ! -d "$brepo" ]; then warn "cannot look for PRs in '$brepo': not a directory"; continue; fi
    if ! found="$(cd "$brepo" && "$FLEET_GH" pr list --state open --limit 200 --json number,url,headRefName,state,isCrossRepository 2>/dev/null)"; then
      warn "gh could not list the open PRs in $brepo"; continue
    fi
    while IFS=$'\t' read -r bteam bname purl; do
      [ -n "$purl" ] || continue
      # already on a row of the team: nothing to record or announce
      [ "$("$registry" list --team "$bteam" | jq --arg u "$purl" 'any(.[]; (.pr // "") == $u or ((.prs // []) | index($u)) != null)')" = false ] || continue
      if [ "$("$registry" list --team "$bteam" | jq 'any(.[]; (.pr // "") != "")')" = true ]; then
        "$registry" add-pr "$bname" "$purl" >/dev/null || continue
      else
        "$registry" set "$bname" pr="$purl" >/dev/null || continue
      fi
      told=true
      "$FLEET_SCRIPTS/tell.sh" "$bteam/lead" "PR $purl is open; start the tester" >/dev/null 2>&1 || { told=false; warn "could not tell $bteam/lead about $purl"; }
      if [ "$(jq --arg u "$purl" '(.pr_opened_emitted // []) | index($u) == null' "$STATE_FILE")" = true ]; then
        add_events "$(jq -cn --arg t "$bteam" --arg n "$bname" --arg u "$purl" --argjson told "$told" '[{type: "pr_opened", team: $t, name: $n, url: $u, lead_told: $told}]')"
        st_upd --arg u "$purl" '$st + {pr_opened_emitted: ((($st.pr_opened_emitted // []) + [$u]) | unique)}'
      fi
    done < <(jq -r --slurpfile rows <(printf '%s' "$drows") --argjson teams "$dteams" --arg repo "$brepo" "$HEAD_TEAM_JQ"'$rows[0] as $rows
      | [.[]? | select(type == "object" and (.state // "OPEN") == "OPEN" and (.isCrossRepository // false) == false)
          | (.headRefName // "") as $h | ($h | head_team($rows)) as $t
          | select($t != null and ($teams | index($t)) != null and any($rows[]; .team == $t and (.repo // "") == $repo))
          | [$rows[] | select(.team == $t and .tier == "Worker")] as $w
          | [$t, (([$w[] | select((.branch // "") == $h)] + [$w[] | select(.name | endswith("/builder"))] + $w) | first | .name), .url]]
      | unique_by(.[2])[] | @tsv' <<<"$found" 2>/dev/null)
  done < <(jq -r --argjson teams "$dteams" '[.[] | select(.team as $t | $teams | index($t)) | .repo // empty | select(. != "")] | unique[]' <<<"$drows")
fi

# --- pull requests ----------------------------------------------------------------------------
# A malformed row (pr, repo or signoff of the wrong type) is skipped with a warning; it never aborts the tick.
# Only a tester row of the PR's own team can sign a PR off.
all_rows="$("$registry" list ${team:+--team "$team"})"
badrows="$(printf '%s' "$all_rows" | jq -r '[.[] | select(type == "object") | select(((.pr // "") | type) != "string" or ((.repo // "") | type) != "string"
  or (.signoff != null and ((.signoff | type) != "object" or ((.signoff.sha // "") | type) != "string")) ) | (.name // "?" | tostring)] | join(", ")')"
[ -z "$badrows" ] || warn "skipping malformed row(s) for PR checks: $badrows"
prs="$(printf '%s' "$all_rows" | jq -c '
  [.[] | select(type == "object" and .status == "Parked") | .team] as $parked
  | [.[] | select(type == "object") | select(((.pr // "") | type) == "string" and ((.repo // "") | type) == "string"
      and (.signoff == null or ((.signoff | type) == "object" and ((.signoff.sha // "") | type) == "string")))
    | select(.status != "Retired")
    | . as $r | ([$r.pr // empty] + (if ($r.prs | type) == "array" then [$r.prs[] | strings] else [] end) | map(select(. != "")) | unique)[] as $u | $r + {pr: $u}]
  | group_by(.pr) | map(. as $g | {pr: .[0].pr, team: .[0].team, name: .[0].name, repo: (.[0].repo // ""),
      signoff: ([$g[] | select((.signoff | objects | .sha) != null and ((.name // "") | endswith("/tester")) and .team == $g[0].team) | .signoff.sha] | first // null),
      park_after_merge: ([$g[] | .park_after_merge // empty] | first // null), parked: (($parked | index($g[0].team)) != null)})')"
read_now=(); ready_now=(); unknown_now=(); merged_now=(); conflicting=() # this tick's view of each PR, for the conflict rule below
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
      # Ready is one rule (common.sh PR_DEFS), shared with the merge queue.
      ev="$(jq -cn --argjson p "$p" --slurpfile g <(printf '%s' "$j") --slurpfile stf "$STATE_FILE" --argjson noci "$no_ci" "$PR_DEFS"'
        $g[0] | pr_noci_ok($noci; $p.repo; $p.pr) as $nociok | ((.headRefOid // "") | ascii_downcase) as $head
        | if .state == "MERGED" then
            (if (($stf[0].pr_merged_emitted // []) | index($p.pr)) == null then {type: "pr_merged", team: $p.team, name: $p.name, url: $p.pr} + (if $p.park_after_merge != null then {parks: $p.park_after_merge} else {} end) + (if $p.parked then {parked: true} else {} end) else null end)
          elif (pr_missing($p.signoff; $nociok) | length) == 0 and (($stf[0].pr_ready_emitted // []) | index($p.pr + "@" + $head)) == null
          then {type: "pr_ready", team: $p.team, name: $p.name, url: $p.pr, sha: $head, ci: pr_ci($nociok)}
          else null end')"
      # A PR that must merge after another (common.sh pr_after: "Merge after #N", "Depends on <url>", "Stacked on")
      # is not ready while that one is open: one read-only view per such PR, only for a PR about to be ready.
      if [ "$(printf '%s' "$ev" | jq -r '.type? // ""' 2>/dev/null)" = pr_ready ]; then
        while IFS= read -r tu; do
          [ -n "$tu" ] && [ "$tu" != "$url" ] || continue
          if [ "$(forge_pr_json "$tu" 2>/dev/null | jq -r '.state // ""' 2>/dev/null)" = OPEN ]; then ev=null; break; fi
        done < <(jq -r --arg u "$url" "$PR_DEFS"'pr_after($u)[]' <<<"$j" 2>/dev/null)
      fi
      # A team with another recorded PR still open is not merged: no pr_merged until every PR of the team has merged.
      if [ "$(printf '%s' "$ev" | jq -r '.type? // ""' 2>/dev/null)" = pr_merged ]; then
        while IFS= read -r tu; do
          [ -n "$tu" ] || continue
          if [ "$(forge_pr_json "$tu" 2>/dev/null | jq -r '.state // ""' 2>/dev/null)" = OPEN ]; then ev=null; break; fi
        done < <(printf '%s' "$prs" | jq -r --arg u "$url" --arg t "$(printf '%s' "$p" | jq -r .team)" '.[] | select(.team == $t and .pr != $u) | .pr')
      fi
      # \x1f, not a tab: a tab read collapses an empty field (a null mergeable), shifting the ones after it.
      IFS=$'\x1f' read -r pst pready pmerge phead < <(jq -rn --argjson p "$p" --slurpfile g <(printf '%s' "$j") --argjson noci "$no_ci" "$PR_DEFS"'
        $g[0] | [.state, ((pr_missing($p.signoff; pr_noci_ok($noci; $p.repo; $p.pr)) | length) == 0), (.mergeable // ""), ((.headRefOid // "") | ascii_downcase)]
        | map(tostring) | join("\u001f")')
      read_now+=("$url")
      [ "$pready" != true ] || ready_now+=("$url")
      # GitHub still computing (mergeable unknown, e.g. right after a merge): a ready PR keeps its place in ready_prev.
      [ "$pst" != OPEN ] || [ "$pmerge" = MERGEABLE ] || [ "$pmerge" = CONFLICTING ] || unknown_now+=("$url")
      [ "$pst" != OPEN ] || [ "$pmerge" != CONFLICTING ] || conflicting+=("$url"$'\x1f'"$phead"$'\x1f'"$(printf '%s' "$p" | jq -r .team)"$'\x1f'"$(printf '%s' "$p" | jq -r .parked)"$'\x1f'"$(printf '%s' "$p" | jq -r '(.signoff // "") != ""')")
      # Merged since the last tick (its pr_merged fires now), never a PR merged long ago that is still on a row.
      [ "$(printf '%s' "$ev" | jq -r '.type // ""' 2>/dev/null)" != pr_merged ] || merged_now+=("$url")
      # A head the tester has not signed while the builder is Done or Idle: the lead may have missed that the builder
      # finished. One nudge per (PR, head); never for a parked team.
      pteam="$(printf '%s' "$p" | jq -r .team)"
      bstat="$(printf '%s' "$all_rows" | jq -r --arg t "$pteam" '[.[] | select(type == "object" and .team == $t and ((.name // "") | endswith("/builder")) and .status != "Retired") | .status] | first // ""')"
      if [ "$pst" = OPEN ] && [ -n "$phead" ] && [ "$(printf '%s' "$p" | jq -r .parked)" != true ] && { [ "$bstat" = Done ] || [ "$bstat" = Idle ]; } &&
        printf '%s' "$p" | jq -e --arg h "$phead" '((.signoff // "") | ascii_downcase) as $s | $s == "" or ($h | startswith($s) | not)' >/dev/null &&
        [ "$(jq --arg k "$url@$phead" '(.head_nudged // []) | index($k) == null' "$STATE_FILE")" = true ]; then
        "$FLEET_SCRIPTS/tell.sh" "$pteam/lead" "PR $url head is now ${phead:0:7} and the builder is idle: read its report and start the tester" >/dev/null 2>&1 ||
          warn "could not tell $pteam/lead that $url has a head the tester has not signed"
        st_upd --arg k "$url@$phead" '$st + {head_nudged: ((($st.head_nudged // []) + [$k]) | unique)}'
      fi
      # Signed off (ready) and every agent Done or Idle: the team parks, so its slot frees while the PR waits for its
      # merge (a Parked team does not count). Tried on every tick while that holds, not only on pr_ready's tick (the
      # lead is often still Working then). park.sh refuses work that is not pushed: one warning per (PR, head), and the
      # team keeps its slot until a later tick parks it. An agent still working means no park.
      if [ "$pready" = true ] && [ "$pst" = OPEN ] && [ "$(printf '%s' "$p" | jq -r .parked)" != true ] &&
        [ "$(printf '%s' "$all_rows" | jq --arg t "$pteam" '[.[] | select(type == "object" and .team == $t and .status != "Retired"
          and .tier != "Orchestrator") | .status] | length > 0 and all(. == "Done" or . == "Idle")')" = true ]; then
        if ! "$FLEET_SCRIPTS/park.sh" "$pteam" --reason signed-off >/dev/null 2>"$FLEET_STATE_DIR/park.err" &&
          [ "$(jq --arg k "$url@$phead" '(.park_refused // []) | index($k) == null' "$STATE_FILE")" = true ]; then
          warn "$pteam is signed off but could not park, so it keeps its slot: $(grep -v '^fleet: warning:' "$FLEET_STATE_DIR/park.err" | head -n 1 | sed 's/^fleet: //')"
          st_upd --arg k "$url@$phead" '$st + {park_refused: ((($st.park_refused // []) + [$k]) | unique)}'
        fi
        rm -f "$FLEET_STATE_DIR/park.err"
      fi
      [ "$ev" != "null" ] || continue
      add_events "[$ev]"
      case "$(printf '%s' "$ev" | jq -r .type)" in
        pr_merged)
          for fn in $("$registry" list --team "$(printf '%s' "$ev" | jq -r .team)" | jq -r '.[] | select(.fixing == "true") | .name'); do "$registry" set "$fn" fixing= >/dev/null 2>&1 || true; done
          st_upd --arg u "$url" --argjson all "$(printf '%s' "$prs" | jq -c --arg t "$(printf '%s' "$ev" | jq -r .team)" '[.[] | select(.team == $t) | .pr]')" \
            '$st + {pr_merged_emitted: ((($st.pr_merged_emitted // []) + [$u] + $all) | unique)}'
          # A team marked to park after its merge parks now, instead of taking the next issue.
          pn="$(printf '%s' "$ev" | jq -r '.parks // ""')"
          if [ -n "$pn" ]; then
            "$FLEET_SCRIPTS/park.sh" "$(printf '%s' "$ev" | jq -r .team)" --reason "$pn" >/dev/null 2>"$FLEET_STATE_DIR/park.err" ||
              warn "could not park $(printf '%s' "$ev" | jq -r .team) after its merge: $(head -n 1 "$FLEET_STATE_DIR/park.err" 2>/dev/null)"
            rm -f "$FLEET_STATE_DIR/park.err"
          fi ;;
        pr_ready)
          # The PR is ready again: the team's fix is done, so it no longer goes over the slot limits.
          for fn in $("$registry" list --team "$(printf '%s' "$ev" | jq -r .team)" | jq -r '.[] | select(.fixing == "true") | .name'); do "$registry" set "$fn" fixing= >/dev/null 2>&1 || true; done
          st_upd --argjson e "$ev" '$st + {pr_ready_emitted: ((($st.pr_ready_emitted // []) + [$e.url + "@" + $e.sha]) | unique)}' ;;
      esac
    done < <(printf '%s' "$prs" | jq -c '.[]')
    rm -f "$ghtmp"; ghtmp=""
  fi
fi
# A PR that was ready (in ready_prev: on the tick before, or since then while GitHub said mergeable unknown) or that
# has a recorded sign-off, and conflicts now, leaves the merge queue. Its lead is told once per (PR, head) to bring it
# up to date by merging the base into it (a merge commit, never a rewrite of history) and have the tester sign off
# again. The cause is read from GitHub: the PRs merged into its base since the previous tick that changed files it also
# changes (read-only), else the PRs merged this tick, else "main". A team that is Parked, or has an agent Done or
# Zombie, is brought back first by catchup.sh (builder and tester in their worktrees, the lead briefed), at most twice
# per PR; the third time a P1 escalation asks the user instead. When that is refused (a cap is full) nobody is told and
# the notice says so. A team whose agents are live is only told. The queue's own rebuild does the rest.
mlist=""; [ "${#merged_now[@]}" = 0 ] || mlist="$(printf '%s\n' "${merged_now[@]}" | paste -sd, - | sed 's/,/, /g')"
since="$(jq -r '.last_tick_at // ""' "$STATE_FILE")"
for c in ${conflicting[@]+"${conflicting[@]}"}; do
  IFS=$'\x1f' read -r curl chead cteam cparked csigned <<<"$c"
  jq -e --arg u "$curl" '(.ready_prev // []) | index($u) != null' "$STATE_FILE" >/dev/null || [ "$csigned" = true ] || continue
  [ "$(jq --arg k "$curl@$chead" '(.conflict_told // []) | index($k) == null' "$STATE_FILE")" = true ] || continue
  # the cause: PRs merged into its base since the last tick that share files with it
  cmerged="$mlist"
  if [ -n "$since" ] && command -v "$FLEET_GH" >/dev/null 2>&1; then
    cj="$("$FLEET_GH" pr view "$curl" --json baseRefName,files 2>/dev/null || true)"
    cbase="$(printf '%s' "$cj" | jq -r '.baseRefName // ""' 2>/dev/null || true)"
    crepo="$(printf '%s' "$curl" | sed -E 's#^https?://[^/]+/([^/]+/[^/]+)/pull/.*#\1#')"
    if [ -n "$cbase" ] && [ -n "$crepo" ]; then
      lj="$("$FLEET_GH" pr list --repo "$crepo" --state merged --base "$cbase" --limit 30 --json number,url,mergedAt,files 2>/dev/null || true)"
      cm="$(jq -rn --slurpfile m <(printf '%s' "${lj:-[]}") --slurpfile c <(printf '%s' "${cj:-{\}}") --arg since "$since" --arg u "$curl" '
        ([($c[0].files // [])[] | .path // empty]) as $mine
        | [($m[0] // [])[]? | select(.url != $u and (($since == "") or ((.mergedAt // "") >= $since))
            and ([(.files // [])[] | .path // empty] | any(. as $f | $mine | index($f) != null)))
          | .url] | join(", ")' 2>/dev/null || true)"
      [ -z "$cm" ] || cmerged="$cm"
    fi
  fi
  told=false; refused=""; cby="${cmerged:-}"
  cneed=false
  if [ "$cparked" = true ]; then cneed=true
  elif [ "$("$registry" list --team "$cteam" | jq '[.[] | select(.status != "Retired" and .tier != "Orchestrator") | .status] | any(. == "Done" or . == "Zombie" or . == "Parked")')" = true ]; then cneed=true; fi
  if $cneed; then
    ncatch="$(jq -r --arg k "$curl" '(.catchup_count // {})[$k] // 0' "$STATE_FILE")"
    if [ "$ncatch" -ge 2 ]; then
      refused="$curl was caught up $ncatch times and conflicts again"
      "$registry" escalate "$cteam/lead" P1 "$curl conflicts again after $ncatch catch-ups; merging the base into it did not hold. Look at it yourself or retire $cteam" \
        "look at it myself" "retire $cteam" >/dev/null 2>&1 || true
    elif "$FLEET_SCRIPTS/catchup.sh" "$cteam" "$curl" "$cby" >/dev/null 2>"$FLEET_STATE_DIR/catchup.err"; then
      told=true; st_upd --arg k "$curl" '$st + {catchup_count: (($st.catchup_count // {}) + {($k): ((($st.catchup_count // {})[$k] // 0) + 1)})}'
    else
      refused="$(grep -v '^fleet: warning:' "$FLEET_STATE_DIR/catchup.err" | head -n 1 | sed 's/^fleet: //')"; refused="${refused:-the catch-up failed}"
    fi
    rm -f "$FLEET_STATE_DIR/catchup.err"
  else
    if [ -n "$cby" ]; then cwhy="conflicts after $cby merged"; else cwhy="conflicts with main now"; fi
    "$FLEET_SCRIPTS/tell.sh" "$cteam/lead" "PR $curl $cwhy; bring it up to date by merging origin/main into it (a merge commit, plain git push) and have the tester sign off again" >/dev/null 2>&1 && told=true
  fi
  add_events "$(jq -cn --arg t "$cteam" --arg u "$curl" --arg m "$cby" --argjson told "$told" --arg r "$refused" \
    '[{type: "pr_conflicting", team: $t, name: ($t + "/lead"), url: $u, detail: (if $m != "" then "after " + $m else "with main" end), merged: $m,
       lead_told: $told} + (if $r != "" then {catchup_refused: $r} else {} end)]')"
  st_upd --arg k "$curl@$chead" '$st + {conflict_told: ((($st.conflict_told // []) + [$k]) | unique)}'
done
st_upd --arg at "${FLEET_NOW:-$(now)}" '$st + {last_tick_at: $at}'
# The ready set of the PRs read now replaces theirs; a PR not read this tick (--team) keeps its entry, and so does a
# ready one whose mergeable reads unknown now.
st_upd --argjson read "$(printf '%s\n' ${read_now[@]+"${read_now[@]}"} | jq -Rsc 'split("\n") | map(select(. != ""))')" \
  --argjson ready "$(printf '%s\n' ${ready_now[@]+"${ready_now[@]}"} | jq -Rsc 'split("\n") | map(select(. != ""))')" \
  --argjson unknown "$(printf '%s\n' ${unknown_now[@]+"${unknown_now[@]}"} | jq -Rsc 'split("\n") | map(select(. != ""))')" \
  '($st.ready_prev // []) as $prev | $st + {ready_prev: (($prev - $read) + $ready + ($prev - ($prev - $unknown)) | unique)}'

# --- keep N teams running ------------------------------------------------------------------------------
# target_teams on the orchestrator row (registry.sh set orchestrator target_teams=N). One slot_free wake, once per change,
# only when a team could really start: fewer live teams than the target and than max_teams (counted as boot counts them:
# Parked teams do not); a configured repo (`repos` in config.toml) with fewer live teams than teams_per_repo; and at least
# one open issue nobody holds and nothing blocks (linear.sh candidates, read at most every 10 minutes; any candidate counts
# for any free repo, the Orchestrator picks; without a Linear key this third condition is skipped and the wake says so).
# Forgotten when a condition fails. The Orchestrator answers it by picking and booting (SKILL.md). A fleet-wide count, so
# tick --team skips it.
if [ -z "$team" ]; then
  tgt="$("$registry" get orchestrator 2>/dev/null | jq -r '.target_teams // empty' 2>/dev/null || true)"
  case "$tgt" in "" | *[!0-9]*) tgt="" ;; esac
  if [ -n "$tgt" ]; then
    nlive="$(live_team_count)"; cap="$(max_teams)"; sf_ok=false; sf_note=""; sf_key=""
    if [ "$nlive" -lt "$tgt" ] && [ "$nlive" -lt "$cap" ] && [ "$now_epoch" -ge "$(jq -r '.usage_until // 0' "$STATE_FILE")" ]; then
      freerepos="$(jq -rn --argjson r "$(config_list repos)" --argjson per "$(teams_per_repo)" --argjson live "$("$registry" list --live | jq -c '[.[] | select(.tier != "Orchestrator") | {team, repo: (.repo // "")}] | unique')" '
        if ($r | length) == 0 then "any" else [$r[] | . as $x | select(([$live[] | select(.repo == $x or (.repo | split("/") | last) == ($x | split("/") | last)) | .team] | unique | length) < $per)] | join(",") end')"
      if [ -n "$freerepos" ]; then
        cand="-"; ckeyless=false
        if "$FLEET_SCRIPTS/linear.sh" has-key >/dev/null 2>&1; then
          cc="$(jq -c --argjson now "$now_epoch" '(.cand_cache // null) | select(. != null and ($now - .at) < 600)' "$STATE_FILE")"
          if [ -z "$cc" ]; then
            if cj="$("$FLEET_SCRIPTS/linear.sh" candidates 2>/dev/null)" && printf '%s' "$cj" | jq -e 'type == "array"' >/dev/null 2>&1; then
              cc="$(jq -cn --argjson at "$now_epoch" --argjson ids "$cj" '{at: $at, ids: $ids}')"; st_upd --argjson c "$cc" '$st + {cand_cache: $c}'
            fi
          fi
          if [ -n "$cc" ]; then
            held="$("$registry" list | jq -c '[.[] | select(.status != "Retired" and (.issue // "") != "") | .issue] | unique')"
            cand="$(jq -rn --argjson c "$cc" --argjson held "$held" '[$c.ids[] | select(. as $i | $held | index($i) | not)] | sort | join(",")')"
          else ckeyless=true; sf_note="; candidates could not be read"; fi
        else ckeyless=true; sf_note="; no Linear key, candidates not checked"; fi
        if $ckeyless || [ -n "$cand" ]; then
          sf_ok=true; sf_key="$nlive|$tgt|$freerepos|$(printf '%s' "$cand" | cksum | awk '{print $1}')"
        fi
      fi
    fi
    if $sf_ok; then
      if [ "$(jq -r '.slot_free_emitted // ""' "$STATE_FILE")" != "$sf_key" ]; then
        add_events "$(jq -cn --argjson n "$nlive" --argjson t "$tgt" --argjson fx "$("$registry" list --live | jq '[.[] | select(.fixing == "true") | .team] | unique | length')" --arg note "$sf_note" '[{type: "slot_free", team: "", name: "", live: $n, target: $t, fixing: $fx, detail: "\($n) live < target \($t)\($note)"}]')"
        st_upd --arg k "$sf_key" '$st + {slot_free_emitted: $k}'
      fi
    else
      st_upd '$st | del(.slot_free_emitted)'
    fi
  fi
fi

# --- repos without a team ---------------------------------------------------------------------
# A parked team still covers its repo.
live="$("$registry" list | jq -c '[.[] | select(.tier != "Orchestrator" and (.status | IN("Done", "Retired") | not)) | .repo // ""]')"
bare="$(jq -cn --argjson r "$(config_list repos)" --argjson live "$live" '
  [$r[] | . as $x | select(([$live[] | select(. == $x or (split("/") | last) == ($x | split("/") | last))] | length) == 0)]')"
add_events "$(jq -cn --argjson b "$bare" --slurpfile stf "$STATE_FILE" '
  [$b[] | select((($stf[0].repo_idle_emitted // []) | index(.)) == null) | {type: "repo_without_team", team: "", name: ., repo: .}]')"
st_upd --argjson b "$bare" '$st + {repo_idle_emitted: $b}'

# --- disk ---------------------------------------------------------------------------------------
if free="$(free_gb)"; then
  warn_at="$(warn_free_gb)"; was="$(jq -r '.disk // "ok"' "$STATE_FILE")"; now_d=ok
  [ "$free" -ge "$warn_at" ] || now_d=low
  if [ "$now_d" != "$was" ]; then
    add_events "$(jq -cn --arg t "$([ "$now_d" = low ] && echo disk || echo disk_ok)" --argjson f "$free" --argjson w "$warn_at" \
      '[{type: $t, team: "", name: "disk", free_gb: $f, warn_free_gb: $w}]')"
  fi
  st_upd --arg d "$now_d" '$st + {disk: $d}'
fi

# --- prune: disk the fleet's tools fill ------------------------------------------------------------------------
# At most once an hour (prune_at), fleet-wide (not with --team). It measures what the fleet holds (its worktrees, the
# Go cache, what the docker prune can free) for the status disk line, and prunes when free disk is below warn_free_gb
# or a measured size passes prune_cap_gb (default 20): `go clean -cache` when the Go cache is over the cap or the disk
# is low; docker's dangling anonymous volumes (64-hex names only: a named volume is never touched, and never `docker
# volume prune`, whose meaning changed across Docker versions), its build cache (`builder prune -f`) and dangling
# images (`image prune -f`) when the build cache plus the dangling images pass the cap or the disk is low (unused
# tagged images and named volumes, which no step removes, never trigger it, or the build cache would go every hour).
# A missing tool skips its step with one warning. What the free disk gained is kept as the last reclaim.
if [ -z "$team" ] && [ $((now_epoch - $(jq -r '.prune_at // 0' "$STATE_FILE"))) -ge 3600 ]; then
  pcap="$(cfg_int prune_cap_gb 20)"; gobin="${FLEET_GO:-go}"; dk="${FLEET_DOCKER:-docker}"
  gocache=""; go_gb=0; dk_gb=0; have_dk=false; command -v "$dk" >/dev/null 2>&1 && have_dk=true
  if command -v "$gobin" >/dev/null 2>&1; then gocache="$("$gobin" env GOCACHE 2>/dev/null || true)"; go_gb="$(du_gb "$gocache")"; fi
  ! $have_dk || dk_gb="$(docker_prunable_gb)"
  held=$(($(du_gb "$FLEET_WORKTREES") + go_gb + dk_gb))
  f0="$(free_gb 2>/dev/null || true)"; low=false; [ -z "$f0" ] || [ "$f0" -ge "$(warn_free_gb)" ] || low=true
  pruned=false
  if $low || [ "$go_gb" -gt "$pcap" ]; then
    if [ -n "$gocache" ]; then "$gobin" clean -cache >/dev/null 2>&1 || warn "go clean -cache failed"; pruned=true
    else warn "go not found; the Go cache is not pruned"; fi
  fi
  if $low || [ "$dk_gb" -gt "$pcap" ]; then
    if $have_dk; then
      while IFS= read -r v; do
        anon_volume "$v" || continue
        "$dk" volume rm "$v" >/dev/null 2>&1 || warn "could not remove the dangling volume $v"
      done < <("$dk" volume ls -q --filter dangling=true 2>/dev/null || true)
      "$dk" builder prune -f >/dev/null 2>&1 || warn "docker builder prune failed"
      "$dk" image prune -f >/dev/null 2>&1 || warn "docker image prune failed"
      pruned=true
    else warn "docker not found; its volumes, build cache and images are not pruned"; fi
  fi
  rec="$(jq -r '.reclaimed_gb // 0' "$STATE_FILE")"
  if $pruned; then f1="$(free_gb 2>/dev/null || true)"; rec=0; [ -z "$f0" ] || [ -z "$f1" ] || [ "$f1" -le "$f0" ] || rec=$((f1 - f0)); fi
  [ "$held" -ge "$rec" ] || rec="$held"
  held_after="$held"; ! $pruned || held_after=$((held - rec))
  st_upd --argjson at "$now_epoch" --argjson h "$held_after" --argjson r "$rec" '$st + {prune_at: $at, held_gb: $h, reclaimed_gb: $r}'
fi

# --- archive: weekly, and on every tick that finds fleet.json over the size cap ----------------------------------
# Past the cap (REGISTRY_CAP_KB, 512) `registry.sh archive` also moves the Retired rows with no lessons; when it did,
# one notice says how many (a reply line, not a wake).
week="$(date +%G-W%V)"; cap_kb="$(const_int REGISTRY_CAP_KB 512)"; reg_kb=$((($(wc -c <"$FLEET_REGISTRY" | tr -d ' ') + 1023) / 1024))
if [ "$(jq -r '.archive_week // ""' "$STATE_FILE")" != "$week" ] || [ "$reg_kb" -gt "$cap_kb" ]; then
  if moved="$("$registry" archive 2>/dev/null)"; then
    if [ "$reg_kb" -gt "$cap_kb" ]; then
      n="$(jq --slurpfile m <(printf '%s' "$moved") '. as $a | [$m[0][] | $a.agents[.].lessons // "" | select(test("^Archived .* without a debrief \\(fleet.json over"))] | length' "$FLEET_ARCHIVE" 2>/dev/null || echo 0)"
      [ "${n:-0}" = 0 ] || notice_add "$(render_line archived n="$n" kb="$reg_kb" cap="$cap_kb")" '{"type": "archived"}'
    fi
  else warn "archive failed"; fi
  st_upd --arg w "$week" '$st + {archive_week: $w}'
fi

# --- weekly summary ---------------------------------------------------------------------------------
sweek="$(date +%G-W%V)"; prev_week="$(jq -r '.summary_week // ""' "$STATE_FILE")"
if [ -n "$prev_week" ] && [ "$prev_week" != "$sweek" ]; then
  add_events "$(jq -cn --arg w "$sweek" '[{type: "weekly_summary", team: "", name: "", week: $w, detail: "the weekly metrics and their report are in the notice"}]')"
fi
st_upd --arg w "$sweek" '$st + {summary_week: $w}'

# --- herdr's panel ---------------------------------------------------------------------------------------------
# A team whose state, PR or issue changed since the last tick shows it on herdr's panel again (common.sh herdr_meta);
# a team that did not change is not reported. meta_seen holds what each team showed last.
while IFS=$'\t' read -r mteam msig; do
  [ -n "$mteam" ] || continue
  [ "$(jq -r --arg t "$mteam" '(.meta_seen // {})[$t] // ""' "$STATE_FILE")" != "$msig" ] || continue
  herdr_meta "$mteam"
  st_upd --arg t "$mteam" --arg s "$msig" '$st + {meta_seen: (($st.meta_seen // {}) + {($t): $s})}'
done < <("$registry" list ${team:+--team "$team"} | jq -r "$RENDER_DEFS"'[.[] | select(.status != "Retired" and .tier != "Orchestrator" and (.team // "") != "")]
  | group_by(.team)[] | [.[0].team, ((if any(.[]; .status == "Parked") then "Parked" else (map(.status | word) | sort_by(rank) | last) end)
    + "|" + ([.[].pr // empty] | first // "") + "|" + ([.[].issue // empty] | first // ""))] | @tsv')

# --- morning report ----------------------------------------------------------------------------------------
# Overnight mode (overnight = true in config.toml): the first tick on or after 07:00 local time each day (the
# FLEET_MORNING_HOUR constant) writes the morning report (metrics.sh --morning) to reports/fleet-morning-<date>.md
# (common.sh report_dir: the Orchestrator's cwd) and wakes with its path, once per date.
if [ -z "$team" ] && [ "$(cfg_bool overnight false)" = true ]; then
  mday="$(local_time "$now_epoch" %Y-%m-%d)"
  if [ "$(local_time "$now_epoch" %H | sed 's/^0//')" -ge "$(const_int MORNING_HOUR 7)" ] && [ "$(jq -r '.morning_date // ""' "$STATE_FILE")" != "$mday" ]; then
    mpath="$(report_dir)/fleet-morning-$mday.md"
    if mkdir -p "$(dirname "$mpath")" && FLEET_NOW="$now_iso" "$FLEET_SCRIPTS/metrics.sh" --morning >"$mpath" 2>/dev/null; then
      add_events "$(jq -cn --arg p "$mpath" --arg d "$mday" '[{type: "morning_report", team: "", name: "", path: $p, date: $d, detail: ("the morning report is " + $p)}]')"
    else warn "could not write the morning report to $mpath"; fi
    st_upd --arg d "$mday" '$st + {morning_date: $d}'
  fi
fi

# --- what changed for the owner: the status table, and the set of PRs ready to merge ---------------------------------
# The team table and the merge queue are the status reply. When their signature changes (a team starts, finishes or
# fails, a PR turns ready, conflicts or merges, the merge order moves, something needs the owner) one status_changed wake
# goes out, at most once every status_mins (the [run] profile, 10): changes in between wait for the next window. When the
# ready set changes (to a non-empty set) the same wake carries the push text "2 ready: merge #A, then #B", at most once
# every merge_push_mins (15). Nothing changed, nothing sent. The first look only records the signatures. A fleet-wide
# count, so tick --team skips it.
q_built=""
if [ -z "$team" ]; then
  q_built="$("$FLEET_SCRIPTS/queue.sh" 2>/dev/null)" || q_built=""
  [ -z "$q_built" ] || {
    tsig="$(render_table --queue "$q_built" 2>/dev/null | cksum | awk '{print $1}')"
    rnow="$(jq -r '[(.ready // [])[] | .url] | join(" ")' <<<"$q_built")"
    rtxt="$(jq -r '(.ready // []) as $r | ($r | map(.url | capture("^https?://[^/]+/(?<o>[^/]+)/(?<r>[^/]+)/pull/(?<n>[0-9]+)")) | map(.r) | unique | length > 1) as $multi
      | if ($r | length) == 0 then "" else "\($r | length) ready: merge " + ([$r[] | .url | capture("^https?://[^/]+/[^/]+/(?<r>[^/]+)/pull/(?<n>[0-9]+)") | (if $multi then .r else "" end) + "#" + .n] | join(", then ")) end' <<<"$q_built")"
    if [ "$(jq -r 'has("status_sig")' "$STATE_FILE")" != true ]; then
      st_upd --arg s "$tsig" --arg r "$rnow" --argjson n "$now_epoch" '$st + {status_sig: $s, ready_sig: $r, status_sent_at: $n, ready_sent_at: $n}'
    else
      s_due=false; r_due=false
      [ "$tsig" = "$(jq -r '.status_sig' "$STATE_FILE")" ] || [ $((now_epoch - $(jq -r '.status_sent_at // 0' "$STATE_FILE"))) -lt $(($(run_int status_mins 10) * 60)) ] || s_due=true
      if [ "$rnow" != "$(jq -r '.ready_sig // ""' "$STATE_FILE")" ]; then
        if [ -z "$rnow" ]; then st_upd '$st + {ready_sig: ""}'
        elif [ $((now_epoch - $(jq -r '.ready_sent_at // 0' "$STATE_FILE"))) -ge $(($(run_int merge_push_mins 15) * 60)) ]; then r_due=true; fi
      fi
      if $s_due || $r_due; then
        add_events "$(jq -cn --arg r "$([ "$r_due" = true ] && printf '%s' "$rtxt")" '[{type: "status_changed", team: "", name: "", detail: "the status table changed"} + (if $r != "" then {ready: $r} else {} end)]')"
        st_upd --arg s "$tsig" --argjson n "$now_epoch" '$st + {status_sig: $s, status_sent_at: $n}'
        ! $r_due || st_upd --arg r "$rnow" --argjson n "$now_epoch" '$st + {ready_sig: $r, ready_sent_at: $n}'
      fi
    fi
  }
fi

# --- the event log ------------------------------------------------------------------------------------
while IFS=$'\t' read -r etype eteam ename eurl esha eissue edetail; do
  [ -n "$etype" ] || continue
  [ "$eurl" != - ] || eurl=""; [ "$esha" != - ] || esha=""; [ "$eteam" != - ] || eteam=""; [ "$ename" != - ] || ename=""
  [ "$eissue" != - ] || eissue=""; [ "$edetail" != - ] || edetail=""
  ev_log "$etype" team="$eteam" name="$ename" pr="$eurl" sha="$esha" issue="$eissue" detail="$edetail"
done < <(jq -r 'def d: if . == null or . == "" then "-" else tostring end;
  .[] | select(.type | IN("pr_opened", "pr_ready", "pr_merged", "pr_conflicting", "stalled", "dead", "failed", "needs_input", "stale_version", "slot_free", "usage_limit", "status_changed",
    "claim_takeover", "claim_lost", "claim_released", "claim_held_pr", "claim_lapsed", "morning_report"))
  | [.type, (.team | d), (.name | d), (.url | d), (.sha | d), (if (.type | startswith("claim_")) then (.issue | d) else "-" end),
     (if .type == "claim_lost" then "claimed by this machine, released by another"
      elif (.type | startswith("claim_")) then ("holder " + (.holder // "?") + (if .detail then ": " + .detail else "" end))
      elif (.type | IN("pr_conflicting", "morning_report")) then (.detail | d) else "-" end)] | @tsv' "$EVENTS_FILE")

# --- notices: each wake's reply, rendered once for `fleet status` (references/output.md) --------------------------
while IFS= read -r ev; do
  [ -n "$ev" ] || continue
  txt="$(render_notice "$ev" 2>/dev/null)" || txt=""
  [ -z "$txt" ] || notice_add "$txt" "$ev"
done < <(jq -c --arg wake "$WAKE_TYPES" ".[] | $WAKE_JQ" "$EVENTS_FILE")

# The state is rebuilt from what is live, so it cannot grow without bound: reported-once keys survive only while
# the thing they describe (a PR on a row, an open escalation, a claimed issue, a recent respawn) still exists.
live_prs="$("$registry" list | jq -c '[.[] | select(.status != "Retired") | (.pr // empty), (.prs // [])[]]')"
live_esc="$("$registry" escalations --open | jq -c '[.[] | .name + "|" + .id]')"
live_claims="$("$registry" list --live | jq -c '[.[] | select((.issue // "") != "") | .team + "|" + .issue]')"
live_names="$("$registry" list --live | jq -c '[.[] | .name]')"
live_teams="$("$registry" list --live | jq -c '[.[] | .team // empty] | unique')"
st_upd --argjson prs "$live_prs" --argjson esc "$live_esc" --argjson cl "$live_claims" --argjson live_names "$live_names" --argjson live_teams "$live_teams" --argjson now "$now_epoch" --argjson w "$(const_int RESPAWN_WINDOW_HOURS 6)" '
  def inrecent: map(select(. > $now - $w * 3600));
  $st
  + (if .pr_ready_emitted then {pr_ready_emitted: [.pr_ready_emitted[] | select(split("@")[0] as $u | $prs | index($u))]} else {} end)
  + (if .head_nudged then {head_nudged: [.head_nudged[] | select(split("@")[0] as $u | $prs | index($u))]} else {} end)
  + (if .park_refused then {park_refused: [.park_refused[] | select(split("@")[0] as $u | $prs | index($u))]} else {} end)
  + (if .pr_merged_emitted then {pr_merged_emitted: [.pr_merged_emitted[] | select(. as $u | $prs | index($u))]} else {} end)
  + (if .pr_opened_emitted then {pr_opened_emitted: [.pr_opened_emitted[] | select(. as $u | $prs | index($u))]} else {} end)
  + (if .ready_prev then {ready_prev: [.ready_prev[] | select(. as $u | $prs | index($u))]} else {} end)
  + (if .conflict_told then {conflict_told: [.conflict_told[] | select(split("@")[0] as $u | $prs | index($u))]} else {} end)
  + (if .escalations_emitted then {escalations_emitted: [.escalations_emitted[] | select(. as $k | $esc | index($k))]} else {} end)
  + (if .takeover_emitted then {takeover_emitted: [.takeover_emitted[] | select(split("|")[0:2] | join("|") as $k | $cl | index($k))]} else {} end)
  + (if .lost_emitted then {lost_emitted: [.lost_emitted[] | select(. as $k | $cl | index($k))]} else {} end)
  + (if .stale_emitted then {stale_emitted: [.stale_emitted[] | select(split("|")[0] as $t | $live_teams | index($t))]} else {} end)
  + (if .brief_failed_emitted then {brief_failed_emitted: [.brief_failed_emitted[] | select(split("|")[0] as $n | $live_names | index($n))]} else {} end)
  + (if .respawns then {respawns: (.respawns | with_entries(.value |= inrecent) | with_entries(select(.value | length > 0)))} else {} end)'
tick_state_write "$(cat "$STATE_FILE")"
# The merge queue, built once here for every status until the next tick (common.sh fleet_queue).
if [ -z "$team" ] && q="${q_built:-$("$FLEET_SCRIPTS/queue.sh" 2>/dev/null)}" && [ -n "$q" ]; then queue_write "$q"; fi
[ "$(jq length "$EVENTS_FILE")" = 0 ] || cat "$EVENTS_FILE"
