#!/usr/bin/env bash
# Live fleet monitor for humans. (The Orchestrator loop uses tick.sh, which supersedes this.)
# Run it in its own herdr pane: it recomputes health every
# N seconds, prints each status transition, and raises a notification when an agent
# becomes Stalled, Zombie or Needs input, or finishes.
#
#   watch.sh [--team T] [--every SECONDS] [--once]
#
# It also prints and notifies once when free disk falls below warn_free_gb (and once more
# below min_free_gb, where boot refuses), and prints once when it recovers.
# --once does a single pass and exits.
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr

args=(); every=20; once=false
while [ $# -gt 0 ]; do
  case "$1" in
    --team) args+=(--team "$2"); shift 2 ;;
    --every) every="$2"; shift 2 ;;
    --once) once=true; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

# A failed notification is logged, never hidden; it must not stop the monitor.
push() {
  local err
  err="$(hd notification show "$@" 2>&1 >/dev/null)" || warn "notification failed: $1: $(printf '%s' "$err" | head -1)"
}

prev="{}"; disk_state=ok
check_disk() {
  local free warn min state
  free="$(free_gb)" || return 0
  warn="$(warn_free_gb)"; min="$(min_free_gb)"
  state=ok
  [ "$free" -ge "$warn" ] || state=warn
  [ "$min" -le 0 ] || [ "$free" -ge "$min" ] || state=min
  if [ "$state" != "$disk_state" ]; then
    printf '%s  disk %s GiB free (warn_free_gb=%s)\n' "$(date +%H:%M:%S)" "$free" "$warn"
    case "$state" in
      warn) push "fleet: disk $free GiB free (warn_free_gb=$warn)" --sound request ;;
      min) push "fleet: disk $free GiB free, boot refuses below min_free_gb=$min" --sound request ;;
    esac
    disk_state="$state"
  fi
}
while :; do
  cur="$("$FLEET_SCRIPTS/status.sh" ${args[@]+"${args[@]}"} --json 2>/dev/null | jq -c 'map({(.name): .status}) | add // {}')" || cur="$prev"
  # Rows that left the live list (Done or Retired) are reported from the registry.
  while IFS='|' read -r name from to; do
    [ -z "$name" ] && continue
    [ -z "$to" ] && to="$("$FLEET_SCRIPTS/registry.sh" get "$name" 2>/dev/null | jq -r .status || echo gone)"
    printf '%s  %-40s %s → %s\n' "$(date +%H:%M:%S)" "$name" "${from:-new}" "$to"
    case "$to" in
      Stalled|Zombie|"Needs input") push "fleet: $name $to" --sound request ;;
      Done) push "fleet: $name done" --sound done ;;
    esac
  done < <(jq -rn --argjson p "$prev" --argjson c "$cur" '
    (($p | keys) + ($c | keys) | unique)[] as $k
    | select($p[$k] != $c[$k]) | [$k, ($p[$k] // ""), ($c[$k] // "")] | join("|")')
  prev="$cur"
  check_disk
  ! $once || break
  sleep "$every"
done
