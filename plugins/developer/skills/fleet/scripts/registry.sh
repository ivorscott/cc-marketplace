#!/usr/bin/env bash
# Fleet registry: one JSON file, one row per agent identity (<team>/<role>).
# Every agent in the fleet uses this CLI, so writes are serialised with a lock.
#
#   registry.sh add '<json object with at least .name>'   upsert a row
#   registry.sh set <name> key=value [key=value ...]      update fields
#   registry.sh append <name> key value                    add value to the row's list at key (no duplicates; an agent: own row, transcripts only)
#   registry.sh get [--archived] <name>                    --archived also looks in fleet-archive.json
#   registry.sh list [--team T] [--live] [--parked] [--problems]
#   registry.sh count-live                                 live agents (Parked, Done and Retired rows are not live)
#   registry.sh done <name> --outcome O --summary TEXT     the done contract (+ notification)
#   registry.sh escalate <name> P0|P1|P2 TEXT              severity-routed escalation (+ notification + inbox line)
#   registry.sh escalations [--open] [--team T] [--not-retired]  every escalation, Done and Retired rows included unless --not-retired
#   registry.sh resolve <name> <id|at> [--note TEXT]       close one escalation (the Orchestrator does this; <id> is unique, <at> is the legacy form)
#   registry.sh note <name> discovered|decision|picked TEXT   discovered: work filed instead of done (the row's
#                                                          `discovered`); decision: the option an agent took on its own
#                                                          (overnight mode); picked: the search behind a boot (the
#                                                          Orchestrator, on the lead's row). The last two go to `notes`
#   registry.sh retire <name|team> [--outcome O]           also closes the rows' open escalations ("closed at retire")
#   registry.sh signoff <name> <pr-url|N> <sha>            the tester's sign-off: records the PR and the exact SHA verified
#   registry.sh reassign <team> <issue> [--assignment TEXT] [--issue-url URL]
#                                                          move a team to a new issue (next.sh): logs issue_done for the old one,
#                                                          clears the old outcome, PR and sign-off, rewrites the assignment;
#                                                          workers go Idle, the lead Working
#   registry.sh park <team> <reason>                       one write: every unfinished row of the team becomes Parked (park.sh, which also closes the panes)
#   registry.sh park-mark <team> <reason|->                 mark the team to park when its PR merges (reason park-after-merge or focus:<team>); - clears it
#   registry.sh unsynced                                   rows changed since the sink last mirrored them
#   registry.sh synced <name> [name ...]                   mark rows as mirrored
#   registry.sh env-claim <team> <max> <cluster> [busy-slots]  atomically take the lowest free port slot
#   registry.sh env-set <team> key=value ...               update a team environment
#   registry.sh env-get <team>
#   registry.sh env-release <team>                         mark the environment Down, freeing its slot
#   registry.sh archive                                    move Retired rows to fleet-archive.json (lessons written, no open escalation, ended archive_after_days ago)
#   registry.sh orchestrator here [--transcript PATH]   the Orchestrator registers its pane as the loop's wake target
#   registry.sh pref <key> [value]                         a fleet-wide choice (the top-level `prefs`): print it (nothing
#                                                          when unset), or set it
#   registry.sh path
#
# Every path comes from FLEET_STATE_DIR (fleet.json, escalations.jsonl, worktrees/, fleet-archive.json); there
# is no FLEET_REGISTRY or FLEET_INBOX override. Agents (FLEET_ROLE set) are refused add, retire, archive,
# reassign, resolve, close-stale, orchestrator and pref.
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
  # The trap frees the temp file (and the lock) even when jq or the schema check kills the script.
  trap "rm -f '$tmp'; rmdir '$LOCK' 2>/dev/null || true" EXIT
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
    # A transcript path (new or changed), and any new entry of `transcripts`, must be under Claude's projects directory.
    bad="$(jq -nr --slurpfile o "$FLEET_REGISTRY" --slurpfile n "$tmp" --arg pd "$(projects_dir)/" '($o[0].agents // {}) as $old
      | [$n[0].agents | to_entries[] | select(
          ((.value.transcript // "") != "" and (.value.transcript != ($old[.key].transcript // ""))
            and ((.value.transcript | tostring | startswith($pd)) | not))
          or ([(.value.transcripts // []) | if type == "array" then .[] else . end] - [($old[.key].transcripts // []) | if type == "array" then .[] else . end]
            | any(tostring | startswith($pd) | not))) | .key] | join(", ")')"
    if [ -n "$bad" ]; then rm -f "$tmp"; die "registry write refused: transcript of $bad is not under $(projects_dir)/; $FLEET_REGISTRY left unchanged"; fi
    stale="$(jq -r "$ESC_DEFS"'[.agents | to_entries[] | select(.value | row_ok | not) | .key] | join(", ")' "$tmp")"
    [ -z "$stale" ] || warn "malformed row(s) already in the registry: $stale (a repairing write: escalate, resolve or retire)"
    mv "$tmp" "$FLEET_REGISTRY"
  else
    rm -f "$tmp"; die "registry update failed; $FLEET_REGISTRY left unchanged"
  fi
}

exists() { jq -e --arg n "$1" '.agents[$n] != null' "$FLEET_REGISTRY" >/dev/null || die "no agent '$1' in the registry"; }

LIVE='(.status != "Done" and .status != "Retired" and .status != "Parked")'
OPEN_ESC='([escs[] | select(.resolved_at == null)] | length > 0)'
# .escalation is derived from the open entries: the highest open severity, "" when none is open.
DERIVE="$ESC_DEFS"'def derive: ([escs[] | select(.resolved_at == null) | .severity]) as $o
  | .escalation = (if ($o | index("P0")) then "P0" elif ($o | index("P1")) then "P1" elif ($o | index("P2")) then "P2" else "" end);'
PROBLEM='(.status == "Stalled" or .status == "Zombie" or .status == "Needs input" or (.escalation // "") != "")'

cmd="${1:-}"; shift || true
# Agents (FLEET_ROLE set in their pane) can report on themselves (set, done, escalate, note, signoff for the
# tester) but cannot create, retire, archive, move or resolve: those are the Orchestrator's.
case "$cmd" in
  add | retire | archive | reassign | resolve | close-stale | orchestrator | park | park-mark | pref)
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
        case "$k" in status | status_detail | summary | nudged_at | branch | worktree) ;; *) die "cannot set $k from an agent: agents may set only status, status_detail, summary, nudged_at, branch and worktree" ;; esac
      fi
      args+=(--arg "k$i" "$k" --arg "v$i" "$v"); prog="$prog | .[\$k$i] = \$v$i"; i=$((i + 1))
    done
    update "${args[@]}" --arg t "$(now)" ".agents[\$n] = ($prog | .updated_at = \$t)"
    ;;
  append)
    name="${1:?usage: append <name> key value}"; k="${2:?usage: append <name> key value}"; v="${3:?usage: append <name> key value}"
    exists "$name"
    # An agent (FLEET_ROLE set) may append only to its own row (FLEET_NAME), and only to `transcripts`.
    if [ -n "${FLEET_ROLE:-}" ]; then
      [ "$name" = "${FLEET_NAME:-}" ] || die "an agent may append only to its own row (FLEET_NAME=${FLEET_NAME:-unset}), not $name"
      case "$k" in transcripts) ;; *) die "cannot append to $k from an agent: agents may append only to transcripts" ;; esac
    fi
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
        --parked) filter="$filter and .status == \"Parked\""; shift ;;
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
    # The launchd job watches the inbox file, so a new line starts a tick; the registry row stays the source of truth.
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
    name="${1:?usage: note <name> discovered|decision|picked TEXT}"; kind="${2:?usage: note <name> discovered|decision|picked TEXT}"
    msg="${3:?usage: note <name> discovered|decision|picked TEXT}"
    case "$kind" in discovered | decision | picked) ;; *) die "a note is discovered, decision or picked, not '$kind'" ;; esac
    exists "$name"
    if [ "$kind" = discovered ]; then
      update --arg n "$name" --arg m "$msg" --arg t "$(now)" '.agents[$n] |= (.discovered += [{message: $m, at: $t}] | .updated_at = $t)'
    else
      update --arg n "$name" --arg k "$kind" --arg m "$msg" --arg t "$(now)" \
        '.agents[$n] |= (.notes = ((.notes // []) + [{kind: $k, message: $m, at: $t}]) | .updated_at = $t)'
    fi
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
    # named, in the agent's own team (FLEET_TEAM). No FLEET_ROLE value skips this check. (FLEET_NAME, FLEET_TEAM
    # and FLEET_ROLE are conventions an agent could set: this guards against mistakes, not against an
    # adversary.) The Orchestrator and scripts (FLEET_ROLE unset) may record a sign-off.
    if [ -n "${FLEET_ROLE:-}" ]; then
      case "${FLEET_NAME:-}" in
        */tester) [ "${FLEET_NAME:-}" = "$name" ] || die "signoff: $name is not you (${FLEET_NAME:-unknown})"
          [ -z "${FLEET_TEAM:-}" ] || [ "$(jq -r --arg n "$name" '.agents[$n].team' "$FLEET_REGISTRY")" = "${FLEET_TEAM:-}" ] || die "signoff: $name is not in your team (${FLEET_TEAM:-unknown})" ;;
        *) die "signoff is the tester's: ${FLEET_NAME:-this agent} may not sign off" ;;
      esac
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
    team="${1:?usage: reassign <team> <issue> [--assignment TEXT] [--issue-url URL]}"; issue="${2:?usage: reassign <team> <issue>}"; shift 2
    assignment=""; iurl=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --assignment) assignment="${2:?--assignment needs text}"; shift 2 ;;
        --issue-url) iurl="${2:?--issue-url needs a URL}"; shift 2 ;;
        *) die "unknown reassign option: $1" ;;
      esac
    done
    [ -n "$assignment" ] || assignment="$issue"
    jq -e --arg t "$team" '[.agents[] | select(.team == $t and .status != "Retired" and .tier != "Orchestrator")] | length > 0' "$FLEET_REGISTRY" >/dev/null ||
      die "no live rows for team '$team'"
    jq -e --arg t "$team" '[.agents[] | select(.team == $t and .status == "Parked")] | length == 0' "$FLEET_REGISTRY" >/dev/null ||
      die "team '$team' is parked; unpark it first"
    # The old issue's outcome, summary and lessons are written to the event log before the rows are cleared:
    # the debrief reads these events, not rows that no longer hold them.
    jq -c --arg t "$team" '.agents[] | select(.team == $t and .status != "Retired" and .tier != "Orchestrator"
        and ((.outcome // "") != "" or (.summary // "") != "" or (.lessons // "") != ""))
      | [.name, (.issue // ""), (.outcome // ""), (.summary // ""), (.lessons // ""), (.pr // "")]' "$FLEET_REGISTRY" |
      while IFS= read -r line; do
        ev_log issue_done team="$team" name="$(printf '%s' "$line" | jq -r '.[0]')" issue="$(printf '%s' "$line" | jq -r '.[1]')" \
          outcome="$(printf '%s' "$line" | jq -r '.[2]')" summary="$(printf '%s' "$line" | jq -r '.[3]')" lessons="$(printf '%s' "$line" | jq -r '.[4]')" \
          pr="$(printf '%s' "$line" | jq -r '.[5]')"
      done
    # One update for every row: a half-moved team would be worse than an unmoved one.
    update --arg t "$team" --arg i "$issue" --arg a "$assignment" --arg u "$iurl" --arg now "$(now)" "$DERIVE"'
      .agents |= with_entries(
        if .value.team == $t and .value.status != "Retired" and .value.tier != "Orchestrator" then
          .value |= (
            del(.outcome, .summary, .done_at, .signoff, .pr, .lessons, .nudged_at)
            | norm | esc_close("closed at next"; $now)
            | derive | .issue = $i | .assignment = $a
            | (if $u != "" then .issue_url = $u else del(.issue_url) end)
            | .status = (if .tier == "Lead" then "Working" else "Idle" end) | .updated_at = $now)
        else . end)'
    ;;
  park)
    team="${1:?usage: park <team> <reason>}"; reason="${2:?usage: park <team> <reason>}"
    jq -e --arg t "$team" '[.agents[] | select(.team == $t and .tier != "Orchestrator" and .status != "Retired")] | length > 0' "$FLEET_REGISTRY" >/dev/null ||
      die "no rows for team '$team'"
    # Inside the one write, so two parks (or a park and a tick) cannot both win.
    update --arg t "$team" --arg r "$reason" --arg now "$(now)" '
      if ([.agents[] | select(.team == $t and .status == "Parked")] | length) > 0 then error("team is already parked") else . end
      | .agents |= with_entries(
        if .value.team == $t and .value.tier != "Orchestrator" and (.value.status | IN("Done", "Retired") | not) then
          .value |= (.status = "Parked" | .parked_at = $now | .parked_reason = $r | del(.park_after_merge) | .updated_at = $now)
        else . end)'
    ;;
  park-mark)
    team="${1:?usage: park-mark <team> <reason|->}"; reason="${2:?usage: park-mark <team> <reason|->}"
    update --arg t "$team" --arg r "$reason" --arg now "$(now)" '
      .agents |= with_entries(
        if .value.team == $t and .value.tier != "Orchestrator" and .value.status != "Retired" then
          .value |= ((if $r == "-" then del(.park_after_merge) else .park_after_merge = $r end) | .updated_at = $now)
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
  orchestrator)
    # The Orchestrator registers its own pane as the loop's wake target, once per session. The row is
    # replaced whole, so an older session's pane and transcript never linger; only the standing goal
    # `target_teams` ("keep N teams running") carries over, so a new session or a compaction keeps it. `cwd` is
    # where the session runs: the morning report goes to its reports/.
    [ "${1:-}" = here ] || die "usage: orchestrator here [--transcript PATH]"; shift
    otr=""
    while [ $# -gt 0 ]; do
      case "$1" in --transcript) otr="${2:?--transcript needs a path}"; shift 2 ;; *) die "unknown option: $1" ;; esac
    done
    opane="${HERDR_PANE_ID:-}"
    [ -n "$opane" ] || die "orchestrator here: not in a herdr pane (HERDR_PANE_ID is unset)"
    oget="$(hd agent get "$opane" 2>/dev/null)" || die "orchestrator here: herdr agent get $opane failed"
    oref="$(printf '%s' "$oget" | jq -r '(.result.agent.name // "") | select(. != "") // empty' 2>/dev/null || true)"
    opane2="$(printf '%s' "$oget" | jq -r '(.result.agent.pane_id // "") | select(. != "") // empty' 2>/dev/null || true)"
    [ -n "$opane2" ] && opane="$opane2"; [ -n "$oref" ] || oref="$opane"
    # No --transcript: the newest session file of this directory's Claude project (UNVERIFIED: the
    # newest file is this session's when one Claude Code session runs in the directory).
    if [ -z "$otr" ]; then otr="$(ls -t "$(transcript_dir_for "$PWD")"/*.jsonl 2>/dev/null | head -n 1 || true)"; fi
    update --arg r "$oref" --arg p "$opane" --arg tr "$otr" --arg m "$(machine_key 2>/dev/null || true)" --arg cwd "$PWD" --arg t "$(now)" \
      '(.agents.orchestrator.target_teams // null) as $goal
       | .agents.orchestrator = {name: "orchestrator", team: "orchestrator", tier: "Orchestrator", status: "Working", herdr_ref: $r, pane: $p,
         machine: $m, cwd: $cwd, at: $t, started: $t, updated_at: $t, discovered: [], escalations: []} + (if $tr != "" then {transcript: $tr} else {} end)
         + (if $goal != null then {target_teams: $goal} else {} end)'
    "$0" get orchestrator
    ;;
  pref)
    k="${1:?usage: pref <key> [value]}"
    case "$k" in [!a-z]* | *[!a-z0-9_]*) die "a pref key is lower case letters, digits and _: $k" ;; esac
    if [ $# -ge 2 ]; then
      update --arg k "$k" --arg v "$2" '.prefs = ((.prefs // {}) + {($k): $v})'
    else
      jq -r --arg k "$k" '.prefs[$k] // empty' "$FLEET_REGISTRY"
    fi
    ;;
  path) printf '%s\n' "$FLEET_REGISTRY" ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
