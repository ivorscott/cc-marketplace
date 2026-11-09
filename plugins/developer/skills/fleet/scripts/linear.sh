#!/usr/bin/env bash
# Claims and heartbeat on the Linear API. A claim is this machine's label (fleet:<key>) on the
# issue; the machine's liveness is one `heartbeat=<ISO>` line in that label's description. No
# claim, lease or heartbeat comment is ever posted: the only comment this script can post is the
# single note a takeover leaves.
#
#   linear.sh claim <ISSUE> [--dry-run]       label the issue with this machine's label, set In Progress; exit 1 when the
#                                             claim was lost, 4 when it stood down to an earlier claim (nothing to start)
#   linear.sh heartbeat                       rewrite the heartbeat line of this machine's label (ONE mutation)
#   linear.sh holds <ISSUE>                   exit 0 only when this machine's label is on the issue and no other fleet label is
#                                             (one read); else exit 1 saying who holds it. boot's gate
#   linear.sh holder <ISSUE>                  JSON: who holds the issue, their last heartbeat and whether it lapsed
#                                             (`lapsed`: older than lease_hours, takeover's own check; null without a
#                                             heartbeat)   (read-only)
#   linear.sh peers                           JSON: other machines' claims {machine, label, name, issue, heartbeat, summary, source}, for
#                                             `fleet status` (summary: the machine's summary document, else the parsed `summary=`
#                                             label line, null when there is neither; source: doc | label)   (read-only; one extra read)
#   linear.sh candidates [--detail]           JSON: identifiers of the open issues a team could take now: Todo or Backlog, or In
#                                             Progress with no fleet label or only lapsed ones, not blocked by an open issue,
#                                             in a tracker_teams team and with a role label (unless candidates_allow_unlabelled);
#                                             one Linear read (the query is UNVERIFIED against the real API). --detail: JSON
#                                             {bootable: [{id, priority, title, reason}], skipped: [{id, reason}]}   (read-only)
#   linear.sh find-text <text>                the identifier of an issue whose title or description holds the text (exit 1 when
#                                             none); the morning report's check for a deferred item filed by hand   (read-only)
#   linear.sh blocks <ISSUE...>               JSON: {"<ISSUE>": [issues it blocks]} from Linear's `blocks` relations,
#                                             one query for all of them   (read-only)
#   linear.sh takeover <ISSUE> [--repo OWNER/NAME]   take an issue over from a lapsed holder; refuses while an
#                                             open PR exists for the issue (see Takeover below)
#   linear.sh release <ISSUE> [--lapsed [--repo OWNER/NAME]]   remove this machine's label (and its legacy label) from
#                                             the issue, keeping the rest; refuses an issue this machine does not hold.
#                                             --lapsed removes another machine's label instead, only with takeover's
#                                             guards (heartbeat older than lease_hours, no open PR); nothing is posted.
#                                             --repo may repeat: the open PR is looked up in every one given (tick's
#                                             sweep passes the fleet's repos), else in the cwd's repo; it is also
#                                             found from the issue itself (PR attachments, branch, search by owner),
#                                             so a PR in a repo no one listed still holds the claim
#   linear.sh state <ISSUE> <Done|Verify|Todo>   move the issue to that workflow state, labels untouched; refuses an
#                                             issue another machine holds
#   linear.sh create-issue <FROM-ISSUE> <title> <description> [--link URL]   create an issue in FROM-ISSUE's team, link the URL
#                                             (a PR) to it, and print {identifier, url} (a write; the mutations are UNVERIFIED
#                                             against the real API); in test mode only when FROM-ISSUE is in the test team
#   linear.sh comments <ISSUE>                JSON: the issue's comments, oldest first, [{id, at, user, body}]   (read-only; the query is UNVERIFIED against the real API)
#   linear.sh verify-list                     JSON: the issues in Verify, each {issue, title, url, age_days, check, expiry}: age is
#                                             days since the issue last changed, check the UNVERIFIED line(s) a row's done
#                                             summary held (live or archived registry; "see the issue" when none), expiry
#                                             fresh (7 days or less), ask (older, never asked) or close (older, asked
#                                             by an earlier report)   (read-only; the query is UNVERIFIED against the real API)
#   linear.sh verify-sweep                    the same list, then the expiry applied: an `ask` item is remembered as asked
#                                             (verify.asked.json in the state dir), a `close` item moves to Done with a
#                                             comment saying why (a write); items no longer in Verify are forgotten
#   linear.sh comment <ISSUE> <text>          post one comment on the issue (a write)
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
# label create or description update only of this machine's own fleet:<key> label, and a summary document create or update only of
# this machine's own "Fleet summary · <key>" document. Nothing else is
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
# Two machines claiming at once: the claim time rides on the machine label (a claimed=<ISSUE>@<ISO> line written with the
# heartbeat). If both labels end up on the issue, the earlier claim wins, then the lowest label name; the loser removes
# its own label and exits 4 ("stood down") before any agent starts.
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
    IssueUpdate | CommentCreate | CommentDelete | IssueCreate | AttachmentCreate) case " $ISSUES_OK " in *" $2 "*) return 0 ;; esac ;;
    IssueLabelUpdate) [ -z "$OWN_LID" ] || [ "$2" != "$OWN_LID" ] || return 0 ;;
    IssueLabelCreate) [ "$2" != "$(machine_label)" ] || return 0 ;;
    DocumentCreate | DocumentUpdate) [ "$2" != "$DOC_PREFIX$(machine_key)" ] || return 0 ;;
  esac
  die "test mode (linear_writes = test:$TEST_TEAM): $1 on $2 is outside team $TEST_TEAM and this machine's own label and summary document. Nothing was written"
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

q_candidates() { # q_candidates → open issues with their state, fleet labels and the open issues that block them (UNVERIFIED query)
  gql_read Candidates 'query Candidates { issues(first: 100, filter: { state: { type: { in: ["backlog", "unstarted", "started"] } } }) { nodes { identifier title priority team { key } state { name type } relations(first: 20) { nodes { type } } labels { nodes { name description } } inverseRelations(first: 20) { nodes { type issue { identifier state { type } } } } } } }' '{}' |
    jq -c '.data.issues.nodes // error("no issues")'
}
q_find_text() { # q_find_text <text> → the identifier of an issue whose title or description holds the text, empty when none (UNVERIFIED query)
  gql_read FindText 'query FindText($t: String!) { issues(first: 1, filter: { or: [{ title: { containsIgnoreCase: $t } }, { description: { containsIgnoreCase: $t } }] }) { nodes { identifier } } }' \
    "$(jq -nc --arg t "$1" '{t: $t}')" | jq -r '.data.issues.nodes[0].identifier // empty'
}
q_verify_items() { # q_verify_items → the issues in the Verify state with title, url and last change (UNVERIFIED query)
  gql_read VerifyItems 'query VerifyItems { issues(first: 100, filter: { state: { name: { eq: "Verify" } } }) { nodes { identifier title url updatedAt } } }' '{}' |
    jq -c '.data.issues.nodes // error("no issues")'
}
q_comments() { # q_comments <ISSUE> → the issue's comments, oldest first (UNVERIFIED query)
  gql_read IssueComments 'query IssueComments($id: String!) { issue(id: $id) { comments(first: 100) { nodes { id createdAt body user { name } } } } }' \
    "$(jq -nc --arg id "$1" '{id: $id}')" | jq -c '[(.data.issue.comments.nodes // [])[] | {id, at: .createdAt, user: (.user.name // ""), body: (.body // "")}] | sort_by(.at)'
}
q_issue_team_key() { # q_issue_team_key <ISSUE> → the team key of the issue, empty when unknown
  gql_read IssueTeamKey 'query IssueTeamKey($id: String!) { issue(id: $id) { identifier team { key } } }' \
    "$(jq -nc --arg id "$1" '{id: $id}')" | jq -r '.data.issue.team.key // empty'
}
q_issue_branch() { # q_issue_branch <ISSUE> → Linear's suggested git branch for the issue, empty when unknown
  gql_read IssueBranch 'query IssueBranch($id: String!) { issue(id: $id) { identifier branchName } }' \
    "$(jq -nc --arg id "$1" '{id: $id}')" | jq -r '.data.issue.branchName // empty'
}
q_issue_sources() { # q_issue_sources <ISSUE> → {branch, urls[]}: the issue's suggested branch and its GitHub PR attachments
  gql_read IssueSources 'query IssueSources($id: String!) { issue(id: $id) { identifier branchName attachments { nodes { url } } } }' \
    "$(jq -nc --arg id "$1" '{id: $id}')" | jq -c '.data.issue // error("no such issue") | {branch: (.branchName // ""),
      urls: [(.attachments.nodes // [])[] | (.url // "") | capture("^(?<u>https://github\\.com/[^/]+/[^/]+/pull/[0-9]+)") | .u] | unique}' 2>/dev/null
}
DOC_PREFIX="Fleet summary · "
q_summary_docs() { # q_summary_docs → [{id, title, content, updatedAt}]: every machine's summary document, one read (UNVERIFIED filter syntax)
  gql_read SummaryDocs 'query SummaryDocs($p: String!) { documents(first: 50, filter: { title: { startsWith: $p } }) { nodes { id title content updatedAt } } }' \
    "$(jq -nc --arg p "$DOC_PREFIX" '{p: $p}')" | jq -c '.data.documents.nodes // []'
}
q_team_id() { # q_team_id → the id of the team a summary document is created under: the test team, else the first tracker_teams key, else the first team (UNVERIFIED)
  local k="${TEST_TEAM:-$(config_list tracker_teams | jq -r '.[0] // ""')}"
  gql_read TeamId 'query TeamId($k: String) { teams(first: 1, filter: { key: { eq: $k } }) { nodes { id } } }' "$(jq -nc --arg k "$k" '{k: $k}')" |
    jq -r '.data.teams.nodes[0].id // empty'
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
m_doc_create() { # m_doc_create <title> <content> <team id> → the new document's id (UNVERIFIED: the parent requirement)
  clear_write DocumentCreate "$1"
  gql_write DocumentCreate 'mutation DocumentCreate($input: DocumentCreateInput!) { documentCreate(input: $input) { success document { id } } }' \
    "$(jq -nc --arg t "$1" --arg c "$2" --arg team "$3" '{input: {title: $t, content: $c, teamId: $team}}')" | jq -r '.data.documentCreate.document.id // empty'
}
m_doc_update() { # m_doc_update <document id> <title> <content>: title is the guard's name for it
  clear_write DocumentUpdate "$2"
  gql_write DocumentUpdate 'mutation DocumentUpdate($id: String!, $input: DocumentUpdateInput!) { documentUpdate(id: $id, input: $input) { success } }' \
    "$(jq -nc --arg id "$1" --arg c "$3" '{id: $id, input: {content: $c}}')" >/dev/null
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
m_issue_create() { # m_issue_create <source issue id> <team id> <title> <description> → the new issue as {id, identifier, url}
  clear_write IssueCreate "$1"
  gql_write IssueCreate 'mutation IssueCreate($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier url } } }' \
    "$(jq -nc --arg t "$2" --arg ti "$3" --arg d "$4" '{input: {teamId: $t, title: $ti, description: $d}}')" |
    jq -c '.data.issueCreate.issue // error("no issue created")'
}
m_attachment_create() { # m_attachment_create <issue id> <title> <url>
  clear_write AttachmentCreate "$1"
  gql_write AttachmentCreate 'mutation AttachmentCreate($input: AttachmentCreateInput!) { attachmentCreate(input: $input) { success } }' \
    "$(jq -nc --arg i "$1" --arg ti "$2" --arg u "$3" '{input: {issueId: $i, title: $ti, url: $u}}')" >/dev/null
}
m_comment_delete() { # m_comment_delete <comment id> <issue id>
  clear_write CommentDelete "$2"
  gql_write CommentDelete 'mutation CommentDelete($id: String!) { commentDelete(id: $id) { success } }' \
    "$(jq -nc --arg id "$1" '{id: $id}')" >/dev/null
}

# ---- helpers (no API calls) ----------------------------------------------------------------------
hb_of() { printf '%s\n' "$1" | "$FLEET_SCRIPTS/claim.sh" hb; }
describe_with_hb() { # describe_with_hb <description> <ISO>: the description with its heartbeat line set
  # The value goes in through the environment, not awk -v: -v processes backslash escapes, which corrupts free text.
  printf '%s\n' "$1" | FLEET_AWK_V="heartbeat=$2" awk 'BEGIN { hb = ENVIRON["FLEET_AWK_V"] }
    /^heartbeat=/ { if (!d) { print hb; d = 1 } ; next }
    NF { print }
    END { if (!d) print hb }'
}
describe_with_claim() { # describe_with_claim <description> <claimed=ISSUE@ISO | "">: the description with its claimed= line set
  [ -n "$2" ] || { printf '%s\n' "$1"; return 0; }
  printf '%s\n' "$1" | FLEET_AWK_V="$2" awk 'BEGIN { c = ENVIRON["FLEET_AWK_V"] }
    /^claimed=/ { if (!d) { print c; d = 1 } ; next }
    NF { print }
    END { if (!d) print c }'
}
describe_with_summary() { # describe_with_summary <description> <summary JSON | "">: the description with its summary= line set (dropped for "")
  printf '%s\n' "$1" | FLEET_AWK_V="${2:+summary=$2}" awk 'BEGIN { sm = ENVIRON["FLEET_AWK_V"] }
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
# when gh cannot answer. A PR counts when its branch is fleet/<slug>[-/...] (slug = the lowercase issue key; boot's fleet/<key>-<machine key>-... too) or the
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

# issue_prs <ISSUE> <repos | ""> → the URL of an open same-repo PR for the issue, found from the issue itself rather
# than a repo list; nothing when there is none. Returns 2 when a lookup fails (gh missing or erroring, Linear
# unreadable) and 3 when there is nothing to look in. In order: a) the issue's GitHub PR attachments (`gh pr view`
# each: OPEN and not cross-repo); b) the PRs whose head is the issue's branch as fleet/<slug> (Linear's branch
# without its user prefix; an exact head, so boot's machine-specific branches are found by c), kept when the title or body names the issue key; c) `gh search prs <KEY>` per owner
# (the owners of <repos>, of the attachment URLs and of config `repo_owners`).
issue_prs() {
  local issue="$1" repos="$2" src b urls u o owners="" slug js hit r keyre
  command -v "$FLEET_GH" >/dev/null 2>&1 || return 2
  src="$(q_issue_sources "$issue")" || return 2
  b="$(printf '%s' "$src" | jq -r .branch)"; urls="$(printf '%s' "$src" | jq -r '.urls[]')"
  for r in $repos; do owners="$owners ${r%%/*}"; done
  for o in $(config_list repo_owners | jq -r '.[]'); do owners="$owners $o"; done
  for u in $urls; do o="${u#https://github.com/}"; owners="$owners ${o%%/*}"; done
  owners="$(printf '%s\n' $owners | sort -u | paste -sd' ' -)"
  [ -n "$urls" ] || [ -n "$b" ] || [ -n "$owners" ] || return 3
  keyre="(^|[^A-Za-z0-9-])$issue([^0-9]|\$)"
  for u in $urls; do
    js="$("$FLEET_GH" pr view "$u" --json url,state,isCrossRepository 2>/dev/null)" || return 2
    hit="$(printf '%s' "$js" | jq -r 'select(.state == "OPEN" and ((.isCrossRepository // false) | not)) | .url')" || return 2
    [ -z "$hit" ] || { printf '%s' "$hit"; return 0; }
  done
  if [ -n "$b" ]; then
    slug="fleet/${b#*/}"
    js="$("$FLEET_GH" search prs --head "$slug" --state open --limit 50 --json url,title,body 2>/dev/null)" || return 2
    hit="$(printf '%s' "$js" | jq -r --arg k "$keyre" '[.[]? | select(((.title // "") + " " + (.body // "")) | test($k))][0].url // empty')" || return 2
    [ -z "$hit" ] || { printf '%s' "$hit"; return 0; }
  fi
  for o in $owners; do
    js="$("$FLEET_GH" search prs "$issue" --owner "$o" --match title,body --state open --limit 50 --json url,title,body 2>/dev/null)" || return 2
    hit="$(printf '%s' "$js" | jq -r --arg k "$keyre" '[.[]? | select(((.title // "") + " " + (.body // "")) | test($k))][0].url // empty')" || return 2
    [ -z "$hit" ] || { printf '%s' "$hit"; return 0; }
  done
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
# the issue in any of the space-separated OWNER/NAME repos (the cwd's repo when there are none) and none is found
# from the issue itself (issue_prs: its PR attachments, its branch, a search by owner), even in a repo this machine
# has no team in; a PR waiting on a merge is not quiet. Otherwise it dies naming why, ending with <refusal> ("Not taking over"), before anything is
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
  rc=0; pr="$(issue_prs "$issue" "$repos")" || rc=$?
  [ "$rc" = 0 ] || die "cannot look up open PRs for $issue (gh failed or is missing, or there is no attachment, branch or owner to look in). $no"
  [ -z "$pr" ] || die "$issue has an open PR ($pr). $no while it is open"
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
  printf '%s\n' "$1" | FLEET_AWK_V="owner=$2" awk 'BEGIN { o = ENVIRON["FLEET_AWK_V"] }
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

# write_summary_doc <summary JSON>: this machine's summary document = a `name=` line and the summary in a fenced block, no
# size limit. Written only when its hash differs from the last one written ($FLEET_STATE_DIR/summary.doc.sha); with no hash
# kept the document is read once and compared. Returns 1 when the write failed (the caller warns).
write_summary_doc() {
  local content title sha hf="$FLEET_STATE_DIR/summary.doc.sha" docs id tid
  title="$DOC_PREFIX$(machine_key)"
  content="$(printf 'name=%s\n```json\n%s\n```\n' "$("$FLEET_SCRIPTS/machine-id.sh" name 2>/dev/null || machine_key)" "$1")"
  sha="$(printf '%s' "$content" | cksum | tr ' ' '-')"
  [ "$(cat "$hf" 2>/dev/null || true)" != "$sha" ] || return 0
  docs="$( (q_summary_docs) 2>/dev/null)" || return 1
  id="$(jq -r --arg t "$title" --arg c "$content" '[.[] | select(.title == $t)][0] | if . == null then "" elif (.content // "") == $c then "same" else .id end' <<<"$docs")"
  if [ "$id" = same ]; then :
  elif [ -n "$id" ]; then (m_doc_update "$id" "$title" "$content") || return 1
  else
    [ "$1" != "[]" ] || return 0 # nothing to publish and nothing published
    tid="$( (q_team_id) 2>/dev/null)" || return 1; [ -n "$tid" ] || return 1
    (m_doc_create "$title" "$content" "$tid" >/dev/null) || return 1
  fi
  mkdir -p "$FLEET_STATE_DIR" 2>/dev/null && printf '%s\n' "$sha" >"$hf" 2>/dev/null || true
}

# write_heartbeat: rewrite the heartbeat= line of this machine's label to now (one mutation, none when the line already
# says now). Sets HB_AT and returns 0; returns 2 when the machine has no label yet. Claim, takeover and heartbeat share it.
write_heartbeat() {
  local mine found lid cur sm base room err full
  mine="$(machine_label)"
  found="$(q_labels_named "$mine")" || return 1
  lid="$(printf '%s' "$found" | jq -r '.[0].id // empty')"
  [ -n "$lid" ] || return 2
  HB_AT="${FLEET_NOW:-$(now)}"; OWN_LID="$lid"
  # A description an older version wrote still holds the full machine id: hashed here too, or nothing is written.
  cur="$(legacy_ids_hashed "$(printf '%s' "$found" | jq -r '.[0].description // ""')")" || return 1
  # The full summary (fleet_summary, no size limit) lives in this machine's summary document, rewritten only when it changed.
  # The label keeps a thin copy of it as `summary=` for one release, so a machine on an older plugin still reads rows; it
  # rides on the same single write as the heartbeat, fitted to what is left under DESC_CAP (whole teams dropped, never a cut
  # line). A summary that cannot be built, or a document that cannot be written, never stops the heartbeat.
  base="$(describe_with_summary "$(describe_with_claim "$(describe_with_hb "$(describe_with_owner "$cur" "$(owner_name)")" "$HB_AT")" "${CLAIM_LINE:-}")" "")"
  room=$((DESC_CAP - ${#base} - 4)); [ "$room" -gt 2 ] || room=2
  if full="$(fleet_summary 2>/dev/null)"; then
    write_summary_doc "$full" || warn "team summary document not written; peers fall back to the label line"
    sm="$(summary_for_label "$room" <<<"$full" 2>/dev/null)" || sm=""
    [ "$sm" != "[]" ] || sm=""
  else
    sm=""; warn "team summary not built; the heartbeat is written without it"
  fi
  if [ "$(printf '%s\n' "$cur" | sed -n 's/^heartbeat=//p' | head -n 1)" != "$HB_AT" ] ||
    { [ -n "${CLAIM_LINE:-}" ] && [ "$(printf '%s\n' "$cur" | sed -n 's/^claimed=//p' | head -n 1)" != "${CLAIM_LINE#claimed=}" ]; } ||
    [ "$(printf '%s\n' "$cur" | sed -n 's/^summary=//p' | head -n 1)" != "$sm" ]; then
    # Linear can refuse a long label description ("Argument Validation Error"). A refused write is tried again without the
    # summary, and says so on stderr: the heartbeat always lands, whatever the limit is.
    err="${TMPDIR:-/tmp}/fleet-hb.$$"
    if ! (m_label_describe "$lid" "$(describe_with_summary "$base" "$sm")") 2>"$err"; then
      if [ -n "$sm" ] && grep -q 'Argument Validation Error' "$err"; then
        rm -f "$err"
        warn "heartbeat written without the team summary: Linear refused the label description with it"
        (m_label_describe "$lid" "$base") || { warn "heartbeat not written: Linear refused the label description"; return 1; }
      else cat "$err" >&2; rm -f "$err"; warn "heartbeat not written: Linear refused the write"; return 1; fi
    fi
    rm -f "$err"
  fi
}

# ---- subcommands ---------------------------------------------------------------------------------
cmd="${1:-}"; [ $# -gt 0 ] && shift
# Every API subcommand needs the key; check it here, at the top level, so a missing key is exit 3
# and not an error swallowed inside a command substitution.
case "$cmd" in claim | heartbeat | holder | peers | candidates | find-text | blocks | whoami | takeover | release | state | migrate | verify-list | verify-sweep | comment | comments | create-issue) load_key ;; esac
case "$cmd" in
  has-key)
    has_key || no_key ;;

  holds)
    READONLY=1
    issue="${1:?usage: holds <ISSUE>}"
    iss="$(q_issue "$issue")"; mine="$(machine_label)"; legacy="$(cfg_str machine_legacy_label '')"
    other="$(other_fleet_labels "$iss" | head -n 1)"
    [ -z "$other" ] || die "$issue is claimed by $other; this machine is $mine. Not booting"
    printf '%s' "$iss" | jq -e --arg m "$mine" --arg l "$legacy" 'any(.labels.nodes[]; .name == $m or ($l != "" and .name == $l))' >/dev/null ||
      die "$issue has no claim by $mine; run fleet claim $issue first. Not booting"
    say --arg i "$issue" --arg m "$mine" '{holds: true, issue: $i, label: $m}' ;;

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
    docs="$(q_summary_docs 2>/dev/null)" || docs="[]"
    q_open_issues_labelled "$(label_prefix)" startsWith | jq -c --arg p "$(label_prefix)" --arg m "$mine" --arg l "$(cfg_str machine_legacy_label '')" --arg dp "$DOC_PREFIX" --argjson docs "$docs" '
      def doc($k): [$docs[] | select(.title == $dp + $k)][0] // null;
      def docsum($d): if $d == null then null else ([($d.content // "") | split("```json\n")[1]? | split("\n```")[0] | fromjson? | select(type == "array")] | first // null) end;
      [.[] | . as $i | .labels.nodes[] | select((.name | startswith($p)) and .name != $m and ($l == "" or .name != $l))
        | (.name | ltrimstr($p)) as $k | doc($k) as $d | docsum($d) as $ds
        | ([(.description // "") | match("(^|\n)summary=([^\n]*)").captures[1].string | fromjson? | select(type == "array")] | first // null) as $ls
        | {machine: $k, label: .name, issue: $i.identifier, heartbeat: ([(.description // "") | match("(^|\n)heartbeat=([^\n ]+)").captures[1].string] | first // null),
          summary: ($ds // $ls), source: (if $ds != null then "doc" elif $ls != null then "label" else null end)}
          + (([(.description // "") | split("\n")[] | select(contains(" · ")) | split(" · ")[0]] | first) as $ln
             | ([($d.content // "") | match("(^|\n)name=([^\n]*)").captures[1].string] | first) as $dn
             | ($dn // $ln) | if . then {name: .} else {} end)]' ;;

  candidates)
    READONLY=1
    detail=0; [ "${1:-}" != --detail ] || detail=1
    # The team keys this tracker work may come from: tracker_teams, else the keys of the issues on registry rows (live and
    # archived); none known means no team filter.
    tt="$(config_list tracker_teams)"
    if [ "$(jq length <<<"$tt")" = 0 ]; then
      tt="$("$FLEET_SCRIPTS/registry.sh" list --with-archived 2>/dev/null | jq -c '[.[] | (.issue // "") | select(test("^[A-Za-z][A-Za-z0-9]*-[0-9]+$")) | sub("-[0-9]+$"; "")] | unique' 2>/dev/null)" || tt="[]"
      [ -n "$tt" ] || tt="[]"
    fi
    q_candidates | jq -c --arg p "$(label_prefix)" --arg rp "$(cfg_str role_label_prefix 'role:')" --argjson unl "$(cfg_bool candidates_allow_unlabelled false)" \
      --argjson tt "$tt" --arg now "${FLEET_NOW:-$(now)}" --argjson lease "$(lease_hours)" --argjson detail "$detail" '
      def rsn:
        ([.labels.nodes[]? | select(.name | startswith($p))]) as $f
        | if .state.name == "Verify" then "verify"
          elif .state.name == "Done" or .state.type == "completed" then "done"
          elif .state.name == "Duplicate" or any(.relations.nodes[]?; .type == "duplicate") then "duplicate"
          elif .state.name == "Canceled" or .state.type == "canceled" then "canceled"
          elif (.state.name != "Todo" and .state.name != "Backlog" and .state.name != "In Progress") then "other-state"
          elif ($tt | length) > 0 and ((.team.key // (.identifier | sub("-[0-9]+$"; ""))) as $k | $tt | index($k) | not) then "other-team"
          elif ($unl | not) and ([.labels.nodes[]? | select(.name | startswith($rp))] | length) == 0 then "no-role"
          elif ([.inverseRelations.nodes[]? | select(.type == "blocks" and (.issue.state.type != "completed" and .issue.state.type != "canceled"))] | length) > 0 then "blocked"
          elif .state.name == "In Progress" and ($f | length) > 0
            and (any($f[]; ([(.description // "") | match("(^|\n)heartbeat=([^\n ]+)").captures[1].string] | first) as $hb
                | $hb != null and (($now | fromdateiso8601) - ($hb | fromdateiso8601)) <= ($lease * 3600))) then "claimed"
          elif .state.name == "In Progress" then "in-progress-lapsed"
          else "ready" end;
      [.[] | {id: .identifier, priority: (.priority // 0), title: (.title // ""), reason: rsn}] as $all
      | if $detail == 1 then
          {bootable: [$all[] | select(.reason == "ready" or .reason == "in-progress-lapsed")],
           skipped: [$all[] | select(.reason != "ready" and .reason != "in-progress-lapsed") | {id, reason}]}
        else [$all[] | select(.reason == "ready" or .reason == "in-progress-lapsed") | .id] end' ;;

  find-text)
    READONLY=1
    t="${1:?usage: find-text <text>}"; [ -n "${t// /}" ] || die "usage: find-text <text>"
    id="$(q_find_text "$t")"
    [ -n "$id" ] || exit 1
    printf '%s\n' "$id" ;;

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
    [ "$dry" = 1 ] || (CLAIM_LINE="claimed=$issue@${FLEET_NOW:-$(now)}"; write_heartbeat) || [ $? = 2 ] || warn "could not refresh the heartbeat of $mine"
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
      # Two machine labels on the issue (the group is single-select, but a write can still land beside another): the
      # earlier claim wins, then the lowest label name, so both sides reach the same answer. The loser takes its own label
      # off and stands down (exit 4) before any agent starts. Linear has no compare-and-set; this is a tie-break.
      rival="$(other_fleet_labels "$after" | LC_ALL=C sort | head -n 1)"
      if [ -n "$rival" ]; then
        mine_at="$(q_labels_named "$mine" | jq -r --arg i "$issue" '.[0].description // "" | capture("(^|\n)claimed=" + $i + "@(?<t>[^\n ]+)").t // "9999"' 2>/dev/null || echo 9999)"
        rival_at="$(q_labels_named "$rival" | jq -r --arg i "$issue" '.[0].description // "" | capture("(^|\n)claimed=" + $i + "@(?<t>[^\n ]+)").t // "9999"' 2>/dev/null || echo 9999)"
        if [ "$rival_at" \< "$mine_at" ] || { [ "$rival_at" = "$mine_at" ] && [ "$(printf '%s\n%s\n' "$mine" "$rival" | LC_ALL=C sort | head -n 1)" = "$rival" ]; }; then
          m_issue_update "$iid" "$(printf '%s' "$after" | jq -c --arg m "$mine" '[.labels.nodes[] | select(.name != $m) | .id]')" ""
          printf 'fleet: stood down on %s: %s claimed it first (%s before %s). No agent was started\n' "$issue" "$rival" "$rival_at" "$mine_at" >&2; exit 4
        fi
      fi
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

  verify-list | verify-sweep)
    [ "$cmd" = verify-sweep ] || READONLY=1
    [ "$cmd" = verify-list ] || [ "$WMODE" != off ] || writes_off
    asked="$FLEET_STATE_DIR/verify.asked.json"; [ -f "$asked" ] && jq -e 'type == "object"' "$asked" >/dev/null 2>&1 || echo '{}' >"$asked"
    checks="$("$FLEET_SCRIPTS/registry.sh" list --with-archived 2>/dev/null | jq -c '
      [.[] | select((.issue // "") != "" and ((.summary // "") | test("UNVERIFIED")))
        | {issue, lines: [(.summary | split("\n")[] | split("; ")[] | select(test("UNVERIFIED")))]}]
      | group_by(.issue) | map({key: .[0].issue, value: ([.[].lines[]] | unique | join("; "))}) | from_entries')" || checks='{}'
    [ -n "$checks" ] || checks='{}'
    items="$(q_verify_items | jq -c --arg now "${FLEET_NOW:-$(now)}" --slurpfile a "$asked" --argjson c "$checks" '
      [.[] | . as $i | ((($now | fromdateiso8601) - ($i.updatedAt | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)) / 86400 | floor) as $d
        | {issue: .identifier, title, url, age_days: $d, check: ($c[.identifier] // "see the issue"),
           expiry: (if $d <= 7 then "fresh" elif ($a[0][.identifier] // null) == null then "ask" else "close" end)}]')"
    if [ "$cmd" = verify-sweep ]; then
      now_iso="${FLEET_NOW:-$(now)}"; tmp="$asked.tmp"
      for iss in $(printf '%s' "$items" | jq -r '.[] | select(.expiry == "close") | .issue'); do
        guard_issue "$iss"; iobj="$(q_issue "$iss")"
        sid="$(q_state_id "$(printf '%s' "$iobj" | jq -r .team.id)" Done)"
        [ -n "$sid" ] || { warn "the team of $iss has no Done state"; continue; }
        m_issue_update "$(printf '%s' "$iobj" | jq -r .id)" "" "$sid"
        m_comment_create "$(printf '%s' "$iobj" | jq -r .id)" "Moved from Verify to Done: it was in Verify for more than 7 days, the morning report asked once whether it was still worth checking, and nobody answered before the next report."
      done
      jq -c --argjson it "$items" --arg t "$now_iso" '
        . as $a | ([$it[] | select(.expiry == "ask") | {key: .issue, value: $t}] | from_entries) as $new
        | ([$it[] | select(.expiry == "ask" or .expiry == "fresh") | .issue]) as $keep
        | ($a | with_entries(select(.key as $k | $keep | index($k)))) + $new' "$asked" >"$tmp" && mv "$tmp" "$asked"
    fi
    printf '%s\n' "$items" ;;

  create-issue)
    from="${1:-}"; title="${2:-}"; body="${3:-}"; link=""
    [ -n "$from" ] && [ -n "$title" ] && [ -n "$body" ] || die "usage: create-issue <FROM-ISSUE> <title> <description> [--link URL]"
    shift 3; while [ $# -gt 0 ]; do case "$1" in --link) link="${2:?--link needs a URL}"; shift 2 ;; *) die "unknown option: $1" ;; esac; done
    [ "$WMODE" != off ] || writes_off
    guard_issue "$from"; iss="$(q_issue "$from")"
    new="$(m_issue_create "$(printf '%s' "$iss" | jq -r .id)" "$(printf '%s' "$iss" | jq -r .team.id)" "$title" "$body${link:+

Linked: $link}")" || die "could not create the issue"
    ISSUES_OK="$ISSUES_OK $(printf '%s' "$new" | jq -r .id)"
    [ -z "$link" ] || m_attachment_create "$(printf '%s' "$new" | jq -r .id)" "Pull request" "$link"
    printf '%s' "$new" | jq -c '{identifier, url}' ;;

  comments)
    READONLY=1
    [ $# = 1 ] || die "usage: comments <ISSUE>"
    q_comments "$1" ;;

  comment)
    issue="${1:-}"; text="${2:-}"
    [ -n "$issue" ] && [ -n "$text" ] && [ $# = 2 ] || die "usage: comment <ISSUE> <text>"
    [ "$WMODE" != off ] || writes_off
    guard_issue "$issue"
    m_comment_create "$(q_issue "$issue" | jq -r .id)" "$text"
    say --arg i "$issue" '{commented: true, issue: $i}' ;;

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
