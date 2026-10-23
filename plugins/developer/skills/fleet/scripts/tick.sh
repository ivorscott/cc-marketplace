#!/usr/bin/env bash
# One Orchestrator tick: everything that changed since the last tick, as one JSON array.
# A quiet tick prints nothing and exits 0; the Orchestrator's whole reply to it is one line.
# Run by loop-tick.sh from launchd (schedule.sh); the Orchestrator calls it itself only when no schedule is installed.
#
#   tick.sh [--team T]
#
# A Parked team (park.sh) is skipped throughout: no nudge, no respawn, no Stalled or Zombie, no PR discovery or
# PR events, and it still covers its repo for repo_without_team. Its claim is kept, so the heartbeat goes on.
# Events (each has type, team, name; url where a PR exists). Each is reported once; what has
# been reported lives in $FLEET_STATE_DIR/tick.state.json.
#   stalled         still Stalled a tick after the nudge (a newly Stalled agent gets one nudge, no event)
#   failed          a row went Failed (a restart or a brief that did not arrive), once on the transition
#   dead            status.sh says Zombie, on the transition; the row is also respawned (respawn.sh) within
#                   a budget, and the second death inside the window escalates P1 instead
#   needs_input     an agent stopped by an API error (expired login); status_detail on its row says which
#   brief_failed    a brief never arrived (the row stays Failed): tick re-sent its pointer once and that did
#                   not arrive either. Once per (agent, brief file)
#   stale_version   an agent runs an older plugin version than the one installed (its row's plugin_version);
#                   it is restarted at the next `next.sh`, never mid-task. Once per (agent, installed version)
#   weekly_summary  the ISO week changed (the Orchestrator writes reports/fleet-metrics-<date>.md from
#                   metrics.sh and sends one line); the first tick ever only records the week
#   escalation      an open escalation not yet reported (keyed by agent name and escalation id)
#   pr_opened       a live builder on a fleet/ branch has an open PR the row doesn't know yet
#                   (gh pr list --head, even when the builder skipped its done step): recorded as
#                   the row's pr, the lead is told to start the tester. Once per PR.
#   pr_ready        the row's PR is open, mergeable, checks green (or none exist and the repo is in
#                   no_pr_ci in config.toml), the tester's signed-off SHA is the PR head, and the
#                   body has no "DO NOT MERGE", "merge order", "before/after", "merge after/before" or "stacked on",
#                   and the PR is not a draft (a stacked child must not go ready before its parent). Once per (PR, head SHA).
#   pr_merged       the row's PR was merged; the Orchestrator answers with next.sh. Once per PR. A team marked
#                   park --after-merge (or by focus) is parked by tick instead; the event says `parks`.
#   repo_without_team  a repo in config.toml `repos` with no live team, when it becomes so
#   disk, disk_ok   free disk crossed below warn_free_gb, and recovered
#   claim_takeover  a team's issue now carries another machine's label (once per team, issue and holder)
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
heartbeat
claims_taken_over

# --- stalled / dead -------------------------------------------------------------------------
# A newly Stalled agent gets ONE nudge through tell.sh (nudged_at on its row) and no event; still
# Stalled on a later tick: a `stalled` event, once. A Zombie on two ticks in a row is a `dead` event (once) and is
# respawned within a budget (respawn_max = 1 per respawn_window_hours = 6 per agent): every attempt, successful
# or not, spends it; once it is spent, one P1 escalation and no more respawns. Done and Retired rows are never touched.
now_iso="${FLEET_NOW:-$(now)}"; now_epoch="$(jq -rn --arg t "$now_iso" '$t | fromdateiso8601')"
targs=(); [ -n "$team" ] && targs=(--team "$team")
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
# A row booted (or restarted) by an older plugin than the one installed now. The fix is a restart at the next
# `next.sh` (never mid-task), so this only reports it, once per (agent, installed version).
iv="$(installed_version)"
if [ -n "$iv" ]; then
  while IFS=$'\t' read -r vname vteam pv; do
    [ -n "$vname" ] && [ -n "$pv" ] || continue
    version_gt "$iv" "$pv" || continue
    if [ "$(jq --arg k "$vname|$iv" '(.stale_emitted // []) | index($k) == null' "$STATE_FILE")" = true ]; then
      add_events "$(jq -cn --arg n "$vname" --arg t "$vteam" --arg p "$pv" --arg i "$iv" '[{type: "stale_version", team: $t, name: $n, detail: ("runs " + $p + ", installed " + $i + "; restarted at the next next.sh")}]')"
      st_upd --arg k "$vname|$iv" '$st + {stale_emitted: ((($st.stale_emitted // []) + [$k]) | unique)}'
    fi
  done < <("$registry" list --live ${team:+--team "$team"} | jq -r '.[] | select(.tier != "Orchestrator") | [.name, .team, (.plugin_version // "")] | @tsv')
fi

# --- escalations ------------------------------------------------------------------------------
esc="$("$registry" escalations --open ${team:+--team "$team"})"
add_events "$(jq -cn --argjson e "$esc" --slurpfile stf "$STATE_FILE" '
  [$e[] | select(((.name + "|" + .id) as $k | ($stf[0].escalations_emitted // []) | index($k)) == null)
    | {type: "escalation", team, name, id, severity, message, at}]')"
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
  [.[] | select(type == "object") | select(((.pr // "") | type) == "string" and ((.repo // "") | type) == "string"
      and (.signoff == null or ((.signoff | type) == "object" and ((.signoff.sha // "") | type) == "string")))
    | select(.status != "Retired" and .status != "Parked" and (.pr // "") != "")]
  | group_by(.pr) | map(. as $g | {pr: .[0].pr, team: .[0].team, name: .[0].name, repo: (.[0].repo // ""),
      signoff: ([$g[] | select((.signoff | objects | .sha) != null and ((.name // "") | endswith("/tester")) and .team == $g[0].team) | .signoff.sha] | first // null),
      park_after_merge: ([$g[] | .park_after_merge // empty] | first // null)})')"
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
            (if (($stf[0].pr_merged_emitted // []) | index($p.pr)) == null then {type: "pr_merged", team: $p.team, name: $p.name, url: $p.pr} + (if $p.park_after_merge != null then {parks: $p.park_after_merge} else {} end) else null end)
          elif (pr_missing($p.signoff; $nociok) | length) == 0 and (($stf[0].pr_ready_emitted // []) | index($p.pr + "@" + $head)) == null
          then {type: "pr_ready", team: $p.team, name: $p.name, url: $p.pr, sha: $head, ci: pr_ci($nociok)}
          else null end')"
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
        pr_ready) st_upd --argjson e "$ev" '$st + {pr_ready_emitted: ((($st.pr_ready_emitted // []) + [$e.url + "@" + $e.sha]) | unique)}' ;;
      esac
    done < <(printf '%s' "$prs" | jq -c '.[]')
    rm -f "$ghtmp"; ghtmp=""
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

# --- weekly archive ------------------------------------------------------------------------------
week="$(date +%G-W%V)"
if [ "$(jq -r '.archive_week // ""' "$STATE_FILE")" != "$week" ]; then
  "$registry" archive >/dev/null 2>&1 || warn "weekly archive failed"
  st_upd --arg w "$week" '$st + {archive_week: $w}'
fi

# --- weekly summary ---------------------------------------------------------------------------------
sweek="$(date +%G-W%V)"; prev_week="$(jq -r '.summary_week // ""' "$STATE_FILE")"
if [ -n "$prev_week" ] && [ "$prev_week" != "$sweek" ]; then
  add_events "$(jq -cn --arg w "$sweek" '[{type: "weekly_summary", team: "", name: "", week: $w, detail: "run metrics.sh --since 7d and write reports/fleet-metrics-<date>.md"}]')"
fi
st_upd --arg w "$sweek" '$st + {summary_week: $w}'

# --- the event log ------------------------------------------------------------------------------------
while IFS=$'\t' read -r etype eteam ename eurl esha; do
  [ -n "$etype" ] || continue
  [ "$eurl" != - ] || eurl=""; [ "$esha" != - ] || esha=""; [ "$eteam" != - ] || eteam=""
  ev_log "$etype" team="$eteam" name="$ename" pr="$eurl" sha="$esha"
done < <(jq -r '.[] | select(.type | IN("pr_opened", "pr_ready", "pr_merged", "stalled", "dead", "failed", "needs_input", "stale_version")) | [.type, (.team // "-" | if . == "" then "-" else . end), .name, (.url // "-"), (.sha // "-")] | @tsv' "$EVENTS_FILE")

# The state is rebuilt from what is live, so it cannot grow without bound: reported-once keys survive only while
# the thing they describe (a PR on a row, an open escalation, a claimed issue, a recent respawn) still exists.
live_prs="$("$registry" list | jq -c '[.[] | select(.status != "Retired") | .pr // empty]')"
live_esc="$("$registry" escalations --open | jq -c '[.[] | .name + "|" + .id]')"
live_claims="$("$registry" list --live | jq -c '[.[] | select((.issue // "") != "") | .team + "|" + .issue]')"
live_names="$("$registry" list --live | jq -c '[.[] | .name]')"
st_upd --argjson prs "$live_prs" --argjson esc "$live_esc" --argjson cl "$live_claims" --argjson live_names "$live_names" --argjson now "$now_epoch" --argjson w "$(const_int RESPAWN_WINDOW_HOURS 6)" '
  def inrecent: map(select(. > $now - $w * 3600));
  $st
  + (if .pr_ready_emitted then {pr_ready_emitted: [.pr_ready_emitted[] | select(split("@")[0] as $u | $prs | index($u))]} else {} end)
  + (if .pr_merged_emitted then {pr_merged_emitted: [.pr_merged_emitted[] | select(. as $u | $prs | index($u))]} else {} end)
  + (if .pr_opened_emitted then {pr_opened_emitted: [.pr_opened_emitted[] | select(. as $u | $prs | index($u))]} else {} end)
  + (if .escalations_emitted then {escalations_emitted: [.escalations_emitted[] | select(. as $k | $esc | index($k))]} else {} end)
  + (if .takeover_emitted then {takeover_emitted: [.takeover_emitted[] | select(split("|")[0:2] | join("|") as $k | $cl | index($k))]} else {} end)
  + (if .stale_emitted then {stale_emitted: [.stale_emitted[] | select(split("|")[0] as $n | $live_names | index($n))]} else {} end)
  + (if .brief_failed_emitted then {brief_failed_emitted: [.brief_failed_emitted[] | select(split("|")[0] as $n | $live_names | index($n))]} else {} end)
  + (if .respawns then {respawns: (.respawns | with_entries(.value |= inrecent) | with_entries(select(.value | length > 0)))} else {} end)'
tick_state_write "$(cat "$STATE_FILE")"
[ "$(jq length "$EVENTS_FILE")" = 0 ] || cat "$EVENTS_FILE"
