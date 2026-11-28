#!/usr/bin/env bash
# Team lifecycle (5.0): the seven team states derived in one place (common.sh LIFECYCLE_JQ), and the statechart
# beside the spec. Pure: no registry, no herdr, no tick. Sourced by run.sh (ok/eq/check, $SCRIPTS).

lc() { bash -c '. "$1/common.sh"; team_lifecycle "$2"' _ "$SCRIPTS" "$1" | jq -r '.state + (if .reason != "" then ":" + .reason else "" end)'; }

lifecycle_states() {
  local rest='{"live":"rest"}' run='{"live":"running"}'
  eq "lifecycle: an agent mid-turn is Working" "$(lc "{\"agents\":[$rest,$run]}")" Working
  eq "lifecycle: at rest with a named wait is Waiting, and says on what" "$(lc "{\"agents\":[$rest],\"wait\":\"CI on a1b2c3d\"}")" "Waiting:CI on a1b2c3d"
  eq "lifecycle: at rest with no wait is Idle" "$(lc "{\"agents\":[$rest,$rest]}")" Idle
  eq "lifecycle: still idle after the nudge is Stalled" "$(lc "{\"agents\":[$rest],\"nudged\":true}")" "Stalled:idle after a nudge"
  eq "lifecycle: a named wait is never Stalled by an old nudge" "$(lc "{\"agents\":[$rest],\"nudged\":true,\"wait\":\"#57 to merge\"}")" "Waiting:#57 to merge"
  eq "lifecycle: an agent that is gone is Stalled, whatever the others do" "$(lc "{\"agents\":[$run,{\"live\":\"gone\"}]}")" "Stalled:an agent is gone"
  eq "lifecycle: a brief that did not arrive is Stalled" "$(lc "{\"agents\":[{\"live\":\"rest\",\"brief_failed\":true}]}")" "Stalled:a brief did not arrive"
  eq "lifecycle: a blocked prompt is Stalled" "$(lc "{\"agents\":[{\"live\":\"rest\",\"blocked\":true}]}")" "Stalled:a prompt blocks an agent"
  eq "lifecycle: signed off, green and mergeable at rest is Ready" "$(lc "{\"agents\":[$rest],\"ready\":true}")" Ready
  eq "lifecycle: an idle team whose PR turned ready is Ready, not nudged" "$(lc "{\"agents\":[$rest],\"ready\":true,\"nudged\":true}")" Ready
  eq "lifecycle: a ready team with an agent mid-turn is Working" "$(lc "{\"agents\":[$run],\"ready\":true}")" Working
  eq "lifecycle: Parked wins over everything but Retired" "$(lc "{\"parked\":true,\"ready\":true,\"agents\":[{\"live\":\"gone\"}]}")" Parked
  eq "lifecycle: Retired wins" "$(lc "{\"retired\":true,\"parked\":true,\"agents\":[$run]}")" Retired
  eq "lifecycle: a restarted worker counts as running: the team is Working, not Done" "$(lc "{\"agents\":[$rest,{\"live\":\"running\",\"done\":true}]}")" Working
  eq "lifecycle: every state names who moves next" \
    "$(for f in '{"agents":[{"live":"running"}]}' '{"agents":[],"wait":"x"}' '{"agents":[]}' '{"agents":[],"nudged":true}' '{"agents":[],"ready":true}' '{"parked":true}' '{"retired":true}'; do
        bash -c '. "$1/common.sh"; team_lifecycle "$2"' _ "$SCRIPTS" "$f" | jq -r 'select(.next != "") | .state'; done | tr '\n' ' ')" \
    "Working Waiting Idle Stalled Ready Parked Retired "
}

lifecycle_chart() { # the statechart names the same seven states, and only those
  local c="$SCRIPTS/../../../../../specs/fleet/lifecycle.statechart.json"
  eq "lifecycle: the statechart has the seven states" "$(jq -r '.states | keys | sort | join(",")' "$c")" "Idle,Parked,Ready,Retired,Stalled,Waiting,Working"
  eq "lifecycle: every transition targets a state of the chart" \
    "$(jq -r '(.states | keys) as $k | [(.states[] | (.on // {})[]), (.on // {})[]] | map(select(. as $t | $k | index($t) | not)) | length' "$c")" 0
  eq "lifecycle: every state the code can return is in the chart" \
    "$(grep -o 'state: "[A-Za-z]*"' "$SCRIPTS/common.sh" | sort -u | sed 's/state: "\(.*\)"/\1/' | while read -r st; do jq -e --arg s "$st" '.states | has($s)' "$c" >/dev/null || echo "$st"; done | wc -l | tr -d ' ')" 0
}

lifecycle_smoke() { lifecycle_states; lifecycle_chart; }
lifecycle_full() { lifecycle_smoke; }
