#!/usr/bin/env bash
# Compute fleet health from herdr state + the done contract, write it back to the
# registry, and print it.
#
#   status.sh [<team>] [--problems] [--json] [--all [--claims FILE|-]]
#
# The output is the status entry of references/output.md: the wake notices not shown yet (once, above the
# rest), the team table (| Team | Issue | PR | State | Needs you |, one row per team with a row not yet
# Retired, parked teams included, then "Waiting on you: ..." when a P0 or P1 is open), the merge queue when any
# PR is open (queue.sh: the ready PRs in the order to merge them, then "Not ready: ..."), and footer lines that
# appear only when they apply: the focus, the disk (below warn_free_gb in config.toml) and a loop with no
# Orchestrator to wake. --problems keeps only the teams that need someone. With a <team>, one row per agent of
# that team instead: | Agent | Role | State | Model | Last action |. --json is the bare array of agents (of the
# <team> when one is given), for tick and the tests; it shows no notice.
#
# --all adds the other machines' claims from the JSON that `linear.sh peers` printed (--claims FILE, or - for
# stdin), one line: "Other machines: [DEV-1] on <key> (heartbeat 3h ago, lapsed); ...". Peers are never probed.
# Without --claims the line says they were not provided. --all --json is a bare array whose rows have machine and
# source (registry | tracker).
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
# Command: Show each team's health and what needs you · e.g. fleet status --problems
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"

team=""; problems=false; json=false; all=false; claims_file=
while [ $# -gt 0 ]; do
  case "$1" in
    --problems) problems=true; shift ;;
    --json) json=true; shift ;;
    --all) all=true; shift ;;
    --claims) claims_file="${2:?--claims needs a file or -}"; shift 2 ;;
    -*) die "unknown option: $1" "Run fleet help status" ;;
    *) [ -z "$team" ] || die "one team at a time: $team and $1"; team="$1"; shift ;;
  esac
done

[ -z "$claims_file" ] || $all || die "--claims needs --all"
claims="[]"
if [ -n "$claims_file" ]; then
  if [ "$claims_file" = "-" ]; then claims="$(cat)"; else
    [ -r "$claims_file" ] || die "cannot read claims file: $claims_file"
    claims="$(cat "$claims_file")"
  fi
  printf '%s' "$claims" | jq -e 'type == "array"' >/dev/null 2>&1 || die "claims must be the JSON array printed by linear.sh peers"
fi

list_args=(--live); [ -n "$team" ] && list_args+=(--team "$team")
rows="$("$registry" list "${list_args[@]}")"

team_has_live_workers() {
  printf '%s' "$rows" | jq -e --arg t "$1" \
    '[.[] | select(.team == $t and .tier == "Worker" and .status != "Done" and .status != "Retired")] | length > 0' >/dev/null
}

# bg_busy <row json>: the agent has a background task running, so idle is not Stalled. Only its transcript says
# (started minus notified or stopped tasks, aged out after bg_task_max_hours); herdr has no field for it, and the
# screen is never read, so with no readable transcript there is none.
bg_busy() {
  local tr n
  tr="$(printf '%s' "$1" | jq -r '.transcript // ""')"
  [ -n "$tr" ] && [ -r "$tr" ] || return 1
  n="$(transcript_bg_running "$tr")"; [ "${n:-0}" -gt 0 ]
}

for name in $(printf '%s' "$rows" | jq -r '.[] | select(.tier != "Orchestrator") | .name'); do
  r="$(printf '%s' "$rows" | jq -c --arg n "$name" '.[] | select(.name == $n)')"
  ref="$(printf '%s' "$r" | jq -r .herdr_ref)"; pane="$(printf '%s' "$r" | jq -r '.pane // ""')"
  tier="$(printf '%s' "$r" | jq -r .tier)"; tm="$(printf '%s' "$r" | jq -r .team)"
  old="$(printf '%s' "$r" | jq -r .status)"; esc="$(printf '%s' "$r" | jq -r '.escalation // ""')"

  herdr_state="$(hd agent get "$ref" 2>/dev/null | jq -r '.result.agent.agent_status // "gone"' || echo gone)"
  pane_alive=true
  if [ -n "$pane" ]; then
    hd pane process-info --pane "$pane" 2>/dev/null |
      jq -e '.result.process_info | .foreground_process_group_id != .shell_pid' >/dev/null || pane_alive=false
  fi

  detail=""
  if [ "$herdr_state" != "gone" ] && $pane_alive && [ "$herdr_state" != "working" ]; then
    detail="$(api_error_detail "$(printf '%s' "$r" | jq -r '.transcript // ""')")"
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
        elif bg_busy "$r"; then new="Working"
        else new="Stalled"; fi ;;
      *) new="$old" ;;
    esac
  fi
  [ "$new" != "$old" ] && "$registry" set "$name" status="$new" >/dev/null
  [ "$detail" = "$(printf '%s' "$r" | jq -r '.status_detail // ""')" ] || "$registry" set "$name" status_detail="$detail" >/dev/null
done

filter='.'; $problems && filter='[.[] | select(.status == "Stalled" or .status == "Zombie" or .status == "Needs input" or (.escalation // "") != "")]'
out="$("$registry" list "${list_args[@]}" | jq "$filter")"
if $all; then
  peer_rows="$(printf '%s' "$claims" | jq -c --arg now "${FLEET_NOW:-$(now)}" --argjson lease "$(lease_hours)" '
    [.[] | . as $c
      | (if $c.heartbeat == null then null else (($now | fromdateiso8601) - ($c.heartbeat | fromdateiso8601)) end) as $age
      | {name: ($c.label // $c.machine), team: "", tier: "-", source: "tracker", machine: $c.machine,
         status: (if $age == null then "Claimed (no heartbeat)" elif $age > ($lease * 3600) then "Claimed (heartbeat lapsed)" else "Claimed" end),
         escalation: "", herdr_ref: "-", issue: $c.issue, heartbeat: $c.heartbeat,
         heartbeat_age: (if $age == null then "-" else "\(($age / 60) | floor)m" end), assignment: ""}]')"
  $problems && peer_rows="[]"
  out="$(jq -cn --argjson l "$out" --argjson p "$peer_rows" '($l | map(. + {source: "registry"})) + $p')"
fi
if $json; then printf '%s\n' "$out"; exit 0; fi

# One team: its agents.
if [ -n "$team" ]; then render_agent_table "$team" || die "no team $team" "Run fleet status for the teams"; exit 0; fi

# The fleet: the notices not shown yet, the team table (with --problems, only the teams that need someone),
# then the footer lines that apply, each a block of the reply.
blocks=("$(notices_show)")
if $problems; then
  pteams="$(printf '%s' "$out" | jq -r '[.[] | select(.tier != "Orchestrator") | .team] | unique[]')"
  if [ -n "$pteams" ]; then
    # shellcheck disable=SC2086
    blocks+=("$(render_table $pteams)")
  else blocks+=("$(render_line no_problems)"); fi
else
  blocks+=("$(render_table)")
  # The merge queue, rebuilt from GitHub and the registry (queue.sh), when any PR is open.
  if q="$("$FLEET_SCRIPTS/queue.sh" 2>/dev/null)"; then blocks+=("$(render_queue "$q")"); else warn "the merge queue could not be built"; fi
fi
[ ! -f "$FLEET_STATE_DIR/focus" ] || blocks+=("$(render_line focus team="$(cat "$FLEET_STATE_DIR/focus")")")
free="$(free_gb 2>/dev/null || true)"
[ -z "$free" ] || [ "$free" -ge "$(warn_free_gb)" ] || blocks+=("$(render_line disk free="$free" warn="$(warn_free_gb)")")
if $all; then
  if [ -z "$claims_file" ]; then blocks+=("$(render_line other_machines list="not provided (pass --claims with linear.sh peers)")")
  else
    blocks+=("$(render_line other_machines list="$(printf '%s' "$claims" | jq -r --argjson now "$(jq -rn --arg t "${FLEET_NOW:-$(now)}" '$t | fromdateiso8601')" \
      --argjson lease "$(lease_hours)" "$RENDER_DEFS"'
      [.[] | "\(issue_cell(.issue; "")) on \(.machine // .label) (\(if .heartbeat == null then "no heartbeat"
        else "heartbeat \(.heartbeat | ago($now))" + (if ($now - (.heartbeat | fromdateiso8601)) > ($lease * 3600) then ", lapsed" else "" end) end))"]
      | if length == 0 then "none" else join("; ") end')")")
  fi
fi
# The launchd loop is installed (its launcher exists) but has no Orchestrator to wake: say so in one line.
if [ -x "$FLEET_STATE_DIR/bin/fleet-tick" ] &&
  [ -z "$("$registry" get orchestrator 2>/dev/null | jq -r '.herdr_ref // ""' 2>/dev/null)" ]; then
  blocks+=("$(render_line loop_unregistered)")
fi
# Agent state comes from herdr's Claude integration (its hooks): say so in one line when it is not current.
herdr_integration_ok || blocks+=("$(render_line herdr_integration)")
reply "${blocks[@]}"
