#!/usr/bin/env bash
# Claims and heartbeat on the Linear API. A claim is this machine's label (fleet:<key>) on the
# issue; the machine's liveness is one `heartbeat=<ISO>` line in that label's description. No
# claim, lease or heartbeat comment is ever posted: the only comment this script can post is the
# single note a takeover leaves.
#
#   linear.sh claim <ISSUE> [--dry-run]       label the issue with this machine's label, set In Progress
#   linear.sh heartbeat                       rewrite the heartbeat line of this machine's label (ONE mutation)
#   linear.sh holder <ISSUE>                  JSON: who holds the issue, their last heartbeat and whether it lapsed
#                                             (`lapsed`: older than lease_hours, takeover's own check; null without a
#                                             heartbeat)   (read-only)
#   linear.sh peers                           JSON: other machines' claims {machine, label, issue, heartbeat, summary}, for
#                                             `fleet status` (summary: the parsed `summary=` line, null when there is none)   (read-only)
#   linear.sh blocks <ISSUE...>               JSON: {"<ISSUE>": [issues it blocks]} from Linear's `blocks` relations,
#                                             one query for all of them   (read-only)
#   linear.sh takeover <ISSUE> [--repo OWNER/NAME]   take an issue over from a lapsed holder; refuses while an
#                                             open PR exists for the issue (see Takeover below)
#   linear.sh release <ISSUE> [--lapsed [--repo OWNER/NAME]]   remove this machine's label (and its legacy label) from
#                                             the issue, keeping the rest; refuses an issue this machine does not hold.
#                                             --lapsed removes another machine's label instead, only with takeover's
#                                             guards (heartbeat older than lease_hours, no open PR); nothing is posted.
#                                             --repo may repeat: the open PR is looked up in every one given (tick's
#                                             sweep passes the fleet's repos), else in the cwd's repo
#   linear.sh state <ISSUE> <Done|Verify|Todo>   move the issue to that workflow state, labels untouched; refuses an
#                                             issue another machine holds
#   linear.sh migrate [--dry-run]             delete this machine's old `fleet-claim:` comments, and rewrite our
#                                             label's description if it still holds a full machine id (a write;
#                                             --dry-run reports it as would_rewrite and mutates nothing)
#   linear.sh whoami                          JSON: the key's Linear user {id, name}   (read-only)
#   linear.sh has-key                         exit 0 when a key is configured, 3 when not (reads nothing)
#
# WRITES. `linear_writes = off | test:FT | on` in config.toml, default off. Off: every write, and every
# subcommand that would write, exits 3 ("Linear writes are off") before any call, the same path as
# having no key. test:FT: each write is cleared on its own: an issue update or a comment only on an issue
# of Linear team FT (the team key is read first, so a refusal makes no mutation and names the team), and a
# label create or description update only of this machine's own fleet:<key> label. Nothing else is
# written in test mode: not the workspace-wide `fleet` group label (create it in Linear first). on: no
# restriction. Reads and --dry-runs never need it. A write the test guard has not cleared is refused.
#
# OWNER. The machine label's description carries `owner=<Linear user name>` (one `viewer` read,
# cached for the tick in $FLEET_STATE_DIR/viewer.cache.json, keyed by FLEET_TICK_ID), kept next to
# the hashed machine id and the heartbeat= line by claim, heartbeat and migrate.
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
# Known gap, accepted (DEV-368): the PR search finds a PR by the issue key in its title or body. A PR on
# boot's fleet/<team>/<role> branch whose title and body never name the key is not found, and a takeover goes
# ahead. House rules make every fleet PR body link its issue, which is what the search relies on.
#
# Takeover needs the holder's heartbeat older than lease_hours (config.toml, default 2) AND no open PR. It
# looks the PR up itself (gh, read-only, in the current repo or --repo; same-repo PRs only): any open PR on
# fleet/<slug>[-/...] or on the issue's Linear branch, and any open PR whose title or body names the issue
# key (`gh pr list --search '<KEY> in:title,body'`), whatever its branch: boot's fleet/<team>/<role> too.
# It refuses while one is open or when it cannot look. FLEET_FORCE never bypasses. Like claim, it then
# re-reads after claim_settle_secs: of two takeovers at once only the one whose label stayed wins and
# comments; the other exits 1. `release --lapsed` makes the same checks and removes the label without taking it.
#
# Labels are looked up by name; when several match (an older team label beside the workspace one), the
# workspace label (no team) is used, for the group and for each machine label alike.
#
# Claim race: the machine label is in a single-select group, and an issue update replaces the
# issue's labels, so the last writer wins; both machines re-read after claim_settle_secs
# (config.toml, default 5) and the one whose label is gone exits 1. This is not compare-and-swap.
#
# UNVERIFIED against the real API: only the endpoint, the Authorization header, issue(id:) and
# issueUpdate with stateId were confirmed from Linear's public docs. The label operations
# (issueLabels filter, issueLabelCreate, issueLabelUpdate), labelIds on issueUpdate,
# workflowStates, commentCreate/commentDelete, the issues filters and the issue `relations` read by
# `blocks` are written from memory of the schema; the tests prove our calls against a stub only
# (DEV-368 decision 13).
set -euo pipefail
. "$(dirname "$0")/common.sh"

# The Orchestrator's script: a fleet agent (FLEET_ROLE set) never runs it, and the transport is fixed outside the
# tests, so an agent cannot point FLEET_CURL or LINEAR_URL at a program of its own and have the key piped to it.
[ -z "${FLEET_ROLE:-}" ] || die "linear.sh is the Orchestrator's; a fleet agent may not run it"
# Outside the tests curl is an absolute path from a fixed list (the caller's PATH is only a last resort) and runs
# with -q as its first argument (no ~/.curlrc, which could set a proxy or a trace file). FLEET_CURL and LINEAR_URL
# are honoured only when ALL hold: FLEET_TEST=1; the state dir is not the live one; LINEAR_API_KEY is not set (the key
# is not from the environment); and the key file is not under the real ~/.config/fleet. The live paths are worked out
# from the real home (FLEET_REAL_HOME, else HOME, as common.sh does), physically resolved and compared in lower case.
# When FLEET_TEST=1 asks for an override that fails one of these, linear.sh refuses (exit 1) rather than sending the key
# anywhere: a transport of the caller's never sees a real key, and the tests never reach the network by accident.
# RESIDUAL, accepted (DEV-368): FLEET_ROLE is an environment convention. An agent can blank it (`FLEET_ROLE= ...`)
# and run this script as the Orchestrator would, and the key file is readable by any process of the same user in
# any case. The guards catch mistakes; they are not a security boundary (README). A keychain store is a follow-up.
lcase() { printf '%s' "$1" | LC_ALL=C tr ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz; }
physical() { # physical <path>: the nearest existing parent made physical, the rest appended, a symlink followed (10 hops)
  local p="$1" d rest hops=0 t
  while :; do
    d="$(dirname "$p")"; rest="$(basename "$p")"
    while [ ! -d "$d" ] && [ "$d" != / ]; do rest="$(basename "$d")/$rest"; d="$(dirname "$d")"; done
    p="$(cd "$d" && pwd -P)/$rest"
    if [ -L "$p" ] && [ "$hops" -lt 10 ]; then t="$(readlink "$p")"; case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac; hops=$((hops + 1)); else break; fi
  done
  printf '%s\n' "$p"
}
override_ok() { # the FLEET_CURL / LINEAR_URL override is safe: nothing it sees is the live state or the live key
  local home live_state live_cfg st kf
  [ "${FLEET_TEST:-}" = 1 ] && [ -z "${LINEAR_API_KEY:-}" ] || return 1
  home="$(physical "${FLEET_REAL_HOME:-${HOME:-/nonexistent}}")"
  live_state="$(lcase "$home/.local/state/fleet")"; live_cfg="$(lcase "$home/.config/fleet")"
  st="$(lcase "$(physical "$FLEET_STATE_DIR")")"; kf="$(lcase "$(physical "$FLEET_CONFIG_DIR/linear_api_key")")"
  case "$st/" in "$live_state/"*) return 1 ;; esac
  case "$kf" in "$live_cfg/"*) return 1 ;; esac
  return 0
}
if [ "${FLEET_TEST:-}" = 1 ] && { [ -n "${FLEET_CURL:-}" ] || [ -n "${LINEAR_URL:-}" ]; }; then
  override_ok || die "FLEET_TEST=1 with FLEET_CURL or LINEAR_URL, but the key or the state dir is the live one (or LINEAR_API_KEY is set); refusing, nothing was sent"
fi
if [ "${FLEET_TEST:-}" = 1 ] && override_ok; then FLEET_CURL="${FLEET_CURL:-curl}"; LINEAR_URL="${LINEAR_URL:-https://api.linear.app/graphql}"; CURL_Q=-q
else
  FLEET_CURL=""; for _c in /usr/bin/curl /opt/homebrew/bin/curl /usr/local/bin/curl /bin/curl; do [ -x "$_c" ] && { FLEET_CURL="$_c"; break; }; done
  [ -n "$FLEET_CURL" ] || FLEET_CURL="$(command -v curl || true)"
  [ -n "$FLEET_CURL" ] || die "no curl found"
  LINEAR_URL="https://api.linear.app/graphql"; CURL_Q=-q
fi
READONLY=0
KEY=""
WMODE="$(linear_writes)"
TEST_TEAM=""; case "$WMODE" in test:*) TEST_TEAM="${WMODE#test:}" ;; esac
CLEARED=""; ISSUES_OK=""; OWN_LID=""
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
    "$FLEET_CURL" ${CURL_Q:+"$CURL_Q"} -sS -K - -X POST -H 'Content-Type: application/json' -d "$body" "$LINEAR_URL")" || die "Linear request failed"
  printf '%s' "$resp" | jq -e 'type == "object"' >/dev/null 2>&1 || die "Linear returned no JSON"
  err="$(printf '%s' "$resp" | jq -r '.errors[0].message // empty')"
  [ -z "$err" ] || die "Linear: $err"
  printf '%s' "$resp"
}
gql_read() { case "$2" in query*) ;; *) die "internal: gql_read given a non-query ($1)" ;; esac; gql "$@"; }
writes_off() { printf 'fleet: Linear writes are off (set linear_writes = "on", or "test:FT", in config.toml)\n' >&2; exit 3; }
gql_write() {
  [ "$WMODE" != off ] || writes_off
  case "$2" in mutation*) ;; *) die "internal: gql_write given a non-mutation ($1)" ;; esac
  [ "$READONLY" != 1 ] || die "internal: mutation $1 attempted in read-only mode"
  [ -z "$TEST_TEAM" ] || [ "$CLEARED" = "$1" ] || die "internal: write $1 was not cleared by the test-mode guard (linear_writes = test:$TEST_TEAM)"
  CLEARED=""
  gql "$@"
}
# clear_write <operation> <issue id | label id | label name>: in test mode, let exactly this one write through when
# it touches an issue that guard_issue cleared, or this machine's own label; refuse anything else, before any call.
clear_write() {
  CLEARED="$1"; [ -n "$TEST_TEAM" ] || return 0
  case "$1" in
    IssueUpdate | CommentCreate | CommentDelete) case " $ISSUES_OK " in *" $2 "*) return 0 ;; esac ;;
    IssueLabelUpdate) [ -z "$OWN_LID" ] || [ "$2" != "$OWN_LID" ] || return 0 ;;
    IssueLabelCreate) [ "$2" != "$(machine_label)" ] || return 0 ;;
  esac
  die "test mode (linear_writes = test:$TEST_TEAM): $1 on $2 is outside team $TEST_TEAM and this machine's own label. Nothing was written"
}

# ---- reads (queries only) ------------------------------------------------------------------------
q_issue() { # q_issue <ISSUE> → {id, identifier, team, labels[{id,name}], state}
  gql_read Issue 'query Issue($id: String!) { issue(id: $id) { id identifier team { id } state { id name } labels { nodes { id name } } } }' \
    "$(jq -nc --arg id "$1" '{id: $id}')" | jq -c '.data.issue // error("no such issue")' 2>/dev/null || die "no such issue: $1"
}
q_labels_named() { # q_labels_named <name> → [{id, name, description, parent, team}], workspace labels (team null) first
  gql_read IssueLabels 'query IssueLabels($n: String!) { issueLabels(filter: { name: { eq: $n } }) { nodes { id name description parent { id name } team { id } } } }' \
    "$(jq -nc --arg n "$1" '{n: $n}')" | jq -c '(.data.issueLabels.nodes // []) | map(select(.team == null)) + map(select(.team != null))'
}
q_state_id() { # q_state_id <team id> <state name> → the id, empty when the team has no such state
  gql_read WorkflowStates 'query WorkflowStates($t: ID!, $n: String!) { workflowStates(filter: { team: { id: { eq: $t } }, name: { eq: $n } }) { nodes { id name } } }' \
    "$(jq -nc --arg t "$1" --arg n "$2" '{t: $t, n: $n}')" | jq -r '.data.workflowStates.nodes[0].id // empty'
}
q_open_issues_labelled() { # q_open_issues_labelled <label name | prefix> <eq|startsWith> → issues with labels and comments
  gql_read OpenIssues 'query OpenIssues($n: String!) { issues(first: 100, filter: { labels: { name: { '"$2"': $n } }, state: { type: { nin: ["completed", "canceled"] } } }) { nodes { id identifier labels { nodes { id name description } } comments(first: 100) { nodes { id body } } } } }' \
    "$(jq -nc --arg n "$1" '{n: $n}')" | jq -c '.data.issues.nodes // []'
}

q_issue_team_key() { # q_issue_team_key <ISSUE> → the team key of the issue, empty when unknown
  gql_read IssueTeamKey 'query IssueTeamKey($id: String!) { issue(id: $id) { identifier team { key } } }' \
    "$(jq -nc --arg id "$1" '{id: $id}')" | jq -r '.data.issue.team.key // empty'
}
q_issue_branch() { # q_issue_branch <ISSUE> → Linear's suggested git branch for the issue, empty when unknown
  gql_read IssueBranch 'query IssueBranch($id: String!) { issue(id: $id) { identifier branchName } }' \
    "$(jq -nc --arg id "$1" '{id: $id}')" | jq -r '.data.issue.branchName // empty'
}
q_viewer() { # the Linear user behind the key
  gql_read Viewer 'query Viewer { viewer { id name } }' '{}' | jq -c '.data.viewer // error("no viewer")' 2>/dev/null || die "cannot read the Linear viewer"
}
q_blocks() { # q_blocks <ISSUE...> → {"<ISSUE>": [identifiers it blocks]}, one query (an aliased issue(id:) per issue)
  local q="" d="" v='{}' i=0 x
  for x in "$@"; do
    q="$q i$i: issue(id: \$i$i) { identifier relations(first: 50) { nodes { type relatedIssue { identifier } } } }"
    d="$d${d:+, }\$i$i: String!"; v="$(jq -c --arg k "i$i" --arg x "$x" '. + {($k): $x}' <<<"$v")"; i=$((i + 1))
  done
  gql_read Blocks "query Blocks($d) {$q }" "$v" | jq -c --argjson v "$v" '.data as $d | [$v | to_entries[] | {(.value):
    [($d[.key].relations.nodes // [])[] | select(.type == "blocks") | .relatedIssue.identifier // empty]}] | add // {}'
}

# ---- writes (mutations only) ---------------------------------------------------------------------
m_label_create() { # m_label_create <name> <description> <parent id | ""> → the new label's id (a workspace label, no team)
  clear_write IssueLabelCreate "$1"
  gql_write IssueLabelCreate 'mutation IssueLabelCreate($input: IssueLabelCreateInput!) { issueLabelCreate(input: $input) { success issueLabel { id } } }' \
    "$(jq -nc --arg n "$1" --arg d "$2" --arg p "$3" \
      '{input: ({name: $n, description: $d} + (if $p != "" then {parentId: $p} else {} end))}')" |
    jq -r '.data.issueLabelCreate.issueLabel.id // empty'
}
m_label_describe() { # m_label_describe <label id> <description>
  clear_write IssueLabelUpdate "$1"
  gql_write IssueLabelUpdate 'mutation IssueLabelUpdate($id: String!, $input: IssueLabelUpdateInput!) { issueLabelUpdate(id: $id, input: $input) { success } }' \
    "$(jq -nc --arg id "$1" --arg d "$2" '{id: $id, input: {description: $d}}')" >/dev/null
}
m_issue_update() { # m_issue_update <issue id> <label ids json array | ""> <state id | "">: an empty one is left as it is
  clear_write IssueUpdate "$1"
  gql_write IssueUpdate 'mutation IssueUpdate($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }' \
    "$(jq -nc --arg id "$1" --arg l "$2" --arg s "$3" '{id: $id, input: ((if $l != "" then {labelIds: ($l | fromjson)} else {} end) + (if $s != "" then {stateId: $s} else {} end))}')" >/dev/null
}
m_comment_create() { # m_comment_create <issue id> <body>
  clear_write CommentCreate "$1"
  gql_write CommentCreate 'mutation CommentCreate($input: CommentCreateInput!) { commentCreate(input: $input) { success } }' \
    "$(jq -nc --arg i "$1" --arg b "$2" '{input: {issueId: $i, body: $b}}')" >/dev/null
}
m_comment_delete() { # m_comment_delete <comment id> <issue id>
  clear_write CommentDelete "$2"
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
describe_with_summary() { # describe_with_summary <description> <summary JSON | "">: the description with its summary= line set (dropped for "")
  printf '%s\n' "$1" | awk -v sm="${2:+summary=$2}" '
    /^summary=/ { if (!d && sm != "") { print sm; d = 1 } ; next }
    NF { print }
    END { if (!d && sm != "") print sm }'
}
other_fleet_labels() { # other_fleet_labels <issue json> → names of fleet labels on it that are not ours
  local mine legacy; mine="$(machine_label)"; legacy="$(cfg_str machine_legacy_label '')"
  printf '%s' "$1" | jq -r --arg p "$(label_prefix)" --arg m "$mine" --arg l "$legacy" '.labels.nodes[] | select((.name | startswith($p)) and .name != $m and ($l == "" or .name != $l)) | .name'
}
say() { jq -nc "$@"; }

# legacy_ids_hashed <description>: the description with every full machine id (a UUID or 32 hex
# characters) replaced by sha256:<first 12 hex of its sha256>. Older versions published the full
# hardware id; the rest of the text, the heartbeat= line included, is kept as it was.
# Fails closed: when machine-id.sh hash fails or gives no 12 hex characters it prints nothing and returns 1, and
# the caller writes nothing (never `sha256:` with an empty hash).
legacy_ids_hashed() {
  local d="$1" id h re='([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})|([0-9A-Fa-f]{32})'
  while [[ "$d" =~ $re ]]; do
    id="${BASH_REMATCH[0]}"; h="$("$FLEET_SCRIPTS/machine-id.sh" hash "$id" 2>/dev/null)" || h=""
    [[ "$h" =~ ^[0-9a-f]{12}$ ]] || { printf 'fleet: cannot hash a machine id in the label description; not writing it\n' >&2; return 1; }
    d="${d/"$id"/sha256:$h}"
  done
  printf '%s' "$d"
}

# open_pr <ISSUE> <repo | ""> → the URL of an open same-repo PR for the issue; nothing when there is none. Returns 2
# when gh cannot answer. A PR counts when its branch is fleet/<slug>[-/...] (slug = the lowercase issue key) or the
# issue's Linear branch, or when its title or body names the issue key, whatever the branch (boot's
# fleet/<team>/<role>, say): a second, search-based `gh pr list`.
open_pr() {
  local issue="$1" repo="$2" slug b prs hit
  command -v "$FLEET_GH" >/dev/null 2>&1 || return 2
  b="$(q_issue_branch "$issue")"
  slug="fleet/$(printf '%s' "$issue" | tr '[:upper:]' '[:lower:]')"
  prs="$("$FLEET_GH" pr list --state open --limit 200 --json url,headRefName,isCrossRepository ${repo:+--repo "$repo"} 2>/dev/null)" || return 2
  hit="$(printf '%s' "$prs" | jq -r --arg s "$slug" --arg b "$b" '
    .[]? | select((.isCrossRepository // false) | not)
        | select(.headRefName == $s or (.headRefName | startswith($s + "-")) or (.headRefName | startswith($s + "/")) or ($b != "" and .headRefName == $b))
        | .url' | head -n 1)" || return 2
  if [ -z "$hit" ]; then
    prs="$("$FLEET_GH" pr list --state open --limit 200 --search "$issue in:title,body" --json number,url,headRefName,isCrossRepository ${repo:+--repo "$repo"} 2>/dev/null)" || return 2
    hit="$(printf '%s' "$prs" | jq -r '.[]? | select((.isCrossRepository // false) | not) | .url' | head -n 1)" || return 2
  fi
  printf '%s' "$hit"
}

# claim_lapsed <heartbeat ISO>: exit 0 when the heartbeat is older than lease_hours (the claim lapsed); exit 1 while
# the lease is live, claim.sh saying why on stderr, or when the heartbeat is not a time (never proven lapsed).
claim_lapsed() {
  local lease
  lease="$("$FLEET_SCRIPTS/claim.sh" lease --now "$1")" || return 1
  "$FLEET_SCRIPTS/claim.sh" expired --lease "$lease" --now "${FLEET_NOW:-$(now)}"
}

# lapsed_claim <ISSUE> <issue json> <repos | ""> <refusal>: prints "<holder label><TAB><heartbeat>" when another
# machine's claim on the issue may be taken from it: its heartbeat is older than lease_hours AND no PR is open for
# the issue in any of the space-separated OWNER/NAME repos (the cwd's repo when there are none; a PR waiting on a
# merge is not quiet). Otherwise it dies naming why, ending with <refusal> ("Not taking over"), before anything is
# written. takeover and release --lapsed share it; FLEET_FORCE never bypasses it.
lapsed_claim() {
  local issue="$1" iss="$2" repos="$3" no="$4" holder hb why pr="" rc=0 r
  holder="$(other_fleet_labels "$iss" | head -n 1)"
  [ -n "$holder" ] || die "$issue is not claimed by another machine. $no"
  hb="$(hb_of "$(q_labels_named "$holder" | jq -r '.[0].description // ""')")"
  [ -n "$hb" ] || die "$holder has no heartbeat; cannot show its claim lapsed. $no"
  why="$(claim_lapsed "$hb" 2>&1)" || die "$issue is claimed by $holder ($why). $no"
  for r in ${repos:-.}; do
    [ "$r" != . ] || r=""
    pr="$(open_pr "$issue" "$r")" || rc=$?
    [ "$rc" = 0 ] || die "cannot look up open PRs for $issue${r:+ in $r} (gh failed or is missing). $no"
    [ -z "$pr" ] || die "$issue has an open PR ($pr). $no while it is open"
  done
  printf '%s\t%s\n' "$holder" "$hb"
}

# guard_issue <ISSUE...>: in test mode, every issue must be in team $TEST_TEAM or nothing is written. The cleared
# issues' ids (and identifiers) go into ISSUES_OK, which clear_write checks per write.
guard_issue() {
  [ -n "$TEST_TEAM" ] || return 0
  local i k
  for i in "$@"; do
    k="$(q_issue_team_key "$i")"
    [ "$k" = "$TEST_TEAM" ] || die "test mode (linear_writes = test:$TEST_TEAM): $i is in team ${k:-unknown}; writes are allowed only on team $TEST_TEAM. Nothing was written"
  done
  for i in "$@"; do ISSUES_OK="$ISSUES_OK $i $(q_issue "$i" | jq -r .id)"; done
}

# viewer: {id, name} of the key's user, read once per tick (FLEET_TICK_ID, set by tick.sh) and cached.
viewer() {
  local f="$FLEET_STATE_DIR/viewer.cache.json" tid="${FLEET_TICK_ID:-}" v
  if [ -n "$tid" ] && [ -f "$f" ] && [ "$(jq -r '.tick // ""' "$f" 2>/dev/null)" = "$tid" ]; then jq -c '{id, name}' "$f"; return 0; fi
  v="$(q_viewer)" || return 1
  if [ -n "$tid" ]; then mkdir -p "$FLEET_STATE_DIR" 2>/dev/null && jq -nc --arg t "$tid" --argjson v "$v" '$v + {tick: $t}' >"$f" 2>/dev/null || true; fi
  printf '%s\n' "$v"
}
owner_name() { viewer 2>/dev/null | jq -r '.name // ""' 2>/dev/null || true; }
# describe_with_owner <description> <owner>: the description with its owner= line set (before the
# heartbeat= line when it is new); everything else is kept.
describe_with_owner() {
  if [ -z "$2" ]; then printf '%s\n' "$1"; return 0; fi
  printf '%s\n' "$1" | awk -v o="owner=$2" '
    /^owner=/ { if (!d) { print o; d = 1 } ; next }
    /^heartbeat=/ && !d { print o; d = 1 }
    NF { print }
    END { if (!d) print o }'
}

# ensure_label <dry>: prints our label id (creating the group and the label as needed).
# An empty description is filled; a non-empty one is never overwritten.
ensure_label() {
  local dry="$1" mine desc found lid gid grp now_iso cur new owner
  mine="$(machine_label)"; desc="$("$FLEET_SCRIPTS/machine-id.sh" description)" || return 1; now_iso="${FLEET_NOW:-$(now)}"
  owner="$(owner_name)"
  found="$(q_labels_named "$mine")" || return 1
  lid="$(printf '%s' "$found" | jq -r '.[0].id // empty')"
  if [ -n "$lid" ]; then
    OWN_LID="$lid"
    cur="$(printf '%s' "$found" | jq -r '.[0].description // ""')"
    if [ -z "$cur" ]; then
      if [ "$dry" = 1 ]; then say --arg l "$mine" '{would: "fill the empty description", label: $l}' >&2
      else m_label_describe "$lid" "$(describe_with_hb "$(describe_with_owner "$desc" "$owner")" "$now_iso")" || return 1; fi
    else
      new="$(legacy_ids_hashed "$cur")" || exit 1; new="$(describe_with_owner "$new" "$owner")"
      if [ "$new" != "$cur" ]; then
        if [ "$dry" = 1 ]; then say --arg l "$mine" '{would_rewrite: "hash the machine id and set the owner line", label: $l}' >&2
        else m_label_describe "$lid" "$new" || return 1; fi
      fi
    fi
    printf '%s\n' "$lid"; return 0
  fi
  gid="$(q_labels_named "$GROUP" | jq -r '[.[] | select(.parent == null)][0].id // empty')" || return 1 # workspace group first
  if [ "$dry" = 1 ]; then
    [ -n "$gid" ] || say --arg g "$GROUP" '{would: "create the group label", label: $g}' >&2
    say --arg l "$mine" '{would: "create the machine label", label: $l}' >&2
    printf 'dry-run-label\n'; return 0
  fi
  # ensure_label runs inside $( ), where set -e does not hold: every failure returns explicitly, so a refused or
  # failed group create never goes on to a label without its group.
  if [ -z "$gid" ]; then gid="$(m_label_create "$GROUP" "fleet machines" "")" || return 1; fi
  [ -n "$gid" ] || die "could not create the $GROUP label group"
  lid="$(m_label_create "$mine" "$(describe_with_hb "$(describe_with_owner "$desc" "$owner")" "$now_iso")" "$gid")" || return 1
  [ -n "$lid" ] || die "could not create the label $mine"
  OWN_LID="$lid"; printf '%s\n' "$lid"
}

# write_heartbeat: rewrite the heartbeat= line of this machine's label to now (one mutation, none when the line already
# says now). Sets HB_AT and returns 0; returns 2 when the machine has no label yet. Claim, takeover and heartbeat share it.
write_heartbeat() {
  local mine found lid cur sm
  mine="$(machine_label)"
  found="$(q_labels_named "$mine")" || return 1
  lid="$(printf '%s' "$found" | jq -r '.[0].id // empty')"
  [ -n "$lid" ] || return 2
  HB_AT="${FLEET_NOW:-$(now)}"; OWN_LID="$lid"
  # A description an older version wrote still holds the full machine id: hashed here too, or nothing is written.
  cur="$(legacy_ids_hashed "$(printf '%s' "$found" | jq -r '.[0].description // ""')")" || return 1
  # The summary line (fleet_summary) rides on the same write: one mutation, and none when neither line changed.
  sm="$(fleet_summary 2>/dev/null)" || sm=""; [ "$sm" != "[]" ] || sm=""
  if [ "$(printf '%s\n' "$cur" | sed -n 's/^heartbeat=//p' | head -n 1)" != "$HB_AT" ] ||
    [ "$(printf '%s\n' "$cur" | sed -n 's/^summary=//p' | head -n 1)" != "$sm" ]; then
    m_label_describe "$lid" "$(describe_with_summary "$(describe_with_hb "$(describe_with_owner "$cur" "$(owner_name)")" "$HB_AT")" "$sm")" || return 1
  fi
}

# ---- subcommands ---------------------------------------------------------------------------------
cmd="${1:-}"; [ $# -gt 0 ] && shift
# Every API subcommand needs the key; check it here, at the top level, so a missing key is exit 3
# and not an error swallowed inside a command substitution.
case "$cmd" in claim | heartbeat | holder | peers | blocks | whoami | takeover | release | state | migrate) load_key ;; esac
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
    hb=""; lapsed=null
    if [ -n "$label" ]; then hb="$(hb_of "$(q_labels_named "$label" | jq -r '.[0].description // ""')")"; fi
    if [ -n "$hb" ]; then if claim_lapsed "$hb" 2>/dev/null; then lapsed=true; else lapsed=false; fi; fi
    say --arg i "$issue" --arg h "$label" --arg m "$mine" --arg hb "$hb" --argjson l "$lapsed" \
      '{issue: $i, holder: (if $h == "" then null else $h end), ours: ($h == $m), heartbeat: (if $hb == "" then null else $hb end), lapsed: $l}' ;;

  blocks)
    READONLY=1
    [ $# -gt 0 ] || die "usage: blocks <ISSUE...>"
    for x in "$@"; do [[ "$x" =~ ^[A-Za-z][A-Za-z0-9]*-[0-9]+$ ]] || die "not an issue key: $x"; done
    q_blocks "$@" ;;

  whoami)
    READONLY=1
    viewer ;;

  peers)
    READONLY=1
    mine="$(machine_label)"
    q_open_issues_labelled "$(label_prefix)" startsWith | jq -c --arg p "$(label_prefix)" --arg m "$mine" --arg l "$(cfg_str machine_legacy_label '')" '
      [.[] | . as $i | .labels.nodes[] | select((.name | startswith($p)) and .name != $m and ($l == "" or .name != $l))
        | {machine: (.name | ltrimstr($p)), label: .name, issue: $i.identifier, heartbeat: ([(.description // "") | match("(^|\n)heartbeat=([^\n ]+)").captures[1].string] | first // null),
          summary: ([(.description // "") | match("(^|\n)summary=([^\n]*)").captures[1].string | fromjson? | select(type == "array")] | first // null)}]' ;;

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
    [ "$dry" = 1 ] || [ "$WMODE" != off ] || writes_off
    mine="$(machine_label)"
    iss="$(q_issue "$issue")"
    iid="$(printf '%s' "$iss" | jq -r .id)"; team="$(printf '%s' "$iss" | jq -r .team.id)"
    holder="$(other_fleet_labels "$iss" | head -n 1)"
    if [ -n "$holder" ]; then die "$issue is claimed by $holder; this machine is $mine. Not claiming"; fi
    [ "$dry" = 1 ] || guard_issue "$issue"
    lid="$(ensure_label "$dry")"
    # The label's heartbeat is refreshed before the label reaches the issue, or another machine's tick reads the old line.
    [ "$dry" = 1 ] || (write_heartbeat) || [ $? = 2 ] || warn "could not refresh the heartbeat of $mine"
    sid="$(q_state_id "$team" "In Progress")"
    keep="$(printf '%s' "$iss" | jq -c --arg p "$(label_prefix)" '[.labels.nodes[] | select(.name | startswith($p) | not) | .id]')"
    ids="$(jq -cn --argjson k "$keep" --arg l "$lid" '$k + [$l] | unique')"
    if [ "$dry" = 1 ]; then
      say --arg i "$issue" --argjson l "$ids" --arg s "$sid" '{would: "update the issue", issue: $i, labelIds: $l, stateId: $s}'
      exit 0
    fi
    m_issue_update "$iid" "$ids" "$sid"
    sleep "$(const_int CLAIM_SETTLE_SECS 5)"
    after="$(q_issue "$issue")"
    if printf '%s' "$after" | jq -e --arg m "$mine" 'any(.labels.nodes[]; .name == $m)' >/dev/null; then
      say --arg i "$issue" --arg m "$mine" '{claimed: true, issue: $i, label: $m}'
    else
      who="$(other_fleet_labels "$after" | head -n 1)"
      printf 'fleet: lost the claim on %s to %s\n' "$issue" "${who:-another machine}" >&2; exit 1
    fi ;;

  heartbeat)
    [ "$WMODE" != off ] || writes_off
    rc=0; write_heartbeat || rc=$?
    if [ "$rc" = 2 ]; then say '{heartbeat: false, reason: "no machine label yet; nothing claimed"}'; exit 0; fi
    [ "$rc" = 0 ] || exit "$rc"
    say --arg t "$HB_AT" '{heartbeat: true, at: $t}' ;;

  takeover)
    issue=""; repo=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="${2:?--repo needs OWNER/NAME}"; shift 2 ;;
        -*) die "unknown option: $1" ;;
        *) issue="$1"; shift ;;
      esac
    done
    [ -n "$issue" ] || die "usage: takeover <ISSUE> [--repo OWNER/NAME]"
    [ "$WMODE" != off ] || writes_off
    mine="$(machine_label)"
    iss="$(q_issue "$issue")"
    guard_issue "$issue"
    # A PR waiting on a merge is not "quiet": taking over would let the taker overwrite it.
    hold="$(lapsed_claim "$issue" "$iss" "$repo" "Not taking over")" || exit 1
    holder="${hold%%$'\t'*}"; hb="${hold#*$'\t'}"
    iid="$(printf '%s' "$iss" | jq -r .id)"; team="$(printf '%s' "$iss" | jq -r .team.id)"
    lid="$(ensure_label 0)"
    (write_heartbeat) || [ $? = 2 ] || warn "could not refresh the heartbeat of $mine"
    sid="$(q_state_id "$team" "In Progress")"
    keep="$(printf '%s' "$iss" | jq -c --arg p "$(label_prefix)" '[.labels.nodes[] | select(.name | startswith($p) | not) | .id]')"
    m_issue_update "$iid" "$(jq -cn --argjson k "$keep" --arg l "$lid" '$k + [$l] | unique')" "$sid"
    # Settle and re-read, as claim does: when two machines take over at once, the last writer's label stays.
    sleep "$(const_int CLAIM_SETTLE_SECS 5)"
    after="$(q_issue "$issue")"
    if ! printf '%s' "$after" | jq -e --arg m "$mine" 'any(.labels.nodes[]; .name == $m)' >/dev/null; then
      who="$(other_fleet_labels "$after" | head -n 1)"
      printf 'fleet: lost the takeover of %s to %s\n' "$issue" "${who:-another machine}" >&2; exit 1
    fi
    m_comment_create "$iid" "fleet: taken over from $holder (heartbeat $hb, no open PR)"
    say --arg i "$issue" --arg f "$holder" --arg m "$mine" --arg hb "$hb" '{taken_over: true, issue: $i, from: $f, by: $m, heartbeat: $hb}' ;;

  release)
    # One issue update that keeps every other label. Like claim it is not compare-and-swap: a label another machine
    # puts on the issue between the read and the update is dropped with ours.
    issue=""; lapsed=0; repo=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --lapsed) lapsed=1; shift ;;
        --repo) repo="${repo:+$repo }${2:?--repo needs OWNER/NAME}"; shift 2 ;;
        -*) die "unknown option: $1" ;;
        *) issue="$1"; shift ;;
      esac
    done
    [ -n "$issue" ] || die "usage: release <ISSUE> [--lapsed [--repo OWNER/NAME]...]"
    [ -z "$repo" ] || [ "$lapsed" = 1 ] || die "--repo goes with --lapsed (it is where the open PR is looked up)"
    [ "$WMODE" != off ] || writes_off
    iss="$(q_issue "$issue")"
    guard_issue "$issue"
    if [ "$lapsed" = 1 ]; then
      hold="$(lapsed_claim "$issue" "$iss" "$repo" "Not releasing")" || exit 1
      from="${hold%%$'\t'*}"; drop="$(jq -cn --arg l "$from" '[$l]')"
    else
      from=""; mine="$(machine_label)"; legacy="$(cfg_str machine_legacy_label '')"
      drop="$(printf '%s' "$iss" | jq -c --arg m "$mine" --arg l "$legacy" '[.labels.nodes[] | select(.name == $m or ($l != "" and .name == $l)) | .name]')"
      [ "$drop" != "[]" ] || die "$issue is not claimed by this machine ($mine). Not releasing"
    fi
    m_issue_update "$(printf '%s' "$iss" | jq -r .id)" \
      "$(printf '%s' "$iss" | jq -c --argjson d "$drop" '[.labels.nodes[] | select(.name as $n | $d | index($n) | not) | .id]')" ""
    say --arg i "$issue" --argjson d "$drop" --arg f "$from" '{released: true, issue: $i, labels: $d} + (if $f != "" then {from: $f} else {} end)' ;;

  state)
    issue="${1:-}"; want="${2:-}"
    [ -n "$issue" ] && [ -n "$want" ] && [ $# = 2 ] || die "usage: state <ISSUE> <Done|Verify|Todo>"
    case "$want" in Done | Verify | Todo) ;; *) die "state is Done, Verify or Todo, not '$want'" ;; esac
    [ "$WMODE" != off ] || writes_off
    iss="$(q_issue "$issue")"
    holder="$(other_fleet_labels "$iss" | head -n 1)"
    [ -z "$holder" ] || die "$issue is claimed by $holder; not changing its state"
    if [ "$(printf '%s' "$iss" | jq -r '.state.name // ""')" = "$want" ]; then
      say --arg i "$issue" --arg s "$want" '{issue: $i, state: $s, changed: false}'; exit 0
    fi
    guard_issue "$issue"
    sid="$(q_state_id "$(printf '%s' "$iss" | jq -r .team.id)" "$want")"
    [ -n "$sid" ] || die "the team of $issue has no workflow state named $want"
    m_issue_update "$(printf '%s' "$iss" | jq -r .id)" "" "$sid"
    say --arg i "$issue" --arg s "$want" '{issue: $i, state: $s, changed: true}' ;;

  migrate)
    dry=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --dry-run) dry=1; READONLY=1; shift ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [ "$dry" = 1 ] || [ "$WMODE" != off ] || writes_off
    mine="$(machine_label)"; key="$(machine_key)"
    victims="$(q_open_issues_labelled "$mine" eq | jq -c --arg k "$key" '
      [.[] | . as $i | .comments.nodes[]
        | select((.body | startswith("fleet-claim:")) and (([.body | split("\n")[0] | scan("machine=([^ ]+)")[0]] | first) == $k))
        | {id, issue: $i.identifier, iid: $i.id}]')"
    # An existing label that still holds a full machine id is rewritten to the hashed form.
    found="$(q_labels_named "$mine")"
    lid="$(printf '%s' "$found" | jq -r '.[0].id // empty')"; cur="$(printf '%s' "$found" | jq -r '.[0].description // ""')"
    OWN_LID="$lid"; new="$(legacy_ids_hashed "$cur")" || exit 1
    new="$(describe_with_owner "$new" "$(owner_name)")"; rewrite=false; { [ -n "$lid" ] && [ "$new" != "$cur" ]; } && rewrite=true
    if [ "$dry" = 1 ]; then say --argjson v "$victims" --argjson r "$rewrite" '{would_delete: $v, would_rewrite: $r}'; exit 0; fi
    # Test mode: every issue a comment would be deleted from must be in the test team, or nothing is written.
    # shellcheck disable=SC2046
    guard_issue $(printf '%s' "$victims" | jq -r '[.[].issue] | unique[]')
    while IFS=$'\t' read -r id iid; do [ -z "$id" ] || m_comment_delete "$id" "$iid"; done < <(printf '%s' "$victims" | jq -r '.[] | [.id, .iid] | @tsv')
    if $rewrite; then m_label_describe "$lid" "$new"; fi
    say --argjson v "$victims" --argjson r "$rewrite" '{deleted: ($v | length), rewrote_label: $r}' ;;

  *) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
