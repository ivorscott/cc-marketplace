#!/usr/bin/env bash
# Fleet registry: one JSON file, one row per agent identity (<team>/<role>).
# Every agent in the fleet uses this CLI, so writes are serialised with a lock.
#
#   registry.sh add '<json object with at least .name>'   upsert a row
#   registry.sh set <name> key=value [key=value ...]      update fields
#   registry.sh get <name>
#   registry.sh list [--team T] [--live] [--problems]
#   registry.sh count-live                                 agents counted against max_agents
#   registry.sh done <name> --outcome O --summary TEXT     the done contract (+ notification)
#   registry.sh escalate <name> P0|P1|P2 TEXT              severity-routed escalation (+ notification)
#   registry.sh note <name> discovered TEXT                file discovered work instead of fixing it
#   registry.sh retire <name|team> [--outcome O]
#   registry.sh unsynced                                   rows changed since the sink last mirrored them
#   registry.sh synced <name> [name ...]                   mark rows as mirrored
#   registry.sh path
set -euo pipefail
. "$(dirname "$0")/common.sh"

mkdir -p "$(dirname "$FLEET_REGISTRY")"
[ -f "$FLEET_REGISTRY" ] || printf '{"agents":{}}\n' >"$FLEET_REGISTRY"

LOCK="$FLEET_REGISTRY.lock"
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
    mv "$tmp" "$FLEET_REGISTRY"
  else
    rm -f "$tmp"; die "registry update failed; $FLEET_REGISTRY left unchanged"
  fi
}

exists() { jq -e --arg n "$1" '.agents[$n] != null' "$FLEET_REGISTRY" >/dev/null || die "no agent '$1' in the registry"; }

notify() {
  [ "${HERDR_ENV:-}" = "1" ] || [ -n "${FLEET_SESSION:-}" ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  hd notification show "$1" --body "$2" --sound "${3:-done}" >/dev/null 2>&1 || true
}

LIVE='(.status != "Done" and .status != "Retired")'
PROBLEM='(.status == "Stalled" or .status == "Zombie" or .status == "Needs input" or (.escalation // "") != "")'

cmd="${1:-}"; shift || true
case "$cmd" in
  add)
    row="${1:?usage: add '<json>'}"
    printf '%s' "$row" | jq -e 'type == "object" and (.name | type == "string")' >/dev/null || die "add needs a JSON object with .name"
    update --argjson r "$row" --arg t "$(now)" \
      '.agents[$r.name] = ((.agents[$r.name] // {started: $t, discovered: [], escalations: []}) + $r + {updated_at: $t})'
    ;;
  set)
    name="${1:?usage: set <name> key=value ...}"; shift
    exists "$name"
    args=(--arg n "$name"); prog='.agents[$n]'
    i=0
    for kv in "$@"; do
      k="${kv%%=*}"; v="${kv#*=}"
      args+=(--arg "k$i" "$k" --arg "v$i" "$v"); prog="$prog | .[\$k$i] = \$v$i"; i=$((i + 1))
    done
    update "${args[@]}" --arg t "$(now)" ".agents[\$n] = ($prog | .updated_at = \$t)"
    ;;
  get)
    jq -e --arg n "${1:?usage: get <name>}" '.agents[$n] // error("no such agent")' "$FLEET_REGISTRY"
    ;;
  list)
    team=""; filter="true"
    while [ $# -gt 0 ]; do
      case "$1" in
        --team) team="$2"; shift 2 ;;
        --live) filter="$filter and $LIVE"; shift ;;
        --problems) filter="$filter and $LIVE and $PROBLEM"; shift ;;
        *) die "unknown list option: $1" ;;
      esac
    done
    jq --arg t "$team" "[.agents[] | select((\$t == \"\" or .team == \$t) and $filter)]" "$FLEET_REGISTRY"
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
    update --arg n "$name" --arg s "$sev" --arg m "$msg" --arg t "$(now)" \
      '.agents[$n] |= (.status = "Needs input" | .escalation = $s | .escalations += [{severity: $s, message: $m, at: $t}] | .updated_at = $t)'
    notify "fleet $sev: $name" "$msg" request
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
    update --arg x "$target" --arg o "$outcome" --arg t "$(now)" '
      .agents |= with_entries(
        if (.key == $x or .value.team == $x) and .value.status != "Retired" then
          .value |= (.status = "Retired" | .ended = $t | .updated_at = $t
            | .outcome = (if .name == $x and $o != "" then $o else (.outcome // (if $o != "" then $o else "Abandoned" end)) end))
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
  path) printf '%s\n' "$FLEET_REGISTRY" ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
