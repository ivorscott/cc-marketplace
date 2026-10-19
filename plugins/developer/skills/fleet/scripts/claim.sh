#!/usr/bin/env bash
# Lease arithmetic for claims. Pure functions of their inputs; this script never calls a tracker.
# (Claims are labels; liveness is a heartbeat line in the label description, written by the claims script.)
#
#   claim.sh lease [--hours H] [--now ISO]
#       prints now + H hours: the lease a heartbeat taken now would give
#   claim.sh hb
#       stdin: a label description; prints the ISO time of its heartbeat=<ISO> line (nothing when absent)
#   claim.sh expired --lease ISO [--last-activity ISO] [--hours H] [--now ISO]
#       exit 0 when the claim can be taken over: now is past the lease AND there was no PR
#       activity in the last H hours. Exit 1 with the reason on stderr otherwise.
#
# H defaults to lease_hours in config.toml (default 2). --now replaces the clock (tests).
set -euo pipefail
. "$(dirname "$0")/common.sh"

epoch() { jq -rn --arg t "$1" '$t | fromdateiso8601' 2>/dev/null || die "not a UTC time (YYYY-MM-DDTHH:MM:SSZ): $1"; }
plus_hours() { # plus_hours <ISO> <hours>
  jq -rn --arg t "$1" --argjson h "$2" '($t | fromdateiso8601) + ($h * 3600) | floor | todate' 2>/dev/null || die "not a UTC time: $1"
}
hours_arg() { case "$1" in "" | *[!0-9]*) die "hours must be a whole number: $1" ;; esac; printf '%s' "$1"; }

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  lease)
    hours="$(lease_hours)"; at="${FLEET_NOW:-}"
    while [ $# -gt 0 ]; do
      case "$1" in
        --hours) hours="$(hours_arg "${2:?--hours needs a value}")"; shift 2 ;;
        --now) at="${2:?--now needs a value}"; shift 2 ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [ -n "$at" ] || at="$(now)"
    plus_hours "$at" "$hours" ;;

  hb)
    sed -n 's/^heartbeat=\([^[:space:]]*\).*/\1/p' | head -n 1 ;;

  expired)
    lease=""; act=""; hours="$(lease_hours)"; at="${FLEET_NOW:-}"
    while [ $# -gt 0 ]; do
      case "$1" in
        --lease) lease="${2:?--lease needs a value}"; shift 2 ;;
        --last-activity) act="${2:?--last-activity needs a value}"; shift 2 ;;
        --hours) hours="$(hours_arg "${2:?--hours needs a value}")"; shift 2 ;;
        --now) at="${2:?--now needs a value}"; shift 2 ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [ -n "$lease" ] || die "usage: claim.sh expired --lease ISO [--last-activity ISO] [--hours H] [--now ISO]"
    [ -n "$at" ] || at="$(now)"
    n="$(epoch "$at")"; le="$(epoch "$lease")"
    if [ "$n" -le "$le" ]; then
      printf 'lease is live until %s (now %s)\n' "$lease" "$at" >&2; exit 1
    fi
    if [ -n "$act" ]; then
      ae="$(epoch "$act")"
      if [ "$ae" -gt $((n - hours * 3600)) ]; then
        printf 'PR activity at %s is within the last %s hours (now %s)\n' "$act" "$hours" "$at" >&2; exit 1
      fi
    fi
    exit 0 ;;

  *) echo "usage: claim.sh lease|hb|expired ..." >&2; exit 2 ;;
esac
