#!/usr/bin/env bash
# The claim comment: build it, parse it, renew its lease, test whether a lease can be taken over.
# Pure functions of their inputs. This script never calls a tracker; the Orchestrator reads and
# writes the comments with its own tools and passes the text in.
#
#   claim.sh line --machine KEY [--name N] --team T [--at ISO] [--lease-hours H] --scope 'repo: p1, p2'
#                 [--takeover-from KEY --takeover-team T --takeover-of-comment ID --previous-lease ISO]
#       prints the claim comment (takeover: line only when taking over, naming the voided comment)
#   claim.sh renew [--hours H] [--now ISO] <comment-body | ->
#       prints the body with lease= moved to now + H hours (at= and the takeover: line stay)
#   claim.sh lease [--hours H] [--now ISO]
#       prints now + H hours, the lease a claim written now would carry
#   claim.sh parse
#       stdin: JSON [{id, createdAt, updatedAt, body, issue?}, ...]; prints one JSON object per claim
#       comment in an array, skipping comments that are not claims
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
  line)
    machine=""; name=""; team=""; at=""; hours="$(lease_hours)"; scope=""
    tfrom=""; tteam=""; tcomment=""; tprev=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --machine) machine="${2:?--machine needs a value}"; shift 2 ;;
        --name) name="${2:?--name needs a value}"; shift 2 ;;
        --team) team="${2:?--team needs a value}"; shift 2 ;;
        --at) at="${2:?--at needs a value}"; shift 2 ;;
        --lease-hours) hours="$(hours_arg "${2:?--lease-hours needs a value}")"; shift 2 ;;
        --scope) scope="${2:?--scope needs a value}"; shift 2 ;;
        --takeover-from) tfrom="${2:?--takeover-from needs a value}"; shift 2 ;;
        --takeover-team) tteam="${2:?--takeover-team needs a value}"; shift 2 ;;
        --takeover-of-comment) tcomment="${2:?--takeover-of-comment needs a value}"; shift 2 ;;
        --previous-lease) tprev="${2:?--previous-lease needs a value}"; shift 2 ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [ -n "$machine" ] && [ -n "$team" ] && [ -n "$scope" ] || die "usage: claim.sh line --machine KEY --team T --scope 'repo: paths' [options]"
    [ -n "$at" ] || at="${FLEET_NOW:-$(now)}"
    lease="$(plus_hours "$at" "$hours")"
    head="fleet-claim: machine=$machine"
    [ -n "$name" ] && head="$head name=\"${name//\"/}\""
    printf '%s team=%s at=%s lease=%s\nscope: %s\n' "$head" "$team" "$at" "$lease" "$scope"
    if [ -n "$tfrom" ]; then
      [ -n "$tteam" ] && [ -n "$tcomment" ] && [ -n "$tprev" ] ||
        die "a takeover needs --takeover-team, --takeover-of-comment and --previous-lease"
      epoch "$tprev" >/dev/null
      printf 'takeover: from=%s team=%s comment=%s at=%s previous-lease=%s reason=expired\n' "$tfrom" "$tteam" "$tcomment" "$at" "$tprev"
    fi ;;

  renew)
    hours="$(lease_hours)"; at="${FLEET_NOW:-}"; body=""; have=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --hours) hours="$(hours_arg "${2:?--hours needs a value}")"; shift 2 ;;
        --now) at="${2:?--now needs a value}"; shift 2 ;;
        *) body="$1"; have=true; shift ;;
      esac
    done
    $have || die "usage: claim.sh renew [--hours H] [--now ISO] <comment-body | ->"
    [ "$body" = "-" ] && body="$(cat)"
    [ -n "$at" ] || at="$(now)"
    printf '%s\n' "$body" | grep -q '^fleet-claim:' || die "not a claim comment (no fleet-claim: line)"
    new="$(plus_hours "$at" "$hours")"
    printf '%s\n' "$body" | awk -v l="$new" '
      /^fleet-claim:/ && !done { if ($0 ~ / lease=[^ ]+/) sub(/ lease=[^ ]+/, " lease=" l); else $0 = $0 " lease=" l; done = 1 }
      { print }' ;;

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

  parse)
    jq -ce '
      def kv: [scan("([A-Za-z][A-Za-z0-9-]*)=(\"[^\"]*\"|[^ ]+)")] | map({(.[0]): (.[1] | ltrimstr("\"") | rtrimstr("\""))}) | add // {};
      def lines: (.body // "") | split("\n") | map(sub("^\\s+"; ""));
      def scope_of($s): ($s | if test(":") then {repo: (split(":")[0] | sub("^\\s+|\\s+$"; "")), paths: (sub("^[^:]*:"; "") | split(",") | map(sub("^\\s+|\\s+$"; "")) | map(select(length > 0)))}
        else {repo: (sub("^\\s+|\\s+$"; "")), paths: []} end);
      [ (if type == "array" then . else [.] end)[]
        | . as $c | lines as $ls
        | ([$ls[] | select(startswith("fleet-claim:"))][0]) as $head
        | select($head != null)
        | ($head | ltrimstr("fleet-claim:") | kv) as $h
        | ([$ls[] | select(startswith("scope:"))][0] // "scope: ") as $sl
        | ([$ls[] | select(startswith("takeover:"))][0]) as $tl
        | ($tl | if . == null then {} else ltrimstr("takeover:") | kv end) as $t
        | {id: $c.id, issue: ($c.issue // null), machine: $h.machine, name: ($h.name // null), team: $h.team, at: $h.at, lease: ($h.lease // null),
           scope: scope_of($sl | ltrimstr("scope:")),
           takeover_from: ($t.from // null), takeover_team: ($t.team // null), takeover_of_comment: ($t.comment // null),
           takeover_previous_lease: ($t["previous-lease"] // null),
           created_at: ($c.createdAt // null), updated_at: ($c.updatedAt // null)} ]' ;;

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

  *) echo "usage: claim.sh line|renew|lease|parse|expired ..." >&2; exit 2 ;;
esac
