#!/usr/bin/env bash
# Compute fleet health from herdr state + the done contract, write it back to the
# registry, and print it.
#
#   status.sh [--team T] [--problems] [--json] [--verbose] [--all [--claims FILE|-]]
#
# The default output is one row per team: TEAM, ISSUE (Linear's link when the team was booted with
# --issue-url, else the key), PR (the full URL), STATE (the worst agent state) and NEEDS YOU (an open
# escalation, or what a stuck agent needs). A line per parked team, the focus, and the disk line
# (only below warn_free_gb) follow. Claims show as "claimed by this Mac" or "claimed by <key>", with a
# line of their own when one was taken over. --verbose (and --all, which implies it) prints one row
# per agent with the ENV, HERDR and heartbeat columns and the machine footer described below.
#
# The table starts with a disk line (free GiB on the worktree volume, LOW below
# warn_free_gb in config.toml) and ends with a machine line (fleet:<key>, plus machine_name
# when set). --json is the bare array of agents, without either.
#
# Open escalations are listed after the table, Done agents included, Retired agents not (retire
# closes theirs): an escalation stays open until the Orchestrator runs `registry.sh resolve`.
#
# --all adds the other machines: one row per claim in the JSON that `linear.sh peers` printed
# (--claims FILE, or - for stdin). Peers are never probed; their rows show Claimed, the issue and
# the age of their last heartbeat ("lapsed" past lease_hours, "no heartbeat" when the label has
# none). The MACHINE and HEARTBEAT columns appear only with --all. --team limits the registry
# rows only. Without --claims the table says "peer claims: not provided". --all --json is a bare
# array whose rows have machine and source (registry | tracker).
#
# Health rules (herdr's own state is necessary but not sufficient):
#   Working      herdr says working
#   Needs input  herdr says blocked, or the agent escalated
#   Done         the agent ran `registry.sh done` (the done contract) — never inferred
#   Idle         herdr says idle/done and the agent declared it is waiting (status=Idle),
#                or it is a lead whose team still has live workers
#   Stalled      herdr says idle/done, but the agent neither finished nor declared waiting, and it has no
#                background task running (a started task with no notification yet, or "N shell(s)" /
#                "N monitor(s)" in the pane footer when there is no transcript, counts as Working)
#   Needs input  also: the newest assistant line of its transcript is an API error (isApiErrorMessage);
#                `status_detail` on the row says "login expired" or "API error" (and the status shows it)
#   Zombie       the agent is gone: herdr can't find it, or its pane is back at the shell
#                (herdr can still report a dead pane as idle, so the process is checked)
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"

team=""; problems=false; json=false; all=false; verbose=false; claims_file=
while [ $# -gt 0 ]; do
  case "$1" in
    --team) team="$2"; shift 2 ;;
    --problems) problems=true; shift ;;
    --json) json=true; shift ;;
    --all) all=true; shift ;;
    --verbose) verbose=true; shift ;;
    --claims) claims_file="${2:?--claims needs a file or -}"; shift 2 ;;
    *) die "unknown option: $1" ;;
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

# bg_busy <row json> <herdr ref>: the agent has a background task running, so idle is not Stalled. The
# transcript says first (started minus notified tasks, aged out after bg_task_max_hours); the pane footer
# ("1 shell still running", "1 shell, 3 monitors") only when there is no readable transcript. herdr has no
# field for it.
bg_busy() {
  local tr n
  tr="$(printf '%s' "$1" | jq -r '.transcript // ""')"
  if [ -n "$tr" ] && [ -r "$tr" ]; then n="$(transcript_bg_running "$tr")"; [ "${n:-0}" -gt 0 ]; return; fi
  footer_bg_running "$(hd agent read "$2" --source visible 2>/dev/null || true)"
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
        elif bg_busy "$r" "$ref"; then new="Working"
        else new="Stalled"; fi ;;
      *) new="$old" ;;
    esac
  fi
  [ "$new" != "$old" ] && "$registry" set "$name" status="$new" >/dev/null
  [ "$detail" = "$(printf '%s' "$r" | jq -r '.status_detail // ""')" ] || "$registry" set "$name" status_detail="$detail" >/dev/null
done

filter='.'; $problems && filter='[.[] | select(.status == "Stalled" or .status == "Zombie" or .status == "Needs input" or (.escalation // "") != "")]'
out="$("$registry" list "${list_args[@]}" | jq "$filter")"
mykey="$(machine_key)"; myname="$(cfg_str machine_name '')"
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
$all && verbose=true
disk_line() {
  local free warn min
  warn="$(warn_free_gb)"; min="$(min_free_gb)"
  if free="$(free_gb)"; then
    printf 'disk: %s GiB free (warn below %s, boot refuses below %s)%s\n' "$free" "$warn" "$min" "$([ "$free" -lt "$warn" ] && echo ' LOW' || true)"
  else printf 'disk: unknown\n'; fi
}
# Default: one row per team. Verbose (and --all) keeps the per-agent table below.
team_table() {
  local esc; esc="$("$registry" escalations --open --not-retired ${team:+--team "$team"})"
  printf '%s' "$out" | jq -r --arg mykey "$mykey" --argjson esc "$esc" '
    def rank: {"Needs input": 6, "Zombie": 5, "Stalled": 4, "Failed": 3, "Working": 2, "Idle": 1, "Done": 0}[.] // 0;
    [.[] | select(.tier != "Orchestrator" and .team != "")] | group_by(.team) | map(
      . as $g | $g[0].team as $t
      | ($g | map(.status) | sort_by(rank) | last) as $state
      | ($esc | map(select(.name | startswith($t + "/"))) | first // null) as $e
      | ($g | map(.pr // "") | map(select(. != "")) | first // "-") as $pr
      | ($g | map(.issue_url // "") | map(select(. != "")) | first // ($g | map(.issue // "") | map(select(. != "")) | first // "-")) as $iss
      | [$t, $iss, $pr, $state,
         (if $e != null then "\($e.severity): \($e.message[0:60])"
          elif $state == "Needs input" then (($g | map(.status_detail // "") | map(select(. != "")) | first) // "answer its prompt")
          elif $state == "Stalled" then "stalled: ask for its done step"
          elif $state == "Zombie" then "agent gone: respawn or retire"
          elif $state == "Failed" then "brief not delivered"
          elif $state == "Done" then (if $pr != "-" then "merge the PR" else "retire the team" end)
          else "-" end)]) as $rows
    | if ($rows | length) == 0 then empty else
        (["TEAM", "ISSUE", "PR", "STATE", "NEEDS YOU"] | @tsv), ($rows[] | @tsv) end' | column -t -s $'\t'
  # Claims in plain words; a taken-over claim gets its own line.
  printf '%s' "$out" | jq -r --arg mykey "$mykey" --arg myname "$myname" '
    [.[] | select((.issue // "") != "" and .tier != "Orchestrator")] | unique_by(.issue)
    | (map(select((.claimed_by // "") == $mykey) | .issue) | join(", ")) as $mine
    | (map(select((.claimed_by // "") != "" and .claimed_by != $mykey) | "\(.issue) by \(.claimed_by)") | join(", ")) as $other
    | (if $mine != "" then "claimed by this Mac" + (if $myname != "" then " (\($myname))" else "" end) + ": " + $mine else empty end),
      (if $other != "" then "claimed by another machine: " + $other else empty end)'
  printf '%s' "$esc" | jq -r '.[] | select(.message | test("claim taken over")) | "claim taken over: \(.name): \(.message[0:80])"'
}
if $verbose; then disk_line; else
  free="$(free_gb 2>/dev/null || true)"; [ -z "$free" ] || [ "$free" -ge "$(warn_free_gb)" ] || disk_line
fi
if ! $verbose; then team_table; fi
# The ENV column appears only once the registry has a team environment; before that the
# output is exactly the 3.0.1 table.
if $verbose; then printf '%s' "$out" | jq -r --argjson all "$all" --arg mykey "$mykey" --arg myname "$myname" --argjson envs "$("$registry" list --envs)" '
  ($envs | length > 0) as $showenv |
  def envcell: ($envs[.team] // null) as $e
    | if $e == null or $e.state == "Down" then "-" elif $e.slot != null then "slot-\($e.slot)-\($e.state)" else $e.state end;
  (any(.[]; (.issue // "") != "")) as $showissue |
  def mcell: (.machine // "-") + (if (.machine_name // "") != "" then " (\(.machine_name))"
    elif .machine == $mykey and $myname != "" then " (\($myname))" else "" end);
  (["AGENT", "TIER", "STATUS", "ESC"] + (if $showenv then ["ENV"] else [] end) + (if $showissue then ["ISSUE"] else [] end)
    + (if $all then ["MACHINE", "HEARTBEAT"] else [] end) + ["HERDR", "ASSIGNMENT"] | @tsv),
  (sort_by(.team, .tier)[] | [.name, .tier, (.status + (if (.status_detail // "") != "" then " (\(.status_detail))" else "" end)), (if (.escalation // "") == "" then "-" else .escalation end)]
    + (if $showenv then [envcell] else [] end) + (if $showissue then [(.issue // "-")] else [] end)
    + (if $all then [mcell, (.heartbeat_age // "-")] else [] end)
    + [.herdr_ref, ((.assignment // "")[0:50])] | @tsv)' |
  column -t -s $'\t'
fi
# Parked teams (park.sh) are not in the table: one compact line each, and one line for the focus.
"$registry" list ${team:+--team "$team"} --parked | jq -r '[.[] | select(.tier != "Orchestrator")] | group_by(.team)[]
  | "parked: \(.[0].team) (\(.[0].parked_reason // "park"), since \((.[0].parked_at // "?")[0:10]))\(if (.[0].issue // "") != "" then ", " + .[0].issue else "" end)"'
[ ! -f "$FLEET_STATE_DIR/focus" ] || printf 'focus: %s\n' "$(cat "$FLEET_STATE_DIR/focus")"
open_esc="$("$registry" escalations --open --not-retired ${team:+--team "$team"})"
if [ "$(printf '%s' "$open_esc" | jq length)" != 0 ]; then
  echo "open escalations:"
  printf '%s' "$open_esc" | jq -r --arg now "${FLEET_NOW:-$(now)}" '.[] | [.name, .severity, .at,
    ((($now | fromdateiso8601) - (.at | fromdateiso8601)) / 60 | floor | tostring + "m ago"), (.message | .[0:80])] | @tsv' | column -t -s $'\t' | sed 's/^/  /'
fi
if $all && [ -z "$claims_file" ]; then echo "peer claims: not provided"; fi
# Which machine this is, so rows from two machines are never confused.
$verbose && printf 'machine: %s%s\n' "$(machine_label)" "${myname:+ ($myname)}" || true
# The launchd loop is installed (its launcher exists) but has no Orchestrator to wake: say so in one line.
if [ -x "$FLEET_STATE_DIR/bin/fleet-tick" ] && [ -z "$(cfg_str orchestrator_ref "")" ] &&
  [ -z "$("$registry" get orchestrator 2>/dev/null | jq -r '.herdr_ref // ""' 2>/dev/null)" ]; then
  echo "loop: no Orchestrator registered; wakes go to notifications only (run registry.sh orchestrator here in its pane)"
fi
