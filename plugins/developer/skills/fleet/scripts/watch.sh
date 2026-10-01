#!/usr/bin/env bash
# Live fleet monitor. Run it in its own herdr pane: it recomputes health every
# N seconds, prints each status transition, and raises a notification when an agent
# becomes Stalled, Zombie or Needs input, or finishes.
#
#   watch.sh [--team T] [--every SECONDS] [--once]
#
# It also prints free disk each pass and notifies once when it falls below warn_free_gb
# (and once more below min_free_gb, where boot refuses); it re-arms when disk recovers.
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

prev="{}"; disk_state=ok
check_disk() {
  local free warn min state
  free="$(free_gb)" || return 0
  warn="$(warn_free_gb)"; min="$(min_free_gb)"
  state=ok
  [ "$free" -ge "$warn" ] || state=warn
  [ "$min" -le 0 ] || [ "$free" -ge "$min" ] || state=min
  printf '%s  disk %s GiB free (warn_free_gb=%s)\n' "$(date +%H:%M:%S)" "$free" "$warn"
  if [ "$state" != "$disk_state" ]; then
    case "$state" in
      warn) hd notification show "fleet: disk $free GiB free (warn_free_gb=$warn)" --sound request >/dev/null 2>&1 || true ;;
      min) hd notification show "fleet: disk $free GiB free, boot refuses below min_free_gb=$min" --sound request >/dev/null 2>&1 || true ;;
    esac
    disk_state="$state"
  fi
}
while :; do
  cur="$("$FLEET_SCRIPTS/status.sh" "${args[@]}" --json 2>/dev/null | jq -c 'map({(.name): .status}) | add // {}')" || cur="$prev"
  # Rows that left the live list (Done or Retired) are reported from the registry.
  while IFS='|' read -r name from to; do
    [ -z "$name" ] && continue
    [ -z "$to" ] && to="$("$FLEET_SCRIPTS/registry.sh" get "$name" 2>/dev/null | jq -r .status || echo gone)"
    printf '%s  %-40s %s → %s\n' "$(date +%H:%M:%S)" "$name" "${from:-new}" "$to"
    case "$to" in
      Stalled|Zombie|"Needs input") hd notification show "fleet: $name $to" --sound request >/dev/null 2>&1 || true ;;
      Done) hd notification show "fleet: $name done" --sound done >/dev/null 2>&1 || true ;;
    esac
  done < <(jq -rn --argjson p "$prev" --argjson c "$cur" '
    (($p | keys) + ($c | keys) | unique)[] as $k
    | select($p[$k] != $c[$k]) | [$k, ($p[$k] // ""), ($c[$k] // "")] | join("|")')
  prev="$cur"
  check_disk
  ! $once || break
  sleep "$every"
done
