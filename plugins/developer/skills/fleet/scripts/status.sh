#!/usr/bin/env bash
# Compute fleet health from herdr state + the done contract, write it back to the
# registry, and print it.
#
#   status.sh [<team>] [--problems] [--json]
#
# The output is the status entry of references/output.md: the wake notices not shown yet (once, above the
# rest), the team table (| Team | Machine | Issue | PR | State | Needs you |, one row per team with a row not yet
# Retired, parked teams included, then "Waiting on you: ..." when a P0 or P1 is open), the merge queue when any
# PR is open (queue.sh: the ready PRs in the order to merge them, then "Not ready: ..."), and footer lines that
# appear only when they apply: the focus, the disk (below warn_free_gb in config.toml), a loop with no
# Orchestrator to wake, and a skill text in use older than the plugin installed (restart the session). --problems keeps only the teams that need someone. With a <team>, one row per agent of
# that team instead: | Agent | Role | State | Model | Last action |. --json is the bare array of this machine's agents
# (of the <team> when one is given), for tick and the tests; it shows no notice.
#
# Every machine in one table. Status reads the other machines' published summaries from Linear (linear.sh peers: one
# read) and shows their teams in the same table and the same merge queue, each row with its Machine; the rows are never
# probed and nothing is written for them. A machine on an older plugin, or one that has published no summary, shows as
# one line, "Other machines: DEV-1 on <key> (claim only: no summary)"; with no Linear key the table
# is this machine's alone and a line says "Other machines: unknown (no Linear key)". A summary older than lease_hours
# stays in the table and is never counted as ready. No heartbeat age is printed: a machine whose heartbeat is lapsed or
# missing gets one plain line ("<machine>: heartbeat lapsed." or "<machine>: no heartbeat."), a live one gets none. To show less, the Orchestrator picks
# rows out of the table; there is no switch. --all is accepted and does nothing for the table; with --json it adds the
# other machines' rows to the array (machine and source: registry | tracker on every row).
# Internal: FLEET_STATUS_LOCAL=1 keeps status to this machine and skips the Linear read (tick and the done contract
# set it, where nothing needs the others).
#
# Health rules (herdr's own state is necessary but not sufficient):
#   Working      herdr says working
#   Needs input  herdr says blocked, or the agent escalated
#   Done         the agent ran `registry.sh done` (the done contract) — never inferred
#   Idle         herdr says idle/done and the agent declared it is waiting (status=Idle),
#                or it is a lead whose team still has live workers
#   Stalled      herdr says idle/done, but the agent neither finished nor declared waiting, and it has no
#                background task running (a task its transcript started, with no notification and no stop
#                yet, counts as Working; the screen is never read, so with no transcript there is none)
#   Needs input  also: the newest assistant line of its transcript is an API error (isApiErrorMessage);
#                `status_detail` on the row says "login expired" or "API error" (and the status shows it)
#   Zombie       the agent is gone: herdr can't find it, or its pane is back at the shell
#                (herdr can still report a dead pane as idle, so the process is checked)
# Command: Show every machine's teams and what needs you · e.g. fleet status
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"

team=""; problems=false; json=false; all=false
while [ $# -gt 0 ]; do
  case "$1" in
    --problems) problems=true; shift ;;
    --json) json=true; shift ;;
    --all) all=true; shift ;;
    -*) die "unknown option: $1" "Run fleet help status" ;;
    *) [ -z "$team" ] || die "one team at a time: $team and $1"; team="$1"; shift ;;
  esac
done

# The other machines: their claims and summaries, from Linear (linear.sh peers, one read); claims_why says why they are
# unknown. Not read for one team's agent table, --problems, --json without --all, or FLEET_STATUS_LOCAL=1.
claims="[]"; claims_why=""; want_peers=true
if [ "${FLEET_STATUS_LOCAL:-}" = 1 ]; then want_peers=false
elif $json; then $all || want_peers=false
elif [ -n "$team" ] || $problems; then want_peers=false; fi
if $want_peers; then
  prc=0; claims="$("$FLEET_SCRIPTS/linear.sh" peers 2>/dev/null)" || prc=$?
  if [ "$prc" = 3 ]; then claims="[]"; claims_why="no Linear key"
  elif [ "$prc" != 0 ] || ! printf '%s' "$claims" | jq -e 'type == "array"' >/dev/null 2>&1; then claims="[]"; claims_why="Linear could not be read"; fi
  export FLEET_PEERS_JSON="$claims" # queue.sh reuses it instead of reading Linear again
fi
# peer_teams: the other machines' teams out of their summaries ([] for a machine with none), one row per team with its
# stale flag; peer_claims: the claims of the machines that published none.
peer_teams="[]"; peer_claims="[]"
if $want_peers; then
  pj="$(printf '%s' "$claims" | jq -c --arg now "${FLEET_NOW:-$(now)}" --argjson lease "$(lease_hours)" '
    (group_by(.machine) | map(select(any(.[]; .summary != null)) | . as $g | ($g | map(select(.summary != null)) | first) as $c
      | (if $c.heartbeat == null then null else (($now | fromdateiso8601) - ($c.heartbeat | fromdateiso8601)) end) as $age
      | ($age != null and $age > ($lease * 3600)) as $stale
      | $c.summary[] | {machine: $c.machine, team: .t, issue: (.i // ""), pr: (.pr // ""), needs: (.n // ""), ready: ((.r // false) and ($stale | not)),
          state: (.s // "Idle"), heartbeat: $c.heartbeat, stale: $stale})) as $teams
    | ([.[] | select(.machine as $m | ($teams | map(.machine) | index($m)) == null)]) as $claims
    | {teams: $teams, claims: $claims}')"
  peer_teams="$(printf '%s' "$pj" | jq -c .teams)"; peer_claims="$(printf '%s' "$pj" | jq -c .claims)"
fi

list_args=(--live); [ -n "$team" ] && list_args+=(--team "$team")
rows="$("$registry" list "${list_args[@]}")"

team_has_live_workers() {
  printf '%s' "$rows" | jq -e --arg t "$1" \
    '[.[] | select(.team == $t and .tier == "Worker" and .status != "Done" and .status != "Retired")] | length > 0' >/dev/null
}

# bg_busy <transcript>: the agent has a background task running, so idle is not Stalled. Only its transcript says
# (started minus notified or stopped tasks, aged out after bg_task_max_hours); herdr has no field for it, and the
# screen is never read, so with no readable transcript there is none.
bg_busy() {
  local n
  [ -n "$1" ] && [ -r "$1" ] || return 1
  n="$(transcript_bg_running "$1")"; [ "${n:-0}" -gt 0 ]
}

# Each row's fields in one jq pass (\x1f-separated: a tab read would merge the empty ones), read on fd 3 so nothing
# in the loop reads the list.
while IFS=$'\x1f' read -r -u 3 name ref pane tier tm old esc tr sdetail bfa lbrief bfl; do
  [ -n "$name" ] || continue
  ! booting "$tm" || continue # boot is still starting this team's agents and sets their states itself
  # A brief that arrived after tell gave up on it (a session slow to start writes the prompt minutes later): its id in
  # the transcript, after the line tell failed at (brief_failed_line), brings the row back as tell would have (a lead
  # Working, a worker Idle), and herdr decides from there.
  if [ "$old" = Failed ] && [ -n "$bfa" ] && [ -n "$lbrief" ] && [ -n "$bfl" ] &&
    brief_in_transcript "$tr" "$(basename "$lbrief" .md)" $((bfl + 1)); then
    old=Idle; [ "$tier" != Lead ] || old=Working
    "$registry" set "$name" status="$old" brief_failed_at= brief_failed_issue= brief_failed_line= brief_resent= >/dev/null
    ev_log brief_delivered team="$tm" name="$name" detail=late
  fi

  herdr_state="$(hd agent get "$ref" 2>/dev/null | jq -r '.result.agent.agent_status // "gone"' || echo gone)"
  pane_alive=true
  if [ -n "$pane" ]; then
    hd pane process-info --pane "$pane" 2>/dev/null |
      jq -e '.result.process_info | .foreground_process_group_id != .shell_pid' >/dev/null || pane_alive=false
  fi

  detail=""
  if [ "$herdr_state" != "gone" ] && $pane_alive && [ "$herdr_state" != "working" ]; then
    detail="$(api_error_detail "$tr")"
  fi

  if [ "$herdr_state" = "gone" ] || ! $pane_alive; then new="Zombie"
  elif [ "$old" = "Failed" ]; then
    new="Failed" # a restart or a brief that never arrived: Failed until a person or a confirmed brief (tell.sh) says otherwise
  elif [ -n "$detail" ]; then new="Needs input"
  else
    case "$herdr_state" in
      working) new="Working" ;;
      blocked) new="Needs input" ;;
      idle|done)
        if [ -n "$esc" ] && [ "$old" = "Needs input" ]; then new="Needs input"
        elif [ "$old" = "Idle" ]; then new="Idle"
        elif [ "$tier" = "Lead" ] && team_has_live_workers "$tm"; then new="Idle"
        elif bg_busy "$tr"; then new="Working"
        else new="Stalled"; fi ;;
      *) new="$old" ;;
    esac
  fi
  [ "$new" != "$old" ] && "$registry" set "$name" status="$new" >/dev/null
  [ "$detail" = "$sdetail" ] || "$registry" set "$name" status_detail="$detail" >/dev/null
done 3< <(jq -r '.[] | select(.tier != "Orchestrator") | [.name, (.herdr_ref // ""), (.pane // ""), (.tier // ""), (.team // ""), (.status // ""),
  (.escalation // ""), (.transcript // ""), (.status_detail // ""), (.brief_failed_at // ""), (.last_brief // ""),
  (.brief_failed_line // "" | tostring | select(test("^[0-9]+$")) // "")]
  | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' <<<"$rows")

filter='.'; $problems && filter='[.[] | select(.status == "Stalled" or .status == "Zombie" or .status == "Needs input" or (.escalation // "") != "")]'
out="$("$registry" list "${list_args[@]}" | jq "$filter")"
if $all && $want_peers; then
  me="$(machine_key 2>/dev/null || echo local)"
  peer_rows="$(jq -cn --arg now "${FLEET_NOW:-$(now)}" --argjson lease "$(lease_hours)" --argjson t "$peer_teams" --argjson c "$peer_claims" '
    [$t[] | {name: .team, team: .team, tier: "-", source: "tracker", machine: .machine, status: .state, escalation: "", herdr_ref: "-", issue: .issue,
       pr: .pr, needs: .needs, ready: .ready, heartbeat: .heartbeat, assignment: ""}]
    + [$c[] | . as $c
      | (if $c.heartbeat == null then null else (($now | fromdateiso8601) - ($c.heartbeat | fromdateiso8601)) end) as $age
      | {name: ($c.label // $c.machine), team: "", tier: "-", source: "tracker", machine: $c.machine,
         status: (if $age == null then "Claimed (no heartbeat)" elif $age > ($lease * 3600) then "Claimed (heartbeat lapsed)" else "Claimed" end),
         escalation: "", herdr_ref: "-", issue: $c.issue, heartbeat: $c.heartbeat,
         heartbeat_age: (if $age == null then "-" else "\(($age / 60) | floor)m" end), assignment: ""}]')"
  out="$(jq -cn --arg me "$me" --slurpfile l <(printf '%s' "$out") --argjson p "$peer_rows" '($l[0] | map(. + {source: "registry", machine: (.machine // $me)})) + $p')"
fi
if $json; then printf '%s\n' "$out"; exit 0; fi

# One team: its agents.
if [ -n "$team" ]; then render_agent_table "$team" || die "no team $team" "Run fleet status for the teams"; exit 0; fi

# The fleet: the notices not shown yet, the team table (with --problems, only the teams that need someone),
# then the footer lines that apply, each a block of the reply.
blocks=("$(notices_show)")
# The merge queue (queue.sh) when any PR is open: the one tick built, while it is fresh (common.sh fleet_queue). Built
# before the table, which says "rebase after #N" in the Needs you cell of a team whose PR waits behind another.
q=""; $problems || q="$(fleet_queue 2>/dev/null)" || { q=""; warn "the merge queue could not be built"; }
if $problems; then
  pteams="$(printf '%s' "$out" | jq -r '[.[] | select(.tier != "Orchestrator") | .team] | unique[]')"
  if [ -n "$pteams" ]; then
    # shellcheck disable=SC2086
    blocks+=("$(render_table $pteams)")
  else blocks+=("$(render_line no_problems)"); fi
else
  targs=(); [ -z "$q" ] || targs+=(--queue "$q")
  [ "$peer_teams" = "[]" ] || targs+=(--peers "$peer_teams")
  blocks+=("$(render_table ${targs[@]+"${targs[@]}"})")
  [ -z "$q" ] || blocks+=("$(render_queue "$q")")
fi
[ ! -f "$FLEET_STATE_DIR/focus" ] || blocks+=("$(render_line focus team="$(cat "$FLEET_STATE_DIR/focus")")")
free="$(free_gb 2>/dev/null || true)"
# What the fleet holds and the last reclaim come from tick's hourly measure (du is too slow for every status).
if [ -n "$free" ] && [ "$free" -lt "$(warn_free_gb)" ]; then
  held="$(jq -r '.held_gb // empty' "$FLEET_STATE_DIR/tick.state.json" 2>/dev/null || true)"
  blocks+=("$(render_line disk free="$free" warn="$(warn_free_gb)" held="$held" reclaimed="$(jq -r '.reclaimed_gb // 0' "$FLEET_STATE_DIR/tick.state.json" 2>/dev/null || echo 0)")")
fi
if $want_peers; then
  if [ -n "$claims_why" ]; then blocks+=("$(render_line other_machines list="unknown ($claims_why)")")
  else
    # A machine that published no summary: its claims, one line. No heartbeat age anywhere in what status prints.
    if [ "$peer_claims" != "[]" ]; then
      blocks+=("$(render_line other_machines list="$(printf '%s' "$peer_claims" | jq -r "$RENDER_DEFS"'
        [.[] | "\(issue_cell(.issue; ""; "")) on \(.machine // .label) (claim only: no summary)"] | join("; ")')")")
    fi
    # A machine whose heartbeat is lapsed or missing gets one plain line, whether or not it published a summary.
    hbl="$(printf '%s' "$claims" | jq -r --arg now "${FLEET_NOW:-$(now)}" --argjson lease "$(lease_hours)" '
      group_by(.machine) | map({machine: .[0].machine, hb: (map(.heartbeat | select(. != null)) | max)})
      | .[] | if .hb == null then "\(.machine)\tno heartbeat"
        elif (($now | fromdateiso8601) - (.hb | fromdateiso8601)) > ($lease * 3600) then "\(.machine)\theartbeat lapsed" else empty end')"
    while IFS=$'\t' read -r hm hw; do
      [ -z "$hm" ] || blocks+=("$(render_line machine_heartbeat machine="$hm" what="$hw")")
    done <<<"$hbl"
  fi
fi
# The launchd loop is installed (its launcher exists) but has no Orchestrator to wake: say so in one line.
if [ -x "$FLEET_STATE_DIR/bin/fleet-tick" ] &&
  [ -z "$("$registry" get orchestrator 2>/dev/null | jq -r '.herdr_ref // ""' 2>/dev/null)" ]; then
  blocks+=("$(render_line loop_unregistered)")
fi
# Agent state comes from herdr's Claude integration (its hooks): say so in one line when it is not current.
herdr_integration_ok || blocks+=("$(render_line herdr_integration)")
# The skill text in use is the version this script belongs to; Claude Code keeps serving it after an update until the
# session restarts. A newer installed plugin: say so, so the Orchestrator does not follow old rules for hours.
iv="$(installed_version)"; pv="$(plugin_version)"
[ -z "$iv" ] || [ -z "$pv" ] || ! version_gt "$iv" "$pv" || blocks+=("$(render_line skill_stale running="$pv" installed="$iv")")
reply "${blocks[@]}"
