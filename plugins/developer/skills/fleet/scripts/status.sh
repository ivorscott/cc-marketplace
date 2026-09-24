#!/usr/bin/env bash
# Compute fleet health from herdr state + the done contract, write it back to the
# registry, and print it.
#
#   status.sh [--team T] [--problems] [--json]
#
# Health rules (herdr's own state is necessary but not sufficient):
#   Working      herdr says working
#   Needs input  herdr says blocked, or the agent escalated
#   Done         the agent ran `registry.sh done` (the done contract) — never inferred
#   Idle         herdr says idle/done and the agent declared it is waiting (status=Idle),
#                or it is a lead whose team still has live workers
#   Stalled      herdr says idle/done, but the agent neither finished nor declared waiting
#   Zombie       the agent is gone: herdr can't find it, or its pane is back at the shell
#                (herdr can still report a dead pane as idle, so the process is checked)
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"

team=""; problems=false; json=false
while [ $# -gt 0 ]; do
  case "$1" in
    --team) team="$2"; shift 2 ;;
    --problems) problems=true; shift ;;
    --json) json=true; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

list_args=(--live); [ -n "$team" ] && list_args+=(--team "$team")
rows="$("$registry" list "${list_args[@]}")"

team_has_live_workers() {
  printf '%s' "$rows" | jq -e --arg t "$1" \
    '[.[] | select(.team == $t and .tier == "Worker" and .status != "Done" and .status != "Retired")] | length > 0' >/dev/null
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

  if [ "$herdr_state" = "gone" ] || ! $pane_alive; then new="Zombie"
  else
    case "$herdr_state" in
      working) new="Working" ;;
      blocked) new="Needs input" ;;
      idle|done)
        if [ -n "$esc" ] && [ "$old" = "Needs input" ]; then new="Needs input"
        elif [ "$old" = "Idle" ]; then new="Idle"
        elif [ "$tier" = "Lead" ] && team_has_live_workers "$tm"; then new="Idle"
        else new="Stalled"; fi ;;
      *) new="$old" ;;
    esac
  fi
  [ "$new" != "$old" ] && "$registry" set "$name" status="$new" >/dev/null
done

filter='.'; $problems && filter='[.[] | select(.status == "Stalled" or .status == "Zombie" or .status == "Needs input" or (.escalation // "") != "")]'
out="$("$registry" list "${list_args[@]}" | jq "$filter")"
if $json; then printf '%s\n' "$out"; exit 0; fi
printf '%s' "$out" | jq -r '
  (["AGENT", "TIER", "STATUS", "ESC", "HERDR", "ASSIGNMENT"] | @tsv),
  (sort_by(.team, .tier)[] | [.name, .tier, .status, (if (.escalation // "") == "" then "-" else .escalation end), .herdr_ref, ((.assignment // "")[0:50])] | @tsv)' |
  column -t -s $'\t'
