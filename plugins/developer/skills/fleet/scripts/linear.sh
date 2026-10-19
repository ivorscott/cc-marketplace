#!/usr/bin/env bash
# Claims and heartbeat on the Linear API. A claim is this machine's label (fleet:<key>) on the
# issue; the machine's liveness is one `heartbeat=<ISO>` line in that label's description. No
# claim, lease or heartbeat comment is ever posted: the only comment this script can post is the
# single note a takeover leaves.
#
#   linear.sh claim <ISSUE> [--dry-run]       label the issue with this machine's label, set In Progress
#   linear.sh heartbeat                       rewrite the heartbeat line of this machine's label (ONE mutation)
#   linear.sh holder <ISSUE>                  JSON: who holds the issue and their last heartbeat   (read-only)
#   linear.sh peers                           JSON: other machines' claims, for `status.sh --all`   (read-only)
#   linear.sh takeover <ISSUE> [--last-activity ISO]   take an issue over from a lapsed holder
#   linear.sh migrate [--dry-run]             delete this machine's old `fleet-claim:` comments, and rewrite our
#                                             label's description if it still holds a full machine id (a write;
#                                             --dry-run reports it as would_rewrite and mutates nothing)
#   linear.sh has-key                         exit 0 when a key is configured, 3 when not (reads nothing)
#
# KEY. $FLEET_CONFIG_DIR/linear_api_key (default ~/.config/fleet/linear_api_key, one line, mode 600)
# or LINEAR_API_KEY in the Orchestrator's own shell. The key is never printed, never put in argv
# (curl reads its header from stdin with `-K -`) and never logged. Agents never see it: boot unsets
# it and the scope guard denies workers the file. Without a key every subcommand exits 3 with
# "no Linear key"; callers treat 3 as "claims unavailable", never fatal. A key file that is not
# mode 600 is refused (exit 3).
#
# READS AND WRITES are separate. Every query goes through gql_read, which refuses anything that is
# not a query; every mutation goes through gql_write, which refuses anything that is not a
# mutation and, in read-only mode (holder, peers, has-key and every --dry-run), refuses all of
# them. A read-only subcommand cannot mutate even by mistake.
#
# Takeover needs the holder's heartbeat older than lease_hours (config.toml, default 2) AND a quiet
# PR (the Orchestrator reads the PR's last activity and passes it in); FLEET_FORCE never bypasses.
#
# Claim race: the machine label is in a single-select group, and an issue update replaces the
# issue's labels, so the last writer wins; both machines re-read after claim_settle_secs
# (config.toml, default 5) and the one whose label is gone exits 1. This is not compare-and-swap.
#
# UNVERIFIED against the real API: only the endpoint, the Authorization header, issue(id:) and
# issueUpdate with stateId were confirmed from Linear's public docs. The label operations
# (issueLabels filter, issueLabelCreate, issueLabelUpdate), labelIds on issueUpdate,
# workflowStates, commentCreate/commentDelete, and the issues filters are written from memory of
# the schema; the tests prove our calls against a stub only (DEV-368 decision 13).
set -euo pipefail
. "$(dirname "$0")/common.sh"

FLEET_CURL="${FLEET_CURL:-curl}"
LINEAR_URL="${LINEAR_URL:-https://api.linear.app/graphql}"
READONLY=0
KEY=""
GROUP="fleet"

# ---- key ---------------------------------------------------------------------------------------
key_file() { printf '%s/linear_api_key\n' "$FLEET_CONFIG_DIR"; }
no_key() { printf 'fleet: no Linear key (add ~/.config/fleet/linear_api_key on the Orchestrator machine)\n' >&2; exit 3; }
key_mode_ok() { # the file exists and is mode 600; reads nothing from it
  local f m; f="$(key_file)"; [ -f "$f" ] || return 1
  m="$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null)" || return 1
  [ "$m" = 600 ]
}
has_key() {
  [ -n "${LINEAR_API_KEY:-}" ] && return 0
  [ -f "$(key_file)" ] || return 1
  key_mode_ok || { printf 'fleet: the Linear key file must be mode 600; refusing to use it\n' >&2; return 1; }
}
load_key() {
  [ -z "$KEY" ] || return 0
  if [ -n "${LINEAR_API_KEY:-}" ]; then KEY="$LINEAR_API_KEY"
  else
    has_key || no_key
    KEY="$(head -n 1 "$(key_file)" | tr -d '\r\n ')"
  fi
  [ -n "$KEY" ] || no_key
}

# ---- transport ---------------------------------------------------------------------------------
gql() { # gql <operation name> <query> <variables json> → the response, errors turned into failures
  local body resp err
  load_key
  body="$(jq -nc --arg o "$1" --arg q "$2" --argjson v "${3:-{\}}" '{operationName: $o, query: $q, variables: $v}')"
  resp="$(printf 'header = "Authorization: %s"\n' "$KEY" |
    "$FLEET_CURL" -sS -K - -X POST -H 'Content-Type: application/json' -d "$body" "$LINEAR_URL")" || die "Linear request failed"
  printf '%s' "$resp" | jq -e 'type == "object"' >/dev/null 2>&1 || die "Linear returned no JSON"
  err="$(printf '%s' "$resp" | jq -r '.errors[0].message // empty')"
  [ -z "$err" ] || die "Linear: $err"
  printf '%s' "$resp"
}
gql_read() { case "$2" in query*) ;; *) die "internal: gql_read given a non-query ($1)" ;; esac; gql "$@"; }
gql_write() {
  case "$2" in mutation*) ;; *) die "internal: gql_write given a non-mutation ($1)" ;; esac
  [ "$READONLY" != 1 ] || die "internal: mutation $1 attempted in read-only mode"
  gql "$@"
}

# ---- reads (queries only) ------------------------------------------------------------------------
q_issue() { # q_issue <ISSUE> → {id, identifier, team, labels[{id,name}], state}
  gql_read Issue 'query Issue($id: String!) { issue(id: $id) { id identifier team { id } state { id name } labels { nodes { id name } } } }' \
    "$(jq -nc --arg id "$1" '{id: $id}')" | jq -c '.data.issue // error("no such issue")' 2>/dev/null || die "no such issue: $1"
}
q_labels_named() { # q_labels_named <name> → [{id, name, description, parent}]
  gql_read IssueLabels 'query IssueLabels($n: String!) { issueLabels(filter: { name: { eq: $n } }) { nodes { id name description parent { id name } } } }' \
    "$(jq -nc --arg n "$1" '{n: $n}')" | jq -c '.data.issueLabels.nodes // []'
}
q_state_id() { # q_state_id <team id> <state name> → the id, empty when the team has no such state
  gql_read WorkflowStates 'query WorkflowStates($t: ID!, $n: String!) { workflowStates(filter: { team: { id: { eq: $t } }, name: { eq: $n } }) { nodes { id name } } }' \
    "$(jq -nc --arg t "$1" --arg n "$2" '{t: $t, n: $n}')" | jq -r '.data.workflowStates.nodes[0].id // empty'
}
q_open_issues_labelled() { # q_open_issues_labelled <label name | prefix> <eq|startsWith> → issues with labels and comments
  gql_read OpenIssues 'query OpenIssues($n: String!) { issues(first: 100, filter: { labels: { name: { '"$2"': $n } }, state: { type: { nin: ["completed", "canceled"] } } }) { nodes { id identifier labels { nodes { id name description } } comments(first: 100) { nodes { id body } } } } }' \
    "$(jq -nc --arg n "$1" '{n: $n}')" | jq -c '.data.issues.nodes // []'
}

# ---- writes (mutations only) ---------------------------------------------------------------------
m_label_create() { # m_label_create <name> <description> <parent id | ""> <team id | ""> → the new label's id
  gql_write IssueLabelCreate 'mutation IssueLabelCreate($input: IssueLabelCreateInput!) { issueLabelCreate(input: $input) { success issueLabel { id } } }' \
    "$(jq -nc --arg n "$1" --arg d "$2" --arg p "$3" --arg t "$4" \
      '{input: ({name: $n, description: $d} + (if $p != "" then {parentId: $p} else {} end) + (if $t != "" then {teamId: $t} else {} end))}')" |
    jq -r '.data.issueLabelCreate.issueLabel.id // empty'
}
m_label_describe() { # m_label_describe <label id> <description>
  gql_write IssueLabelUpdate 'mutation IssueLabelUpdate($id: String!, $input: IssueLabelUpdateInput!) { issueLabelUpdate(id: $id, input: $input) { success } }' \
    "$(jq -nc --arg id "$1" --arg d "$2" '{id: $id, input: {description: $d}}')" >/dev/null
}
m_issue_update() { # m_issue_update <issue id> <label ids json array> <state id | "">
  gql_write IssueUpdate 'mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }' \
    "$(jq -nc --arg id "$1" --argjson l "$2" --arg s "$3" '{id: $id, input: ({labelIds: $l} + (if $s != "" then {stateId: $s} else {} end))}')" >/dev/null
}
m_comment_create() { # m_comment_create <issue id> <body>
  gql_write CommentCreate 'mutation CommentCreate($input: CommentCreateInput!) { commentCreate(input: $input) { success } }' \
    "$(jq -nc --arg i "$1" --arg b "$2" '{input: {issueId: $i, body: $b}}')" >/dev/null
}
m_comment_delete() { # m_comment_delete <comment id>
  gql_write CommentDelete 'mutation CommentDelete($id: String!) { commentDelete(id: $id) { success } }' \
    "$(jq -nc --arg id "$1" '{id: $id}')" >/dev/null
}

# ---- helpers (no API calls) ----------------------------------------------------------------------
hb_of() { printf '%s\n' "$1" | "$FLEET_SCRIPTS/claim.sh" hb; }
describe_with_hb() { # describe_with_hb <description> <ISO>: the description with its heartbeat line set
  printf '%s\n' "$1" | awk -v hb="heartbeat=$2" '
    /^heartbeat=/ { if (!d) { print hb; d = 1 } ; next }
    NF { print }
    END { if (!d) print hb }'
}
other_fleet_labels() { # other_fleet_labels <issue json> → names of fleet labels on it that are not ours
  local mine; mine="$(machine_label)"
  printf '%s' "$1" | jq -r --arg p "$(label_prefix)" --arg m "$mine" '.labels.nodes[] | select((.name | startswith($p)) and .name != $m) | .name'
}
say() { jq -nc "$@"; }

# legacy_ids_hashed <description>: the description with every full machine id (a UUID or 32 hex
# characters) replaced by sha256:<first 12 hex of its sha256>. Older versions published the full
# hardware id; the rest of the text, the heartbeat= line included, is kept as it was.
legacy_ids_hashed() {
  local d="$1" id h re='([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})|([0-9A-Fa-f]{32})'
  while [[ "$d" =~ $re ]]; do
    id="${BASH_REMATCH[0]}"; h="$("$FLEET_SCRIPTS/machine-id.sh" hash "$id")"
    d="${d/"$id"/sha256:$h}"
  done
  printf '%s' "$d"
}

# ensure_label <team id> <dry>: prints our label id (creating the group and the label as needed).
# An empty description is filled; a non-empty one is never overwritten.
ensure_label() {
  local team="$1" dry="$2" mine desc found lid gid grp now_iso cur new
  mine="$(machine_label)"; desc="$("$FLEET_SCRIPTS/machine-id.sh" description)"; now_iso="${FLEET_NOW:-$(now)}"
  found="$(q_labels_named "$mine")"
  lid="$(printf '%s' "$found" | jq -r '.[0].id // empty')"
  if [ -n "$lid" ]; then
    cur="$(printf '%s' "$found" | jq -r '.[0].description // ""')"
    if [ -z "$cur" ]; then
      if [ "$dry" = 1 ]; then say --arg l "$mine" '{would: "fill the empty description", label: $l}' >&2
      else m_label_describe "$lid" "$(describe_with_hb "$desc" "$now_iso")"; fi
    else
      new="$(legacy_ids_hashed "$cur")"
      if [ "$new" != "$cur" ]; then
        if [ "$dry" = 1 ]; then say --arg l "$mine" '{would_rewrite: "replace the full machine id with its hash", label: $l}' >&2
        else m_label_describe "$lid" "$new"; fi
      fi
    fi
    printf '%s\n' "$lid"; return 0
  fi
  gid="$(q_labels_named "$GROUP" | jq -r '[.[] | select(.parent == null)][0].id // empty')"
  if [ "$dry" = 1 ]; then
    [ -n "$gid" ] || say --arg g "$GROUP" '{would: "create the group label", label: $g}' >&2
    say --arg l "$mine" '{would: "create the machine label", label: $l}' >&2
    printf 'dry-run-label\n'; return 0
  fi
  [ -n "$gid" ] || gid="$(m_label_create "$GROUP" "fleet machines" "" "$team")"
  m_label_create "$mine" "$(describe_with_hb "$desc" "$now_iso")" "$gid" "$team"
}

# ---- subcommands ---------------------------------------------------------------------------------
cmd="${1:-}"; [ $# -gt 0 ] && shift
# Every API subcommand needs the key; check it here, at the top level, so a missing key is exit 3
# and not an error swallowed inside a command substitution.
case "$cmd" in claim | heartbeat | holder | peers | takeover | migrate) load_key ;; esac
case "$cmd" in
  has-key)
    has_key || no_key ;;

  holder)
    READONLY=1
    issue="${1:?usage: holder <ISSUE>}"
    iss="$(q_issue "$issue")"
    other="$(other_fleet_labels "$iss" | head -n 1)"
    mine="$(machine_label)"
    label="$other"; [ -n "$label" ] || label="$(printf '%s' "$iss" | jq -r --arg m "$mine" '.labels.nodes[] | select(.name == $m) | .name')"
    hb=""
    if [ -n "$label" ]; then hb="$(hb_of "$(q_labels_named "$label" | jq -r '.[0].description // ""')")"; fi
    say --arg i "$issue" --arg h "$label" --arg m "$mine" --arg hb "$hb" \
      '{issue: $i, holder: (if $h == "" then null else $h end), ours: ($h == $m), heartbeat: (if $hb == "" then null else $hb end)}' ;;

  peers)
    READONLY=1
    mine="$(machine_label)"
    q_open_issues_labelled "$(label_prefix)" startsWith | jq -c --arg p "$(label_prefix)" --arg m "$mine" '
      [.[] | . as $i | .labels.nodes[] | select((.name | startswith($p)) and .name != $m)
        | {machine: (.name | ltrimstr($p)), label: .name, issue: $i.identifier, heartbeat: ([(.description // "") | match("(^|\n)heartbeat=([^\n ]+)").captures[1].string] | first // null)}]' ;;

  claim)
    dry=0; issue=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run) dry=1; READONLY=1; shift ;;
        -*) die "unknown option: $1" ;;
        *) issue="$1"; shift ;;
      esac
    done
    [ -n "$issue" ] || die "usage: claim <ISSUE> [--dry-run]"
    mine="$(machine_label)"
    iss="$(q_issue "$issue")"
    iid="$(printf '%s' "$iss" | jq -r .id)"; team="$(printf '%s' "$iss" | jq -r .team.id)"
    holder="$(other_fleet_labels "$iss" | head -n 1)"
    if [ -n "$holder" ]; then die "$issue is claimed by $holder; this machine is $mine. Not claiming"; fi
    lid="$(ensure_label "$team" "$dry")"
    sid="$(q_state_id "$team" "In Progress")"
    keep="$(printf '%s' "$iss" | jq -c --arg p "$(label_prefix)" '[.labels.nodes[] | select(.name | startswith($p) | not) | .id]')"
    ids="$(jq -cn --argjson k "$keep" --arg l "$lid" '$k + [$l] | unique')"
    if [ "$dry" = 1 ]; then
      say --arg i "$issue" --argjson l "$ids" --arg s "$sid" '{would: "update the issue", issue: $i, labelIds: $l, stateId: $s}'
      exit 0
    fi
    m_issue_update "$iid" "$ids" "$sid"
    sleep "$(cfg_int claim_settle_secs 5)"
    after="$(q_issue "$issue")"
    if printf '%s' "$after" | jq -e --arg m "$mine" 'any(.labels.nodes[]; .name == $m)' >/dev/null; then
      say --arg i "$issue" --arg m "$mine" '{claimed: true, issue: $i, label: $m}'
    else
      who="$(other_fleet_labels "$after" | head -n 1)"
      printf 'fleet: lost the claim on %s to %s\n' "$issue" "${who:-another machine}" >&2; exit 1
    fi ;;

  heartbeat)
    mine="$(machine_label)"
    found="$(q_labels_named "$mine")"
    lid="$(printf '%s' "$found" | jq -r '.[0].id // empty')"
    if [ -z "$lid" ]; then say '{heartbeat: false, reason: "no machine label yet; nothing claimed"}'; exit 0; fi
    ts="${FLEET_NOW:-$(now)}"
    m_label_describe "$lid" "$(describe_with_hb "$(printf '%s' "$found" | jq -r '.[0].description // ""')" "$ts")"
    say --arg t "$ts" '{heartbeat: true, at: $t}' ;;

  takeover)
    issue=""; act=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --last-activity) act="${2:?--last-activity needs a value}"; shift 2 ;;
        -*) die "unknown option: $1" ;;
        *) issue="$1"; shift ;;
      esac
    done
    [ -n "$issue" ] || die "usage: takeover <ISSUE> [--last-activity ISO]"
    mine="$(machine_label)"
    iss="$(q_issue "$issue")"
    holder="$(other_fleet_labels "$iss" | head -n 1)"
    [ -n "$holder" ] || die "$issue is not claimed by another machine; claim it instead"
    hb="$(hb_of "$(q_labels_named "$holder" | jq -r '.[0].description // ""')")"
    [ -n "$hb" ] || die "$holder has no heartbeat; cannot show its claim lapsed. Not taking over"
    lease="$("$FLEET_SCRIPTS/claim.sh" lease --now "$hb")"
    eargs=(expired --lease "$lease" --now "${FLEET_NOW:-$(now)}"); [ -z "$act" ] || eargs+=(--last-activity "$act")
    why="$("$FLEET_SCRIPTS/claim.sh" "${eargs[@]}" 2>&1)" || die "$issue is claimed by $holder ($why). Not taking over"
    iid="$(printf '%s' "$iss" | jq -r .id)"; team="$(printf '%s' "$iss" | jq -r .team.id)"
    lid="$(ensure_label "$team" 0)"
    sid="$(q_state_id "$team" "In Progress")"
    keep="$(printf '%s' "$iss" | jq -c --arg p "$(label_prefix)" '[.labels.nodes[] | select(.name | startswith($p) | not) | .id]')"
    m_issue_update "$iid" "$(jq -cn --argjson k "$keep" --arg l "$lid" '$k + [$l] | unique')" "$sid"
    m_comment_create "$iid" "fleet: taken over from $holder (heartbeat $hb, PR quiet since ${act:-no PR})"
    say --arg i "$issue" --arg f "$holder" --arg m "$mine" '{taken_over: true, issue: $i, from: $f, by: $m}' ;;

  migrate)
    dry=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run) dry=1; READONLY=1; shift ;;
        *) die "unknown option: $1" ;;
      esac
    done
    mine="$(machine_label)"; key="$(machine_key)"
    victims="$(q_open_issues_labelled "$mine" eq | jq -c --arg k "$key" '
      [.[] | . as $i | .comments.nodes[]
        | select((.body | startswith("fleet-claim:")) and (([.body | split("\n")[0] | scan("machine=([^ ]+)")[0]] | first) == $k))
        | {id, issue: $i.identifier}]')"
    # An existing label that still holds a full machine id is rewritten to the hashed form.
    found="$(q_labels_named "$mine")"
    lid="$(printf '%s' "$found" | jq -r '.[0].id // empty')"; cur="$(printf '%s' "$found" | jq -r '.[0].description // ""')"
    new="$(legacy_ids_hashed "$cur")"; rewrite=false; { [ -n "$lid" ] && [ "$new" != "$cur" ]; } && rewrite=true
    if [ "$dry" = 1 ]; then say --argjson v "$victims" --argjson r "$rewrite" '{would_delete: $v, would_rewrite: $r}'; exit 0; fi
    for id in $(printf '%s' "$victims" | jq -r '.[].id'); do m_comment_delete "$id"; done
    if $rewrite; then m_label_describe "$lid" "$new"; fi
    say --argjson v "$victims" --argjson r "$rewrite" '{deleted: ($v | length), rewrote_label: $r}' ;;

  *) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
