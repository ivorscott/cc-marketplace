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
#   registry.sh env-claim <team> <max> <cluster> [busy-slots]  atomically take the lowest free port slot
#   registry.sh env-set <team> key=value ...               update a team environment
#   registry.sh env-get <team>
#   registry.sh env-release <team>                         mark the environment Down, freeing its slot
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
    if [ "${1:-}" = "--envs" ]; then jq '.envs // {}' "$FLEET_REGISTRY"; exit 0; fi
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
  *) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
