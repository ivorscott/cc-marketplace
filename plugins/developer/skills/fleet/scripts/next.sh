#!/usr/bin/env bash
# Move a team to its next issue after a PR merged (the Orchestrator's answer to a pr_merged tick event).
#
#   next.sh <team> <issue> [--brief TEXT]
#
#   1. claim the issue, when scripts/linear.sh exists and answers (not shipped yet: skipped);
#      a claim that fails aborts before any row changes
#   2. registry.sh reassign: every row of the team gets the issue, a clean outcome/PR/sign-off,
#      its open escalations closed ("closed at next") and status Working
#   3. workers get /clear; the lead gets /compact when its context is above compact_above_pct
#      (config.toml, default 50) or when the percentage cannot be read
#   4. the lead gets the brief (--brief TEXT, default "New issue: <issue>.") plus the fleet rules
# Slash commands are sent with --no-confirm (they change neither state nor transcript); the
# brief is confirmed. A message that is not delivered marks that row Failed and next exits 1.
# UNVERIFIED against real herdr output: the context percentage is read from the lead's screen
# ("NN% context used" or "context left ... NN%") and the patterns are a guess (DEV-368 decision 5).
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"

team="${1:?usage: next.sh <team> <issue> [--brief TEXT]}"; issue="${2:?usage: next.sh <team> <issue> [--brief TEXT]}"; shift 2
brief_text=""
while [ $# -gt 0 ]; do
  case "$1" in
    --brief) brief_text="${2:?--brief needs text}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
[ -n "$brief_text" ] || brief_text="New issue: $issue."

rows="$("$registry" list --team "$team" | jq -c '[.[] | select(.status != "Retired" and .tier != "Orchestrator")]')"
[ "$(printf '%s' "$rows" | jq length)" != 0 ] || die "no live rows for team '$team'"

if [ -x "$FLEET_SCRIPTS/linear.sh" ]; then
  rc=0; "$FLEET_SCRIPTS/linear.sh" claim "$issue" || rc=$?
  case "$rc" in
    0) ;;
    3) warn "claims unavailable; moving $team to $issue unclaimed" ;;
    *) die "could not claim $issue; $team keeps its current issue" ;;
  esac
fi

"$registry" reassign "$team" "$issue" >/dev/null

failed=()
send() { # send <row name> <text> [--no-confirm]
  "$FLEET_SCRIPTS/tell.sh" "$@" >/dev/null || { "$registry" set "$1" status=Failed >/dev/null; failed+=("$1"); return 1; }
}

# context_pct <herdr ref>: percent of context used, from the visible screen; empty when unknown.
context_pct() {
  local s; s="$(hd agent read "$1" --source visible 2>/dev/null | tail -n 15 || true)"
  printf '%s\n' "$s" | awk '
    match($0, /[0-9]+% *(of )?context( used)?/) { t = substr($0, RSTART, RLENGTH); sub(/%.*/, "", t); print t; exit }
    match($0, /[Cc]ontext left[^0-9]*[0-9]+%/) { t = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", t); print 100 - t; exit }'
}

lead=""
while IFS= read -r name; do
  if [ "$(printf '%s' "$rows" | jq -r --arg n "$name" '.[] | select(.name == $n) | .tier')" = "Lead" ]; then lead="$name"; continue; fi
  send "$name" /clear --no-confirm || true
done < <(printf '%s' "$rows" | jq -r '.[].name')

if [ -n "$lead" ]; then
  ref="$(printf '%s' "$rows" | jq -r --arg n "$lead" '.[] | select(.name == $n) | .herdr_ref')"
  pct="$(context_pct "$ref")"; above="$(cfg_int compact_above_pct 50)"
  if [ -z "$pct" ] || [ "$pct" -gt "$above" ]; then
    send "$lead" /compact --no-confirm || true
    hd agent wait "$ref" --until idle --timeout 120000 >/dev/null 2>&1 || true
  fi
  ex="$(printf '%s' "$rows" | jq -r --arg n "$lead" '.[] | select(.name == $n) | .expertise_file // ""')"
  case " ${failed[*]:-} " in *" $lead "*) ;; *) send "$lead" "$(build_brief "$lead" "$ex" "$brief_text")" || true ;; esac
fi

if [ "${#failed[@]}" -gt 0 ]; then
  warn "not delivered to: ${failed[*]} (rows set to Failed)"
  exit 1
fi
jq -cn --arg t "$team" --arg i "$issue" '{team: $t, issue: $i, moved: true}'
