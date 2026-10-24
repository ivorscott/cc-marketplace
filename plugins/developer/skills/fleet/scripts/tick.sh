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
#   pr_opened       a live builder on a fleet/ branch has an open PR the row doesn't know yet
#                   (gh pr list --head, even when the builder skipped its done step): recorded as
#                   the row's pr, the lead is told to start the tester. Once per PR.
#   pr_ready        the row's PR is open, mergeable, checks green (or none exist and the repo is in
#                   no_pr_ci in config.toml), the tester's signed-off SHA is the PR head, and the
#                   body has no "DO NOT MERGE", "merge order", "before/after", "merge after/before" or "stacked on",
#                   and the PR is not a draft (a stacked child must not go ready before its parent). Once per (PR, head SHA).
#                   While a team's PR is ready and every agent of the team is Done or Idle, on that tick or a later one,
#                   it is parked (park.sh --reason signed-off) to free its slot.
#   pr_merged       the row's PR was merged; the Orchestrator answers with next.sh. Once per PR. A team marked
#                   park --after-merge (or by focus) is parked by tick instead; the event says `parks`.
#   pr_conflicting  after this tick's merge, a PR that was ready on the tick before is CONFLICTING: it leaves the merge
#                   queue, its team is unparked if parked, and its lead is told to bring it up to date with main and
#                   have the tester sign off again. Once per (PR, head); `unpark_refused` when a cap kept it parked.
#   repo_without_team  a repo in config.toml `repos` with no live team, when it becomes so
#   disk, disk_ok   free disk crossed below warn_free_gb, and recovered
#   slot_free       fewer live teams than target_teams (orchestrator row) and max_teams: the Orchestrator picks and
#                   boots. Once per (live count, target)
#   claim_takeover  a team's issue now carries another machine's label (once per team, issue and holder)
#   claim_released  another machine's lapsed claim with no open PR was released (linear.sh release --lapsed)
#   claim_held_pr   another machine's lapsed claim has an open PR, so it was left alone
#   claim_lapsed    another machine's claim lapsed (writes off, test mode) or has no heartbeat; left alone, read-only.
#                   The three claim_ events: once per (issue, holder, heartbeat); not with --team
#   claims_unavailable  teams hold issues but no Linear key is configured (once)
#   claims_readonly     teams hold issues and a key exists, but linear_writes = off (once)
# With a key and linear_writes allowing it, every tick makes ONE heartbeat mutation (linear.sh heartbeat);
# with a key, one read per claimed issue (holder), Done rows included. Tick never runs linear.sh migrate.
# Once a week (ISO week, in the state file) tick also runs `registry.sh archive`.
# One tick at a time: tick.lock (mkdir; pid and start time inside). A tick that finds a held lock exits 0
# quietly (tick_skipped on stderr); a lock whose holder pid is no longer running is recovered.
# PR state is read with `gh pr view` / `gh pr list` (FLEET_GH), read-only. A gh failure for one PR is logged on
# stderr and skips that PR for this tick; no gh on PATH is one warning and no PR events.
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"
config_warn_unknown

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
add_events() { jq -c --argjson b "$1" '. + $b' "$EVENTS_FILE" >"$EVENTS_FILE.new" && mv "$EVENTS_FILE.new" "$EVENTS_FILE"; }

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
      [ "$rows_n" = 0 ] ||
        "$FLEET_SCRIPTS/linear.sh" heartbeat >/dev/null 2>&1 || warn "linear.sh heartbeat failed"
    fi
  elif [ "$rows_n" != 0 ] && [ "$(jq -r '.claims_unavailable_emitted // false' "$STATE_FILE")" != true ]; then
    add_events '[{"type": "claims_unavailable", "team": "", "name": "", "detail": "no Linear key; heartbeat and takeover checks are off"}]'
    st_upd '$st + {claims_unavailable_emitted: true}'
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
    if [ "$(jq --arg k "$t|$i|$h" '(.takeover_emitted // []) | index($k) == null' "$STATE_FILE")" = true ]; then
      add_events "$(jq -cn --arg t "$t" --arg i "$i" --arg h "$h" '[{type: "claim_takeover", team: $t, name: ($t + "/lead"), issue: $i, holder: $h}]')"
      st_upd --arg k "$t|$i|$h" '$st + {takeover_emitted: ((($st.takeover_emitted // []) + [$k]) | unique)}'
    fi
  done < <(printf '%s' "$claim_rows" | jq -r '[.[] | [.team, .issue]] | unique[] | @tsv')
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
      [ -d "$d" ] && git -C "$d" remote get-url origin 2>/dev/null | sed -E 's#^(git@[^:]+:|[a-z]+://([^@/]+@)?[^/]+/)##; s#\.git$##'
    done | grep -E '^[^/[:space:]]+/[^/[:space:]]+$' | sort -u | paste -sd' ' -)" || repos=""
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
heartbeat
claims_taken_over
claims_lapsed

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
  add_events "$(jq -cn --argjson rows "$rows" --slurpfile stf "$STATE_FILE" '
    [$rows[] | select(.tier != "Orchestrator" and .status == "Failed" and (($stf[0].status // {})[.name] != .status))
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
  add_events "$(jq -cn --argjson rows "$rows" --slurpfile stf "$STATE_FILE" '
    [$rows[] | (.name + "|" + (.status_detail // "")) as $k
      | select(.tier != "Orchestrator" and .status == "Needs input" and (.status_detail // "") != ""
        and ((($stf[0].needs_input_emitted // []) | index($k)) == null))
      | {type: "needs_input", team, name, detail: .status_detail}]')"
  # Only the rows this tick read are re-derived: a --team tick keeps the other teams' keys.
  st_upd --argjson rows "$rows" '[$rows[].name] as $seen
    | $st + {needs_input_emitted: ([($st.needs_input_emitted // [])[] | select(split("|")[0] as $n | $seen | index($n) | not)]
        + [$rows[] | select(.status == "Needs input" and (.status_detail // "") != "") | .name + "|" + .status_detail])}'
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
  st_upd --argjson rows "$rows" '$st + {status: (($st.status // {}) + ([$rows[] | {(.name): .status}] | add // {})),
    dead_emitted: (($st.dead_emitted // []) - [$rows[] | select(.status != "Zombie") | .name])}'
else
  warn "status.sh failed; no stalled/dead events this tick"
fi

# --- stale plugin version ------------------------------------------------------------------------------
# A team with a row booted (or restarted) by an older plugin than the one installed now. Its restart at the next
# `next.sh` (never mid-task) would switch it, and that waits for the user's go (next.sh and respawn.sh --restart
# refuse with exit 5 until FLEET_VERSION_OK=1), so this asks, once per (team, installed version), naming the
# team's first stale row, the lead first.
iv="$(installed_version)"
if [ -n "$iv" ]; then
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
add_events "$(jq -cn --argjson e "$esc" --slurpfile stf "$STATE_FILE" '
  [$e[] | select(((.name + "|" + .id) as $k | ($stf[0].escalations_emitted // []) | index($k)) == null)
    | {type: "escalation", team, name, id, severity, message, options: (.options // []), at}]')"
st_upd --argjson e "$esc" '
  $st + {escalations_emitted: ((($st.escalations_emitted // []) + [$e[] | .name + "|" + .id]) | unique)}'

# --- PR discovery: a builder's PR found by the branch its worktree is on ---------------------------------
# Boot records fleet/<team>/<role>, but a builder pushes fleet/<slug>: the branch is read from the worktree
# (git branch --show-current), falling back to the row, and written back to the row. Only same-repository
# PRs count (gh pr list --head also returns fork PRs, and the repo is public).
if command -v "$FLEET_GH" >/dev/null 2>&1; then
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    bname="$(printf '%s' "$b" | jq -r .name)"; rowbranch="$(printf '%s' "$b" | jq -r '.branch // ""')"; brepo="$(printf '%s' "$b" | jq -r '.repo // ""')"
    bwt="$(printf '%s' "$b" | jq -r '.worktree // ""')"; bbranch=""
    if [ -n "$bwt" ] && [ -d "$bwt" ]; then bbranch="$(git -C "$bwt" branch --show-current 2>/dev/null || true)"; fi
    [ -n "$bbranch" ] || bbranch="$rowbranch"
    case "$bbranch" in fleet/*) ;; *) continue ;; esac
    if [ "$bbranch" != "$rowbranch" ]; then "$registry" set "$bname" branch="$bbranch" >/dev/null || warn "could not write $bname's branch back"; fi
    if [ ! -d "$brepo" ]; then warn "cannot look for $bname's PR: repo '$brepo' is not a directory"; continue; fi
    if ! found="$(cd "$brepo" && "$FLEET_GH" pr list --head "$bbranch" --json number,url,headRefOid,state,isCrossRepository 2>/dev/null)"; then
      warn "gh could not list PRs for $bbranch"; continue
    fi
    purl="$(printf '%s' "$found" | jq -r '[.[]? | select(.state == "OPEN" and ((.isCrossRepository // false) | not))] | first | .url // ""' 2>/dev/null)" || purl=""
    [ -n "$purl" ] || continue
    "$registry" set "$bname" pr="$purl" >/dev/null || continue
    bteam="$(printf '%s' "$b" | jq -r .team)"; told=true
    "$FLEET_SCRIPTS/tell.sh" "$bteam/lead" "PR $purl is open; start the tester" >/dev/null 2>&1 || { told=false; warn "could not tell $bteam/lead about $purl"; }
    if [ "$(jq --arg u "$purl" '(.pr_opened_emitted // []) | index($u) == null' "$STATE_FILE")" = true ]; then
      add_events "$(jq -cn --arg t "$bteam" --arg n "$bname" --arg u "$purl" --argjson told "$told" '[{type: "pr_opened", team: $t, name: $n, url: $u, lead_told: $told}]')"
      st_upd --arg u "$purl" '$st + {pr_opened_emitted: ((($st.pr_opened_emitted // []) + [$u]) | unique)}'
    fi
  done < <("$registry" list ${team:+--team "$team"} | jq -c '.[] | select(.tier == "Worker" and .status != "Retired" and .status != "Parked" and (.pr // "") == "")')
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
    | select(.status != "Retired" and (.pr // "") != "")]
  | group_by(.pr) | map(. as $g | {pr: .[0].pr, team: .[0].team, name: .[0].name, repo: (.[0].repo // ""),
      signoff: ([$g[] | select((.signoff | objects | .sha) != null and ((.name // "") | endswith("/tester")) and .team == $g[0].team) | .signoff.sha] | first // null),
      park_after_merge: ([$g[] | .park_after_merge // empty] | first // null), parked: (($parked | index($g[0].team)) != null)})')"
read_now=(); ready_now=(); merged_now=(); conflicting=() # this tick's view of each PR, for the after-merge rule below
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
      ev="$(jq -cn --argjson p "$p" --argjson g "$j" --slurpfile stf "$STATE_FILE" --argjson noci "$no_ci" "$PR_DEFS"'
        $g | pr_noci_ok($noci; $p.repo; $p.pr) as $nociok | ((.headRefOid // "") | ascii_downcase) as $head
        | if .state == "MERGED" then
            (if (($stf[0].pr_merged_emitted // []) | index($p.pr)) == null then {type: "pr_merged", team: $p.team, name: $p.name, url: $p.pr} + (if $p.park_after_merge != null then {parks: $p.park_after_merge} else {} end) + (if $p.parked then {parked: true} else {} end) else null end)
          elif (pr_missing($p.signoff; $nociok) | length) == 0 and (($stf[0].pr_ready_emitted // []) | index($p.pr + "@" + $head)) == null
          then {type: "pr_ready", team: $p.team, name: $p.name, url: $p.pr, sha: $head, ci: pr_ci($nociok)}
          else null end')"
      IFS=$'\t' read -r pst pready pmerge phead < <(jq -rn --argjson p "$p" --argjson g "$j" --argjson noci "$no_ci" "$PR_DEFS"'
        $g | [.state, ((pr_missing($p.signoff; pr_noci_ok($noci; $p.repo; $p.pr)) | length) == 0), (.mergeable // ""), ((.headRefOid // "") | ascii_downcase)] | @tsv')
      read_now+=("$url")
      [ "$pready" != true ] || ready_now+=("$url")
      [ "$pst" != OPEN ] || [ "$pmerge" != CONFLICTING ] || conflicting+=("$url"$'\t'"$phead"$'\t'"$(printf '%s' "$p" | jq -r .team)"$'\t'"$(printf '%s' "$p" | jq -r .parked)")
      [ "$pst" != MERGED ] || merged_now+=("$url")
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
          st_upd --arg u "$url" '$st + {pr_merged_emitted: ((($st.pr_merged_emitted // []) + [$u]) | unique)}'
          # A team marked to park after its merge parks now, instead of taking the next issue.
          pn="$(printf '%s' "$ev" | jq -r '.parks // ""')"
          if [ -n "$pn" ]; then
            "$FLEET_SCRIPTS/park.sh" "$(printf '%s' "$ev" | jq -r .team)" --reason "$pn" >/dev/null 2>"$FLEET_STATE_DIR/park.err" ||
              warn "could not park $(printf '%s' "$ev" | jq -r .team) after its merge: $(head -n 1 "$FLEET_STATE_DIR/park.err" 2>/dev/null)"
            rm -f "$FLEET_STATE_DIR/park.err"
          fi ;;
        pr_ready)
          st_upd --argjson e "$ev" '$st + {pr_ready_emitted: ((($st.pr_ready_emitted // []) + [$e.url + "@" + $e.sha]) | unique)}' ;;
      esac
    done < <(printf '%s' "$prs" | jq -c '.[]')
    rm -f "$ghtmp"; ghtmp=""
  fi
fi
# After a merge: a PR that was ready the tick before and conflicts now leaves the merge queue. Its lead is told once
# per (PR, head) to bring it up to date with main (as the house rules say: a merge commit in overnight mode) and have
# the tester sign off again; a parked team is unparked first,
# and when that is refused (a cap is full) nobody is told and the notice says so. The queue's own rebuild does the rest.
if [ "${#merged_now[@]}" -gt 0 ]; then
  mlist="$(printf '%s\n' "${merged_now[@]}" | paste -sd, - | sed 's/,/, /g')"
  for c in ${conflicting[@]+"${conflicting[@]}"}; do
    IFS=$'\t' read -r curl chead cteam cparked <<<"$c"
    jq -e --arg u "$curl" '(.ready_prev // []) | index($u) != null' "$STATE_FILE" >/dev/null || continue
    [ "$(jq --arg k "$curl@$chead" '(.conflict_told // []) | index($k) == null' "$STATE_FILE")" = true ] || continue
    told=false; refused=""
    if [ "$cparked" = true ] && ! "$FLEET_SCRIPTS/unpark.sh" "$cteam" >/dev/null 2>"$FLEET_STATE_DIR/unpark.err"; then
      refused="$(grep -v '^fleet: warning:' "$FLEET_STATE_DIR/unpark.err" | head -n 1 | sed 's/^fleet: //')"; refused="${refused:-unpark failed}"
    fi
    rm -f "$FLEET_STATE_DIR/unpark.err"
    if [ -z "$refused" ]; then
      "$FLEET_SCRIPTS/tell.sh" "$cteam/lead" "PR $curl conflicts after $mlist merged; bring it up to date with main (as the house rules say) and have the tester sign off again" >/dev/null 2>&1 && told=true
    fi
    add_events "$(jq -cn --arg t "$cteam" --arg u "$curl" --arg m "$mlist" --argjson told "$told" --arg r "$refused" \
      '[{type: "pr_conflicting", team: $t, name: ($t + "/lead"), url: $u, detail: ("after " + $m), merged: $m, lead_told: $told} + (if $r != "" then {unpark_refused: $r} else {} end)]')"
    st_upd --arg k "$curl@$chead" '$st + {conflict_told: ((($st.conflict_told // []) + [$k]) | unique)}'
  done
fi
# The ready set of the PRs read now replaces theirs; a PR not read this tick (--team) keeps its entry.
st_upd --argjson read "$(printf '%s\n' ${read_now[@]+"${read_now[@]}"} | jq -Rsc 'split("\n") | map(select(. != ""))')" \
  --argjson ready "$(printf '%s\n' ${ready_now[@]+"${ready_now[@]}"} | jq -Rsc 'split("\n") | map(select(. != ""))')" \
  '$st + {ready_prev: ((($st.ready_prev // []) - $read) + $ready | unique)}'

# --- keep N teams running ------------------------------------------------------------------------------
# target_teams on the orchestrator row (registry.sh set orchestrator target_teams=N). With fewer live teams than the
# target and than max_teams (counted as boot counts them: Parked teams do not), one slot_free wake, once per (live
# count, target), forgotten when the count recovers. The Orchestrator answers it by picking and booting (SKILL.md).
# A fleet-wide count, so tick --team skips it.
if [ -z "$team" ]; then
  tgt="$("$registry" get orchestrator 2>/dev/null | jq -r '.target_teams // empty' 2>/dev/null || true)"
  case "$tgt" in "" | *[!0-9]*) tgt="" ;; esac
  if [ -n "$tgt" ]; then
    nlive="$(live_team_count)"; cap="$(max_teams)"
    if [ "$nlive" -lt "$tgt" ] && [ "$nlive" -lt "$cap" ]; then
      if [ "$(jq -r '.slot_free_emitted // ""' "$STATE_FILE")" != "$nlive|$tgt" ]; then
        add_events "$(jq -cn --argjson n "$nlive" --argjson t "$tgt" '[{type: "slot_free", team: "", name: "", live: $n, target: $t, detail: "\($n) live < target \($t)"}]')"
        st_upd --arg k "$nlive|$tgt" '$st + {slot_free_emitted: $k}'
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
# Go cache, what docker can reclaim) for the status disk line, and prunes when free disk is below warn_free_gb or a
# measured size passes prune_cap_gb (default 20): `go clean -cache` when the Go cache is over the cap or the disk is
# low; docker's dangling anonymous volumes (64-hex names only: a named volume is never touched, and never `docker
# volume prune`, whose meaning changed across Docker versions), its build cache (`builder prune -f`) and dangling
# images (`image prune -f`) when what docker can reclaim is over the cap or the disk is low. A missing tool skips its
# step with one warning. What the free disk gained is kept as the last reclaim.
if [ -z "$team" ] && [ $((now_epoch - $(jq -r '.prune_at // 0' "$STATE_FILE"))) -ge 3600 ]; then
  pcap="$(cfg_int prune_cap_gb 20)"; gobin="${FLEET_GO:-go}"; dk="${FLEET_DOCKER:-docker}"
  gocache=""; go_gb=0; dk_gb=0; have_dk=false; command -v "$dk" >/dev/null 2>&1 && have_dk=true
  if command -v "$gobin" >/dev/null 2>&1; then gocache="$("$gobin" env GOCACHE 2>/dev/null || true)"; go_gb="$(du_gb "$gocache")"; fi
  ! $have_dk || dk_gb="$(docker_reclaimable_gb)"
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

# --- weekly archive ------------------------------------------------------------------------------
week="$(date +%G-W%V)"
if [ "$(jq -r '.archive_week // ""' "$STATE_FILE")" != "$week" ]; then
  "$registry" archive >/dev/null 2>&1 || warn "weekly archive failed"
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

# --- the event log ------------------------------------------------------------------------------------
while IFS=$'\t' read -r etype eteam ename eurl esha eissue edetail; do
  [ -n "$etype" ] || continue
  [ "$eurl" != - ] || eurl=""; [ "$esha" != - ] || esha=""; [ "$eteam" != - ] || eteam=""; [ "$ename" != - ] || ename=""
  [ "$eissue" != - ] || eissue=""; [ "$edetail" != - ] || edetail=""
  ev_log "$etype" team="$eteam" name="$ename" pr="$eurl" sha="$esha" issue="$eissue" detail="$edetail"
done < <(jq -r 'def d: if . == null or . == "" then "-" else tostring end;
  .[] | select(.type | IN("pr_opened", "pr_ready", "pr_merged", "pr_conflicting", "stalled", "dead", "failed", "needs_input", "stale_version", "slot_free",
    "claim_takeover", "claim_released", "claim_held_pr", "claim_lapsed", "morning_report"))
  | [.type, (.team | d), (.name | d), (.url | d), (.sha | d), (if (.type | startswith("claim_")) then (.issue | d) else "-" end),
     (if (.type | startswith("claim_")) then ("holder " + (.holder // "?") + (if .detail then ": " + .detail else "" end))
      elif (.type | IN("pr_conflicting", "morning_report")) then (.detail | d) else "-" end)] | @tsv' "$EVENTS_FILE")

# --- notices: each wake's reply, rendered once for `fleet status` (references/output.md) --------------------------
while IFS= read -r ev; do
  [ -n "$ev" ] || continue
  txt="$(render_notice "$ev" 2>/dev/null)" || txt=""
  [ -z "$txt" ] || notice_add "$txt"
done < <(jq -c --arg wake "$WAKE_TYPES" ".[] | $WAKE_JQ" "$EVENTS_FILE")

# The state is rebuilt from what is live, so it cannot grow without bound: reported-once keys survive only while
# the thing they describe (a PR on a row, an open escalation, a claimed issue, a recent respawn) still exists.
live_prs="$("$registry" list | jq -c '[.[] | select(.status != "Retired") | .pr // empty]')"
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
  + (if .stale_emitted then {stale_emitted: [.stale_emitted[] | select(split("|")[0] as $t | $live_teams | index($t))]} else {} end)
  + (if .brief_failed_emitted then {brief_failed_emitted: [.brief_failed_emitted[] | select(split("|")[0] as $n | $live_names | index($n))]} else {} end)
  + (if .respawns then {respawns: (.respawns | with_entries(.value |= inrecent) | with_entries(select(.value | length > 0)))} else {} end)'
tick_state_write "$(cat "$STATE_FILE")"
[ "$(jq length "$EVENTS_FILE")" = 0 ] || cat "$EVENTS_FILE"
