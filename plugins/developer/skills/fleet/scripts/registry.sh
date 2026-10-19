#!/usr/bin/env bash
# Fleet registry: one JSON file, one row per agent identity (<team>/<role>).
# Every agent in the fleet uses this CLI, so writes are serialised with a lock.
#
#   registry.sh add '<json object with at least .name>'   upsert a row
#   registry.sh set <name> key=value [key=value ...]      update fields
#   registry.sh append <name> key value                    add value to the row's list at key (no duplicates)
#   registry.sh get [--archived] <name>                    --archived also looks in fleet-archive.json
#   registry.sh list [--team T] [--live] [--problems]
#   registry.sh count-live                                 agents counted against max_agents
#   registry.sh done <name> --outcome O --summary TEXT     the done contract (+ notification)
#   registry.sh escalate <name> P0|P1|P2 TEXT              severity-routed escalation (+ notification + inbox line)
#   registry.sh escalations [--open] [--team T] [--not-retired]  every escalation, Done and Retired rows included unless --not-retired
#   registry.sh resolve <name> <id|at> [--note TEXT]       close one escalation (the Orchestrator does this; <id> is unique, <at> is the legacy form)
#   registry.sh note <name> discovered TEXT                file discovered work instead of fixing it
#   registry.sh retire <name|team> [--outcome O]           also closes the rows' open escalations ("closed at retire")
#   registry.sh signoff <name> <pr-url|N> <sha>            the tester's sign-off: records the PR and the exact SHA verified
#   registry.sh reassign <team> <issue>                    move a team to a new issue (next.sh): clears the old outcome, PR and sign-off
#   registry.sh unsynced                                   rows changed since the sink last mirrored them
#   registry.sh synced <name> [name ...]                   mark rows as mirrored
#   registry.sh env-claim <team> <max> <cluster> [busy-slots]  atomically take the lowest free port slot
#   registry.sh env-set <team> key=value ...               update a team environment
#   registry.sh env-get <team>
#   registry.sh env-release <team>                         mark the environment Down, freeing its slot
#   registry.sh archive                                    move Retired rows to fleet-archive.json (lessons written, no open escalation, ended archive_after_days ago)
#   registry.sh path
#
# Every path comes from FLEET_STATE_DIR (fleet.json, escalations.jsonl, worktrees/, fleet-archive.json); there
# is no FLEET_REGISTRY or FLEET_INBOX override. Agents (FLEET_ROLE set) are refused add, retire, archive,
# reassign, resolve and close-stale.
set -euo pipefail
. "$(dirname "$0")/common.sh"

mkdir -p "$(dirname "$FLEET_REGISTRY")"
[ -f "$FLEET_REGISTRY" ] || printf '{"agents":{}}\n' >"$FLEET_REGISTRY"

LOCK="$FLEET_REGISTRY.lock"
ARCHIVE="$FLEET_ARCHIVE"
lock() {
  local i=0
  until mkdir "$LOCK" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -gt 100 ] && die "registry locked: remove $LOCK if no fleet command is running"
    sleep 0.1
  done
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
}

# Apply a jq program to the registry atomically.
update() {
  lock
  local tmp; tmp="$(mktemp "$FLEET_REGISTRY.XXXXXX")"
  if jq "$@" "$FLEET_REGISTRY" >"$tmp" && jq -e '.agents | type == "object"' "$tmp" >/dev/null 2>&1; then
    # Schema: a write may not make a row malformed (name a string, escalations an array of
    # entries with severity P0/P1/P2, message and at, discovered an array). A row that was
    # already malformed on disk is tolerated, with a warning, so it cannot block every other
    # write; the escalate/resolve/retire paths repair it (norm).
    local bad stale
    bad="$(jq -nr --slurpfile o "$FLEET_REGISTRY" --slurpfile n "$tmp" "$ESC_DEFS"'($o[0].agents // {}) as $old
      | [$n[0].agents | to_entries[] | select((.value | row_ok | not) and (($old[.key]) == null or ($old[.key] | row_ok)))
        | .key] | join(", ")')"
    if [ -n "$bad" ]; then rm -f "$tmp"; die "registry write refused: would leave malformed row(s): $bad; $FLEET_REGISTRY left unchanged"; fi
    # A transcript path (new or changed) must be under Claude's projects directory.
    bad="$(jq -nr --slurpfile o "$FLEET_REGISTRY" --slurpfile n "$tmp" --arg pd "$(projects_dir)/" '($o[0].agents // {}) as $old
      | [$n[0].agents | to_entries[] | select((.value.transcript // "") != "" and (.value.transcript != ($old[.key].transcript // ""))
          and ((.value.transcript | tostring | startswith($pd)) | not)) | .key] | join(", ")')"
    if [ -n "$bad" ]; then rm -f "$tmp"; die "registry write refused: transcript of $bad is not under $(projects_dir)/; $FLEET_REGISTRY left unchanged"; fi
    stale="$(jq -r "$ESC_DEFS"'[.agents | to_entries[] | select(.value | row_ok | not) | .key] | join(", ")' "$tmp")"
    [ -z "$stale" ] || warn "malformed row(s) already in the registry: $stale (a repairing write: escalate, resolve or retire)"
    mv "$tmp" "$FLEET_REGISTRY"
  else
    rm -f "$tmp"; die "registry update failed; $FLEET_REGISTRY left unchanged"
  fi
}

exists() { jq -e --arg n "$1" '.agents[$n] != null' "$FLEET_REGISTRY" >/dev/null || die "no agent '$1' in the registry"; }

notify() {
  [ "${HERDR_ENV:-}" = "1" ] || [ -n "${FLEET_SESSION:-}" ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  local err
  if ! err="$(hd notification show "$1" --body "$2" --sound "${3:-done}" 2>&1 >/dev/null)"; then
    warn "notification failed: $1: $(printf '%s' "$err" | head -1)"
  fi
}

LIVE='(.status != "Done" and .status != "Retired")'
OPEN_ESC='([escs[] | select(.resolved_at == null)] | length > 0)'
# .escalation is derived from the open entries: the highest open severity, "" when none is open.
DERIVE="$ESC_DEFS"'def derive: ([escs[] | select(.resolved_at == null) | .severity]) as $o
  | .escalation = (if ($o | index("P0")) then "P0" elif ($o | index("P1")) then "P1" elif ($o | index("P2")) then "P2" else "" end);'
PROBLEM='(.status == "Stalled" or .status == "Zombie" or .status == "Needs input" or (.escalation // "") != "")'

cmd="${1:-}"; shift || true
# Agents (FLEET_ROLE set in their pane) can report on themselves (set, done, escalate, note, signoff for the
# tester) but cannot create, retire, archive, move or resolve: those are the Orchestrator's.
case "$cmd" in
  add | retire | archive | reassign | resolve | close-stale)
    [ -z "${FLEET_ROLE:-}" ] || die "$cmd is the Orchestrator's; an agent (FLEET_ROLE=$FLEET_ROLE) may not run it" ;;
esac
case "$cmd" in
  add)
    row="${1:?usage: add '<json>'}"
    printf '%s' "$row" | jq -e 'type == "object" and (.name | type == "string")' >/dev/null || die "add needs a JSON object with .name"
    update --argjson r "$row" --arg t "$(now)" \
      '(.agents[$r.name] // {started: $t, discovered: [], escalations: []}) as $o
       | .agents[$r.name] = (($o + $r + {updated_at: $t}) | .escalations = ($o.escalations | if type == "array" then . else [] end))'
    ;;
  set)
    name="${1:?usage: set <name> key=value ...}"; shift
    exists "$name"
    args=(--arg n "$name"); prog='.agents[$n]'
    i=0
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      case "$k" in escalation|escalations) die "cannot set $k: use 'resolve <name> <id|at>' to close an escalation" ;; esac
      # An agent (FLEET_ROLE set in its pane) may set only these keys of its row; the Orchestrator and the
      # scripts (FLEET_ROLE unset) may set any other, and the schema check still applies to the result.
      if [ -n "${FLEET_ROLE:-}" ]; then
        case "$k" in status | summary | nudged_at | branch | worktree) ;; *) die "cannot set $k from an agent: agents may set only status, summary, nudged_at, branch and worktree" ;; esac
      fi
      args+=(--arg "k$i" "$k" --arg "v$i" "$v"); prog="$prog | .[\$k$i] = \$v$i"; i=$((i + 1))
    done
    update "${args[@]}" --arg t "$(now)" ".agents[\$n] = ($prog | .updated_at = \$t)"
    ;;
  append)
    name="${1:?usage: append <name> key value}"; k="${2:?usage: append <name> key value}"; v="${3:?usage: append <name> key value}"
    exists "$name"
    update --arg n "$name" --arg k "$k" --arg v "$v" --arg t "$(now)" \
      '.agents[$n] |= ((.[$k] = ((((.[$k] // []) | if type == "array" then . else [.] end) + [$v]) | unique)) | .updated_at = $t)'
    ;;
  get)
    files=("$FLEET_REGISTRY")
    if [ "${1:-}" = "--archived" ]; then shift; [ ! -f "$ARCHIVE" ] || files+=("$ARCHIVE"); fi
    jq -e -n --arg n "${1:?usage: get [--archived] <name>}" '[inputs.agents[$n] | select(. != null)] | first // error("no such agent")' "${files[@]}"
    ;;
  list)
    team=""; filter="true"; archived=false
    if [ "${1:-}" = "--envs" ]; then jq '.envs // {}' "$FLEET_REGISTRY"; exit 0; fi
    while [ $# -gt 0 ]; do
      case "$1" in
        --team) team="$2"; shift 2 ;;
        --live) filter="$filter and $LIVE"; shift ;;
        --with-archived) archived=true; shift ;;
        --problems) filter="$filter and (($LIVE and $PROBLEM) or $OPEN_ESC)"; shift ;;
        *) die "unknown list option: $1" ;;
      esac
    done
    files=("$FLEET_REGISTRY"); $archived && [ -f "$ARCHIVE" ] && files+=("$ARCHIVE")
    jq -n --arg t "$team" "${ESC_DEFS}[inputs.agents[] | select((\$t == \"\" or .team == \$t) and $filter)]" "${files[@]}"
    ;;
  count-live)
    jq "[.agents[] | select($LIVE and .tier != \"Orchestrator\")] | length" "$FLEET_REGISTRY"
    ;;
  done)
    name="${1:?usage: done <name> --outcome O --summary TEXT}"; shift
    outcome="Shipped"; summary=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --outcome) outcome="$2"; shift 2 ;;
        --summary) summary="$2"; shift 2 ;;
        *) die "unknown done option: $1" ;;
      esac
    done
    exists "$name"
    update --arg n "$name" --arg o "$outcome" --arg s "$summary" --arg t "$(now)" \
      '.agents[$n] += {status: "Done", outcome: $o, summary: $s, done_at: $t, updated_at: $t}'
    notify "fleet: $name done" "$outcome${summary:+ — $summary}"
    ;;
  escalate)
    name="${1:?usage: escalate <name> P0|P1|P2 TEXT}"; sev="${2:?}"; msg="${3:?}"
    case "$sev" in P0|P1|P2) ;; *) die "severity must be P0, P1 or P2" ;; esac
    exists "$name"
    at="$(now)"
    update --arg n "$name" --arg s "$sev" --arg m "$msg" --arg t "$at" \
      "$DERIVE"'.agents[$n] |= (norm | .status = "Needs input"
        | .escalations += [{id: (($t | gsub("[-:]"; "")) + "-" + ((.escalations | length) + 1 | tostring)), severity: $s, message: $m, at: $t}]
        | derive | .updated_at = $t)'
    # update() holds the lock until this process exits, so the new entry is still the last one.
    id="$(jq -r --arg n "$name" '.agents[$n].escalations | last | .id' "$FLEET_REGISTRY")"
    # The inbox is what escalation-wait.sh delivers to the Orchestrator; the registry row stays the source of truth.
    line="$(jq -nc --arg at "$at" --arg id "$id" --arg n "$name" --arg tm "$(jq -r --arg n "$name" '.agents[$n].team // ""' "$FLEET_REGISTRY")" --arg s "$sev" --arg m "$msg" \
      '{at: $at, id: $id, name: $n, team: $tm, severity: $s, message: $m}')"
    { printf '%s\n' "$line" >>"$FLEET_INBOX"; } 2>/dev/null || warn "cannot write the escalation inbox $FLEET_INBOX"
    ev_log escalation_raised team="$(jq -r --arg n "$name" '.agents[$n].team // ""' "$FLEET_REGISTRY")" name="$name" detail="$sev $id"
    notify "fleet $sev: $name" "$msg" request
    ;;
  escalations)
    team=""; open=false; live=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --open) open=true; shift ;;
        --not-retired) live=true; shift ;;
        --team) team="$2"; shift 2 ;;
        *) die "unknown escalations option: $1" ;;
      esac
    done
    jq --arg t "$team" --argjson open "$open" --argjson live "$live" "$ESC_DEFS"'
      [.agents[] | select(($t == "" or .team == $t) and (($live | not) or .status != "Retired")) | . as $a | escs[]
        | select(($open | not) or .resolved_at == null)
        | {name: $a.name, team: $a.team, id, at, severity, message, resolved_at: (.resolved_at // null), resolution: (.resolution // null)}]
      | sort_by(.at)' "$FLEET_REGISTRY"
    ;;
  resolve)
    name="${1:?usage: resolve <name> <id|at> [--note TEXT]}"; ref="${2:?usage: resolve <name> <id|at> [--note TEXT]}"; shift 2
    note=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --note) note="${2:?--note needs text}"; shift 2 ;;
        *) die "unknown resolve option: $1" ;;
      esac
    done
    exists "$name"
    # An id matches first, then (legacy) an at. seq is the first open match's array position; 0 when none is open.
    seq="$(jq -r --arg n "$name" --arg a "$ref" "$ESC_DEFS"'.agents[$n] | [escs[]] as $e
      | ($e | map(select(.id == $a)) | if length > 0 then . else ($e | map(select(.at == $a))) end) as $m
      | if ($m | length) == 0 then "none" else ([$m[] | select(.resolved_at == null) | .seq] | first // 0) end' "$FLEET_REGISTRY")"
    [ "$seq" != "none" ] || die "no escalation '$ref' on $name (see: escalations --open)"
    [ "$seq" != "0" ] || { warn "escalation $name $ref is already resolved"; exit 0; }
    update --arg n "$name" --argjson i "$((seq - 1))" --arg note "$note" --arg t "$(now)" \
      "$DERIVE"'.agents[$n] |= (
        .escalations[$i] += {resolved_at: $t} + (if $note != "" then {resolution: $note} else {} end)
        | derive
        | if .escalation == "" and .status == "Needs input" then .status = "Working" else . end
        | .updated_at = $t)'
    ev_log escalation_resolved team="$(jq -r --arg n "$name" '.agents[$n].team // ""' "$FLEET_REGISTRY")" name="$name" detail="$ref"
    ;;
  note)
    name="${1:?usage: note <name> discovered TEXT}"; kind="${2:?}"; msg="${3:?}"
    [ "$kind" = "discovered" ] || die "only 'discovered' notes are supported"
    exists "$name"
    update --arg n "$name" --arg m "$msg" --arg t "$(now)" '.agents[$n] |= (.discovered += [{message: $m, at: $t}] | .updated_at = $t)'
    ;;
  retire)
    target="${1:?usage: retire <name|team> [--outcome O]}"; shift
    outcome=""
    [ "${1:-}" = "--outcome" ] && outcome="${2:-}"
    update --arg x "$target" --arg o "$outcome" --arg t "$(now)" "$DERIVE"'
      .agents |= with_entries(
        if (.key == $x or .value.team == $x) and .value.status != "Retired" then
          .value |= (norm | esc_close("closed at retire"; $t)
            | derive | .status = "Retired" | .ended = $t | .updated_at = $t
            | .outcome = (if .name == $x and $o != "" then $o else (.outcome // (if $o != "" then $o else "Abandoned" end)) end))
        else . end)'
    ;;
  archive)
    # Retired rows leave the live file once their lessons exist (debrief reads rows with an outcome
    # and no lessons, so those stay) and no escalation is open, archive_after_days after they ended.
    # The archive is written and verified first, then the rows are removed, so a failure between the
    # two leaves a row in both files and the next run finishes the move.
    lock
    days="$(archive_after_days)"
    moved="$(jq -c --argjson d "$days" --arg now "$(now)" "$ESC_DEFS"'
      [.agents | to_entries[] | select(.value.status == "Retired"
        and ((.value.lessons // "") != "")
        and ([.value | escs[] | select(.resolved_at == null)] | length == 0)
        and ((.value.ended // "") != "" and (($now | fromdateiso8601) - (.value.ended | fromdateiso8601)) >= ($d * 86400)))
        | .key]' "$FLEET_REGISTRY")"
    if [ "$moved" != "[]" ]; then
      [ -f "$ARCHIVE" ] || printf '{"agents":{}}\n' >"$ARCHIVE"
      tmp="$(mktemp "$ARCHIVE.XXXXXX")"
      jq --argjson names "$moved" --slurpfile live "$FLEET_REGISTRY" \
        '.agents += ($live[0].agents | with_entries(select(.key | IN($names[]))))' "$ARCHIVE" >"$tmp" &&
        jq -e --argjson names "$moved" '. as $a | $names | all(. as $n | $a.agents[$n] != null)' "$tmp" >/dev/null ||
        { rm -f "$tmp"; die "archive write failed; $FLEET_REGISTRY left unchanged"; }
      mv "$tmp" "$ARCHIVE"
      tmp="$(mktemp "$FLEET_REGISTRY.XXXXXX")"
      jq --argjson names "$moved" '.agents |= with_entries(select(.key | IN($names[]) | not))' "$FLEET_REGISTRY" >"$tmp" &&
        jq -e '.agents | type == "object"' "$tmp" >/dev/null || { rm -f "$tmp"; die "archive: live registry write failed; rows are in $ARCHIVE and still live"; }
      mv "$tmp" "$FLEET_REGISTRY"
    fi
    printf '%s\n' "$moved"
    ;;
  signoff)
    name="${1:?usage: signoff <name> <pr-url|N> <sha>}"; pr="${2:?usage: signoff <name> <pr-url|N> <sha>}"; sha="${3:?usage: signoff <name> <pr-url|N> <sha>}"
    exists "$name"
    # Only the tester signs off, and only for itself: an agent's FLEET_NAME must end in /tester and be the row
    # named. (FLEET_NAME and FLEET_ROLE are conventions an agent could set: this guards against mistakes,
    # not against an adversary.) The Orchestrator and scripts (FLEET_ROLE unset) may record a sign-off.
    if [ -n "${FLEET_ROLE:-}" ] && [ "${FLEET_ROLE:-}" != tester ]; then
      case "${FLEET_NAME:-}" in */tester) [ "${FLEET_NAME:-}" = "$name" ] || die "signoff: $name is not you (${FLEET_NAME:-unknown})" ;; *) die "signoff is the tester's: ${FLEET_NAME:-this agent} may not sign off" ;; esac
    fi
    printf '%s' "$sha" | grep -Eq '^[0-9a-fA-F]{7,40}$' || die "sha must be 7-40 hex characters: $sha"
    sha="$(printf '%s' "$sha" | tr 'A-F' 'a-f')"
    [ "$(jq -r --arg n "$name" '.agents[$n].status' "$FLEET_REGISTRY")" != "Retired" ] || die "$name is Retired; cannot sign off"
    case "$pr" in
      https://*/*) ;;
      *[!0-9]* | "") die "pr must be a full PR URL or a number: $pr" ;;
      *)
        # A bare number: the repo comes from the git remote of the row's worktree (or repo).
        dir="$(jq -r --arg n "$name" '.agents[$n] | (if (.worktree // "") != "" then .worktree else (.repo // "") end)' "$FLEET_REGISTRY")"
        remote="$(git -C "$dir" remote get-url origin 2>/dev/null)" || die "cannot read the origin remote of '$dir'; pass the full PR URL"
        slug="$(printf '%s' "$remote" | sed -E 's#^(git@|ssh://git@|https?://)([^/:]+)[:/](.+)$#\2/\3#; s#\.git$##')"
        case "$slug" in */*/*) ;; *) die "cannot make a PR URL from remote '$remote'; pass the full PR URL" ;; esac
        pr="https://$slug/pull/$pr" ;;
    esac
    update --arg n "$name" --arg pr "$pr" --arg sha "$sha" --arg t "$(now)" \
      '.agents[$n] += {pr: $pr, signoff: {pr: $pr, sha: $sha, at: $t}, updated_at: $t}'
    ev_log signoff team="$(jq -r --arg n "$name" '.agents[$n].team // ""' "$FLEET_REGISTRY")" name="$name" pr="$pr" sha="$sha"
    ;;
  reassign)
    team="${1:?usage: reassign <team> <issue>}"; issue="${2:?usage: reassign <team> <issue>}"
    jq -e --arg t "$team" '[.agents[] | select(.team == $t and .status != "Retired" and .tier != "Orchestrator")] | length > 0' "$FLEET_REGISTRY" >/dev/null ||
      die "no live rows for team '$team'"
    # One update for every row: a half-moved team would be worse than an unmoved one.
    update --arg t "$team" --arg i "$issue" --arg now "$(now)" "$DERIVE"'
      .agents |= with_entries(
        if .value.team == $t and .value.status != "Retired" and .value.tier != "Orchestrator" then
          .value |= (
            del(.outcome, .summary, .done_at, .signoff, .pr, .lessons)
            | norm | esc_close("closed at next"; $now)
            | derive | .issue = $i | .status = "Working" | .updated_at = $now)
        else . end)'
    ;;
  unsynced)
    jq '[.agents[] | select((.updated_at // "") > (.synced_at // ""))]' "$FLEET_REGISTRY"
    ;;
  synced)
    [ $# -gt 0 ] || die "usage: synced <name> [name ...]"
    names="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
    update --argjson ns "$names" '.agents |= with_entries(if (.key | IN($ns[])) then .value.synced_at = .value.updated_at else . end)'
    ;;
  env-claim)
    # A slot is held by an env in Creating, Up or Failed (Failed keeps it until `down`).
    # Ports: HTTP 8080+10n, HTTPS 8443+10n. Over the cap, or with every slot busy on the
    # host, the env is recorded Queued and nothing is allocated. Prints the env as JSON.
    team="${1:?usage: env-claim <team> <max> <cluster> [busy-slots]}"; max="${2:?}"; cluster="${3:?}"; busy="${4:-}"
    lock
    tmp="$(mktemp "$FLEET_REGISTRY.XXXXXX")"
    jq --arg t "$team" --argjson max "$max" --arg c "$cluster" --arg busy "$busy" --arg now "$(now)" '
      .envs //= {} |
      ([.envs | to_entries[] | select(.key != $t and (.value.state | IN("Creating", "Up", "Failed"))) | .value.slot]) as $used |
      ($busy | split(",") | map(select(. != "") | tonumber)) as $hostbusy |
      (.envs[$t] // {}) as $cur |
      (if ($cur.state | IN("Creating", "Up", "Failed")) then $cur.slot
       else ([range(0; $max)] | map(select(. as $n | ($used | index($n)) == null and ($hostbusy | index($n)) == null)) | first) end) as $slot |
      .envs[$t] = ($cur + {cluster: $c, updated_at: $now} +
        (if $slot == null then {state: "Queued", slot: null, http_port: null, https_port: null}
         else {state: "Creating", slot: $slot, http_port: (8080 + 10 * $slot), https_port: (8443 + 10 * $slot)} end))
    ' "$FLEET_REGISTRY" >"$tmp" && mv "$tmp" "$FLEET_REGISTRY" || { rm -f "$tmp"; die "env-claim failed"; }
    jq -c --arg t "$team" '.envs[$t]' "$FLEET_REGISTRY"
    ;;
  env-set)
    team="${1:?usage: env-set <team> key=value ...}"; shift
    args=(--arg t "$team" --arg now "$(now)"); prog='.envs //= {} | .envs[$t] //= {}'
    i=0
    for kv in "$@"; do
      args+=(--arg "k$i" "${kv%%=*}" --arg "v$i" "${kv#*=}"); prog="$prog | .envs[\$t][\$k$i] = \$v$i"; i=$((i + 1))
    done
    update "${args[@]}" "$prog | .envs[\$t].updated_at = \$now"
    ;;
  env-get)
    jq -e --arg t "${1:?usage: env-get <team>}" '.envs[$t] // error("no such env")' "$FLEET_REGISTRY"
    ;;
  env-release)
    team="${1:?usage: env-release <team>}"
    update --arg t "$team" --arg now "$(now)" \
      'if .envs[$t] then .envs[$t] |= (.state = "Down" | .slot = null | .http_port = null | .https_port = null | .updated_at = $now) else . end'
    ;;
  path) printf '%s\n' "$FLEET_REGISTRY" ;;
  *) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
