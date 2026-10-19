#!/usr/bin/env bash
# Respawn a dead agent (a Zombie row) from its registry row: same role, worktree, branch, model and
# harness, in its own workspace. tick.sh runs this, within a budget (respawn_max = 1 per
# respawn_window_hours = 6 per agent, config.toml); a Done or Retired row is never respawned.
#
#   respawn.sh <team/role>
#   respawn.sh <team/role> --restart [--brief-text TEXT]
#
# --restart (used by next.sh, between issues) restarts a live agent at a safe point: `/exit`, wait for its pane
# to come back to the shell, then a fresh start in the same pane with a new --session-id and its FULL brief
# (the role brief for the row's current assignment, plus --brief-text for the lead), sent as a file through
# tell.sh --brief. The lead comes back Working, a worker Idle (the lead hands it work). The row's
# plugin_version becomes the version of these scripts. It is not a death: nothing charges the respawn budget,
# and the event is `restarted`. UNVERIFIED against real herdr: `herdr agent start` after /exit in the same pane.
#
# The resume brief is `build_brief --resume`: the role brief, the assignment, the last report file,
# `git status` and `git log` of its branch and its open escalations (no pane text). A lead also gets
# the plan path and the team's rows. The brief is sent through tell.sh --brief to an agent that comes up
# Working or Idle, so a brief that does not arrive marks the row Failed. The row gets a
# new session id, so its `transcript` path changes (the old one is kept in the row's `transcripts` list). Logs `respawned` to the event log.
#
# If the row's pane is gone, a new pane is split from the lead's pane in the same workspace.
# UNVERIFIED against real herdr: that `herdr agent start <same name>` is accepted for an agent whose
# pane died (DEV-368).
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"

name="${1:?usage: respawn.sh <team/role> [--restart [--brief-text TEXT]]}"; shift
restart=false; extra=""
while [ $# -gt 0 ]; do
  case "$1" in
    --restart) restart=true; shift ;;
    --brief-text) extra="${2:?--brief-text needs text}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
row="$("$registry" get "$name")" || exit 1
get() { printf '%s' "$row" | jq -r ".$1 // \"\""; }
status="$(get status)"
case "$status" in Done | Retired) die "$name is $status; not respawning it" ;; esac

team="$(get team)"; tier="$(get tier)"; agent="$(get herdr_ref)"; pane="$(get pane)"; split_new=0
cwd="$(get cwd)"; worktree="$(get worktree)"; model="$(get model)"; kind="$(get harness)"; kind="${kind:-claude}"
template="$(get template)"; repo="$(get repo)"; task="$(get assignment)"; ex="$(get expertise_file)"; issue_url="$(get issue_url)"
role="${name#*/}"
tpl="$FLEET_SKILL_DIR/templates/$template.json"
[ -f "$tpl" ] || die "no template '$template' for $name"
tool_allow="$(jq -cn --argjson t "$(config_list tracker_allow)" --argjson f "$(config_list forge_allow)" '$t + $f | unique')"
tpl_mode="$(jq -r '.permission_mode // empty' "$tpl")"
if [ -n "$tpl_mode" ]; then perm_mode="$(check_permission_mode "$tpl_mode")" || exit 1
else perm_mode="$(permission_mode)" || exit 1; fi
. "$FLEET_SCRIPTS/agent-lib.sh"

if [ "$tier" = "Lead" ]; then
  allow="$(jq -c '.lead.allow // []' "$tpl")"; brief_tpl="$(jq -r '.lead.brief' "$tpl")"
else
  allow="$(jq -c --arg r "$role" '[.workers[] | select(.role == $r)][0].allow // []' "$tpl")"
  brief_tpl="$(jq -r --arg r "$role" '[.workers[] | select(.role == $r)][0].brief // ""' "$tpl")"
fi
workers="$("$registry" list --team "$team" | jq -r '[.[] | select(.tier == "Worker") | .herdr_ref] | join(", ")')"

if $restart; then
  # The full brief for the current assignment (a lead also gets the text next.sh passes).
  role_brief="$(render "$brief_tpl" "$name" "$worktree" "$workers")"
  [ -z "$extra" ] || role_brief="$role_brief

$extra"
  brief="$(build_brief "$name" "$ex" "$role_brief")"
  # /exit, then wait for the pane to show its shell again.
  "$FLEET_SCRIPTS/tell.sh" "$name" /exit --no-confirm >/dev/null 2>&1 || die "could not send /exit to $name"
  waited=0; exit_secs="${FLEET_EXIT_WAIT_SECS:-30}"; poll="${FLEET_TELL_POLL:-1}"
  while hd pane process-info --pane "$pane" 2>/dev/null | jq -e '.result.process_info | .foreground_process_group_id != .shell_pid' >/dev/null 2>&1; do
    if awk -v w="$waited" -v m="$exit_secs" 'BEGIN { exit !(w >= m) }'; then die "$name did not exit within ${exit_secs}s; it keeps running its old session"; fi
    sleep "$poll"; waited="$(awk -v w="$waited" -v p="$poll" 'BEGIN { print w + p }')"
  done
else
  # The resume brief is built before the new agent starts, from the row as it was.
  brief="$(build_brief --resume "$name" "$ex" "$(render "$brief_tpl" "$name" "$worktree" "$workers")")"
fi

# The pane: reuse the row's, or split a new one beside the lead in the same workspace.
if ! hd pane process-info --pane "$pane" >/dev/null 2>&1; then
  lead_pane="$("$registry" list --team "$team" | jq -r '[.[] | select(.tier == "Lead") | .pane] | first // ""')"
  [ -n "$lead_pane" ] || die "$name's pane is gone and the team has no lead pane to split from"
  env_args=(); [ -z "$(env_config "$repo")" ] || env_args=(--env "KUBECONFIG=$(env_dir "$team")/kubeconfig")
  pane="$(hd pane split --pane "$lead_pane" --direction down --cwd "${cwd:-$repo}" --no-focus \
    --env "FLEET_ROLE=$(printf '%s' "$tier" | tr 'A-Z' 'a-z')" --env "FLEET_NAME=$name" --env "FLEET_TEAM=$team" \
    --env "FLEET_WORKTREE=$worktree" --env "FLEET_STATE_DIR=$FLEET_STATE_DIR" ${env_args[@]+"${env_args[@]}"} | jq -r .result.pane.pane_id)"
  [ -n "$pane" ] && [ "$pane" != null ] || die "could not split a new pane for $name"
  split_new=1
fi

session_id=""; transcript=""
if [ "$kind" = claude ]; then
  session_id="$(new_uuid)"; transcript="$(transcript_dir_for "${cwd:-$repo}")/$session_id.jsonl"
fi
new_status="$(start_agent "$agent" "$kind" "$pane" "$model" "$tier" "$worktree" "$allow")"
if [ "$new_status" = Zombie ]; then
  # A pane this run split is closed, not left behind; the row keeps its old pane and the next attempt splits again.
  if [ "$split_new" = 1 ]; then hd pane close "$pane" >/dev/null 2>&1 || warn "could not close pane $pane"; fi
  die "$name did not start again; row stays Zombie"
fi
if $restart && [ "$new_status" = Working ]; then
  [ "$tier" = Lead ] || new_status=Idle
fi
set_args=(status="$new_status" pane="$pane")
pv="$(plugin_version)"; [ -z "$pv" ] || set_args+=(plugin_version="$pv")
if [ -n "$transcript" ]; then
  old_t="$(get transcript)"; [ -z "$old_t" ] || "$registry" append "$name" transcripts "$old_t" >/dev/null
  set_args+=(transcript="$transcript")
fi
"$registry" set "$name" "${set_args[@]}" >/dev/null
if $restart; then ev_log restarted team="$team" name="$name" detail="new session"
else ev_log respawned team="$team" name="$name" detail="new pane $pane"; fi

if [ "$new_status" = Working ] || [ "$new_status" = Idle ]; then
  "$FLEET_SCRIPTS/tell.sh" "$name" "$brief" --brief >/dev/null || { "$registry" set "$name" status=Failed >/dev/null; die "the resume brief did not reach $name; row set to Failed"; }
fi
jq -cn --arg n "$name" --arg s "$new_status" --argjson r "$restart" 'if $r then {restarted: $n, status: $s} else {respawned: $n, status: $s} end'
