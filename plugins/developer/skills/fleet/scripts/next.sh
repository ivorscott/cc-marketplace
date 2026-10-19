#!/usr/bin/env bash
# Move a team to its next issue after a PR merged (the Orchestrator's answer to a pr_merged tick event).
#
#   next.sh <team> <issue> [--brief TEXT]
#
#   1. claim the issue through linear.sh; a claim that fails aborts before any row changes. When claims are
#      unavailable (no key, or linear_writes off) the team moves unclaimed, as boot does, except with
#      `machines` > 1 in config.toml: then nothing could stop another machine taking the issue, and next refuses
#   2. registry.sh reassign: every row of the team gets the issue, a clean outcome/PR/sign-off,
#      its open escalations closed ("closed at next") and status Working
#   3. workers get /clear and the row's `transcript` is re-pointed at the new session file
#      (/clear starts a new transcript with a new session id); the lead gets /compact when its
#      context is above compact_above_pct (config.toml, default 50) or when it cannot be read
#   4. the lead gets the brief (--brief TEXT, default "New issue: <issue>.") plus the fleet rules
# Slash commands are sent with --no-confirm (they change neither state nor transcript); the
# brief is confirmed. A message that is not delivered marks that row Failed and next exits 1.
# The lead's context percentage comes from its transcript: the latest assistant turn's
# input + cache tokens against the model's window ([context_window] in config.toml, default
# 200000). Fallback: the lead's screen ("NN% context used" or "context left ... NN%"). UNVERIFIED:
# the real window per model, the screen patterns, and the transcript format across Claude Code
# updates (DEV-368 decision 5, amended).
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

# A linear.sh that is missing or not executable counts as claims unavailable (3), so the machines rule still applies.
rc=3; if [ -x "$FLEET_SCRIPTS/linear.sh" ]; then rc=0; "$FLEET_SCRIPTS/linear.sh" claim "$issue" || rc=$?; fi
if true; then
  case "$rc" in
    0) ;;
    3) if [ "$(cfg_int machines 1)" -gt 1 ]; then die "claims are unavailable (no Linear key, or linear_writes off) and machines > 1 in config.toml, so $issue cannot be claimed. $team keeps its current issue"; fi
       warn "claims unavailable; moving $team to $issue unclaimed" ;;
    *) die "could not claim $issue; $team keeps its current issue" ;;
  esac
fi

"$registry" reassign "$team" "$issue" >/dev/null
ev_log next team="$team" issue="$issue"

failed=()
send() { # send <row name> <text> [--no-confirm]
  "$FLEET_SCRIPTS/tell.sh" "$@" >/dev/null || { "$registry" set "$1" status=Failed >/dev/null; failed+=("$1"); return 1; }
}

# context_pct <transcript> <herdr ref>: percent of context used, from the transcript, else the
# visible screen; empty when unknown.
context_pct() {
  local p s; p="$(transcript_context_pct "$1")"
  if [ -n "$p" ]; then printf '%s\n' "$p"; return 0; fi
  s="$(hd agent read "$2" --source visible 2>/dev/null | tail -n 15 || true)"
  printf '%s\n' "$s" | awk '
    match($0, /[0-9]+% *(of )?context( used)?/) { t = substr($0, RSTART, RLENGTH); sub(/%.*/, "", t); print t; exit }
    match($0, /[Cc]ontext left[^0-9]*[0-9]+%/) { t = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", t); print 100 - t; exit }'
}

# clear_session <row name>: /clear a worker, then point its row's transcript at the new session file
# (the files in its project dir that did not exist before the clear; the newest wins).
clear_session() {
  local name="$1" cwd dir before="" f best="" t=0 secs poll="${FLEET_TELL_POLL:-1}"
  cwd="$(printf '%s' "$rows" | jq -r --arg n "$name" '.[] | select(.name == $n) | .cwd // ""')"
  dir=""; [ -z "$cwd" ] || dir="$(transcript_dir_for "$cwd")"
  [ -z "$dir" ] || before="$(ls "$dir"/*.jsonl 2>/dev/null || true)"
  send "$name" /clear --no-confirm || return 0
  [ -n "$dir" ] || return 0
  secs="$(cfg_int tell_confirm_secs 15)"
  while :; do
    for f in $(ls -t "$dir"/*.jsonl 2>/dev/null || true); do
      printf '%s\n' "$before" | grep -qxF "$f" || { best="$f"; break; }
    done
    [ -z "$best" ] || break
    [ "$t" -ge "$secs" ] && break
    sleep "$poll"; t=$((t + 1))
  done
  if [ -n "$best" ]; then "$registry" set "$name" transcript="$best" >/dev/null
  else warn "no new transcript for $name after /clear; its transcript path may be stale"; fi
}

lead=""
while IFS= read -r name; do
  if [ "$(printf '%s' "$rows" | jq -r --arg n "$name" '.[] | select(.name == $n) | .tier')" = "Lead" ]; then lead="$name"; continue; fi
  clear_session "$name"
done < <(printf '%s' "$rows" | jq -r '.[].name')

if [ -n "$lead" ]; then
  ref="$(printf '%s' "$rows" | jq -r --arg n "$lead" '.[] | select(.name == $n) | .herdr_ref')"
  pct="$(context_pct "$(printf '%s' "$rows" | jq -r --arg n "$lead" '.[] | select(.name == $n) | .transcript // ""')" "$ref")"; above="$(cfg_int compact_above_pct 50)"
  if [ -z "$pct" ] || [ "$pct" -gt "$above" ]; then
    send "$lead" /compact --no-confirm || true
    hd agent wait "$ref" --until idle --timeout 120000 >/dev/null 2>&1 || true
  fi
  ex="$(printf '%s' "$rows" | jq -r --arg n "$lead" '.[] | select(.name == $n) | .expertise_file // ""')"
  case " ${failed[*]:-} " in *" $lead "*) ;; *) send "$lead" "$(build_brief "$lead" "$ex" "$brief_text")" --brief || true ;; esac
fi

if [ "${#failed[@]}" -gt 0 ]; then
  warn "not delivered to: ${failed[*]} (rows set to Failed)"
  exit 1
fi
jq -cn --arg t "$team" --arg i "$issue" '{team: $t, issue: $i, moved: true}'
