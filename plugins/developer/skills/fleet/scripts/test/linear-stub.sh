#!/usr/bin/env bash
# A fake Linear API for the tests: linear.sh calls it as FLEET_CURL. It never touches the network.
#
#   LINEAR_DB            JSON state: {team, states: {name: id}, labels: [...], issues: [...], next}; an issue's
#                        optional `blocks` and `related` (identifiers) answer the Blocks query as relations of
#                        those types
#   LINEAR_LOG           one line per operation: "query|mutation <OperationName>"
#   LINEAR_ARGV_LOG      one line per call with its argv (the key is never in it; it arrives on stdin)
#   LINEAR_STUB_KEY      the key the stub accepts, read from the `-K -` config on stdin
#   LINEAR_STUB_RACE     label name: after an issueUpdate, another machine "wins" and replaces the labels
# An unknown operation is logged as "UNKNOWN <name>" and answered with an error.
set -u
body=""; cfg=""
echo "$*" >>"${LINEAR_ARGV_LOG:-/dev/null}"
while [ $# -gt 0 ]; do
  case "$1" in
    -d) body="$2"; shift 2 ;;
    -K) cfg="$(cat)"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$cfg" != "header = \"Authorization: ${LINEAR_STUB_KEY:-}\"" ]; then echo '{"errors":[{"message":"authentication failed"}]}'; exit 0; fi
op="$(printf '%s' "$body" | jq -r .operationName)"
kind="$(printf '%s' "$body" | jq -r '.query | split(" ")[0]')"
vars="$(printf '%s' "$body" | jq -c .variables)"
query="$(printf '%s' "$body" | jq -r .query)"
printf '%s %s\n' "$kind" "$op" >>"$LINEAR_LOG"
db() { jq -c "$@" "$LINEAR_DB"; }
save() { printf '%s\n' "$1" >"$LINEAR_DB"; }
ok() { jq -nc --argjson d "$1" '{data: $d}'; }

case "$op" in
  Issue)
    db --argjson v "$vars" '
      (.issues[] | select(.identifier == $v.id or .id == $v.id)) as $i
      | {issue: {id: $i.id, identifier: $i.identifier, team: $i.team, state: $i.state,
          labels: {nodes: [$i.labelIds[] as $l | .labels[] | select(.id == $l) | {id, name}]}}}' >"$LINEAR_DB.out"
    if [ -s "$LINEAR_DB.out" ]; then ok "$(cat "$LINEAR_DB.out")"; else ok '{"issue": null}'; fi ;;
  Viewer)
    ok "$(db '{viewer: {id: "U1", name: (.viewer.name // "Fixture Owner")}}')" ;;
  IssueTeamKey)
    ok "$(db --argjson v "$vars" '{issue: ((.issues[] | select(.identifier == $v.id)) | {identifier, team: {key: (.team.key // "ENG")}})}')" ;;
  IssueBranch)
    ok "$(db --argjson v "$vars" '{issue: ((.issues[] | select(.identifier == $v.id)) | {identifier, branchName: (.branchName // "")})}')" ;;
  Blocks)
    ok "$(db --argjson v "$vars" '. as $r | $v | with_entries(.value as $id
      | .value = ([$r.issues[] | select(.identifier == $id)] | first
        | if . == null then null else {identifier, relations: {nodes: ([(.blocks // [])[] | {type: "blocks", relatedIssue: {identifier: .}}]
            + [(.related // [])[] | {type: "related", relatedIssue: {identifier: .}}])}} end))')" ;;
  IssueLabels)
    ok "$(db --argjson v "$vars" '{issueLabels: {nodes: [.labels[] | select(.name == $v.n) | . + {team: (if (.teamId // null) != null then {id: .teamId} else null end)} | del(.teamId)]}}')" ;;
  WorkflowStates)
    ok "$(db --argjson v "$vars" '{workflowStates: {nodes: [(.states[$v.n] // empty) | {id: ., name: $v.n}]}}')" ;;
  IssueLabelCreate)
    new="$(db --argjson v "$vars" '
      (.next + 1) as $n | ("L" + ($n | tostring)) as $id
      | .next = $n
      | .labels += [{id: $id, name: $v.input.name, description: ($v.input.description // ""),
          teamId: $v.input.teamId, parent: (if $v.input.parentId then (.labels[] | select(.id == $v.input.parentId) | {id, name}) else null end)}]')"
    save "$new"
    ok "$(printf '%s' "$new" | jq -c '{issueLabelCreate: {success: true, issueLabel: {id: .labels[-1].id}}}')" ;;
  IssueLabelUpdate)
    save "$(db --argjson v "$vars" '.labels |= map(if .id == $v.id then .description = $v.input.description else . end)')"
    ok '{"issueLabelUpdate": {"success": true}}' ;;
  IssueUpdate)
    save "$(db --argjson v "$vars" '. as $r | .issues |= map(if .id == $v.id then
        (if $v.input.labelIds then .labelIds = $v.input.labelIds else . end)
        | (if $v.input.stateId then .state = {id: $v.input.stateId, name: ([$r.states | to_entries[] | select(.value == $v.input.stateId) | .key] | first // "?")} else . end)
        else . end)')"
    if [ -n "${LINEAR_STUB_RACE:-}" ]; then # another machine wrote after us: the group is single-select
      save "$(db --arg r "$LINEAR_STUB_RACE" '(.labels[] | select(.name == $r) | .id) as $rid | .issues |= map(.labelIds = [$rid])')"
    fi
    ok '{"issueUpdate": {"success": true}}' ;;
  CommentCreate)
    save "$(db --argjson v "$vars" '(.next + 1) as $n | .next = $n | .issues |= map(if .id == $v.input.issueId then .comments += [{id: ("C" + ($n | tostring)), body: $v.input.body}] else . end)')"
    ok '{"commentCreate": {"success": true}}' ;;
  CommentDelete)
    save "$(db --argjson v "$vars" '.issues |= map(.comments |= map(select(.id != $v.id)))')"
    ok '{"commentDelete": {"success": true}}' ;;
  Candidates)
    ok "$(db '. as $r | {issues: {nodes: [.issues[] | select(.state.name != "Done" and .state.name != "Canceled") | . as $i
      | {identifier, state: {name: .state.name, type: (if .state.name == "In Progress" then "started" else "unstarted" end)},
         labels: {nodes: [$i.labelIds[] as $l | $r.labels[] | select(.id == $l) | {name, description}]},
         inverseRelations: {nodes: [($i.blocked_by // [])[] | {type: "blocks", issue: {identifier: ., state: {type: "started"}}}]}}]}}')" ;;
  OpenIssues)
    mode=eq; case "$query" in *startsWith*) mode=startsWith ;; esac
    ok "$(db --argjson v "$vars" --arg mode "$mode" '
      . as $r | {issues: {nodes: [.issues[] | select(.state.name != "Done" and .state.name != "Canceled") | . as $i
        | ([$i.labelIds[] as $l | $r.labels[] | select(.id == $l)]) as $ls
        | select(any($ls[]; if $mode == "eq" then .name == $v.n else (.name | startswith($v.n)) end))
        | {id: $i.id, identifier: $i.identifier, labels: {nodes: ($ls | map({id, name, description}))}, comments: {nodes: $i.comments}}]}}')" ;;
  *)
    echo "UNKNOWN $op" >>"$LINEAR_LOG"
    echo '{"errors":[{"message":"unknown operation"}]}' ;;
esac
