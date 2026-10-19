#!/usr/bin/env bash
# Move a team to its next issue after a PR merged (the Orchestrator's answer to a pr_merged tick event).
#
#   next.sh <team> <issue> [--brief TEXT] [--assignment TEXT] [--issue-url URL]
#
#   0. one next per team at a time: a second call while one runs exits 4 and changes nothing (the lock holds
#      the pid; a lock whose process is gone, e.g. after SIGKILL, is taken over)
#   1. safe point: every agent of the team must be idle (not mid-turn) with no background task running;
#      otherwise nothing changes, it says who is busy and exits 1 (run it again later)
#   2. claim the issue, when scripts/linear.sh exists and answers; a claim that fails aborts before any row
#      changes (no Linear key: proceeds unclaimed with a warning)
#   3. registry.sh reassign: issue_done is logged for the old issue, every row gets the new issue and
#      assignment (--assignment, default the issue), a clean outcome/PR/sign-off, its open escalations closed
#      ("closed at next"); workers go Idle, the lead Working
#   4. every agent is restarted (respawn.sh --restart): /exit, then a fresh start in its pane with a new
#      --session-id and its full brief as a file (tell.sh --brief). The workers restart in parallel, then the
#      lead (so the whole move takes about two restarts, not one per agent). The lead's brief
#      also carries --brief TEXT (default "New issue: <issue>."). No /clear and no /compact: a fresh session
#      also picks up an updated plugin.
#      Claims unavailable (no key, or linear_writes off): the team moves unclaimed, except with `machines` > 1 in
#      config.toml, where nothing could stop another machine taking the issue and next refuses.
# It can take a few minutes: run it in the background (Bash run_in_background) and wait for its completion.
# An agent whose restart fails (it did not exit, did not start, or its brief did not arrive) is set Failed and
# next exits 1 naming it; the others are restarted. UNVERIFIED against real herdr: `herdr agent start` after
# /exit in the same pane.
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"

usage="usage: next.sh <team> <issue> [--brief TEXT] [--assignment TEXT] [--issue-url URL]"
team="${1:?$usage}"; issue="${2:?$usage}"; shift 2
brief_text=""; assignment=""; issue_url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --brief) brief_text="${2:?--brief needs text}"; shift 2 ;;
    --assignment) assignment="${2:?--assignment needs text}"; shift 2 ;;
    --issue-url) issue_url="${2:?--issue-url needs a URL}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
[ -n "$brief_text" ] || brief_text="New issue: $issue."

# 0. One next per team at a time.
mkdir -p "$FLEET_STATE_DIR"
lock="$FLEET_STATE_DIR/next.$(printf '%s' "$team" | tr -c 'A-Za-z0-9_-' '_').lock"
if ! mkdir "$lock" 2>/dev/null; then
  holder="$(cat "$lock/pid" 2>/dev/null || true)"
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then # its next.sh is gone (SIGKILL, power cut): take over
    rm -rf "$lock"; mkdir "$lock" 2>/dev/null || { printf 'fleet: next_skipped: another next.sh is moving %s\n' "$team" >&2; exit 4; }
  else
    printf 'fleet: next_skipped: another next.sh is moving %s (pid %s)\n' "$team" "${holder:-unknown}" >&2
    exit 4
  fi
fi
printf '%s\n' "$$" >"$lock/pid"
trap 'rm -rf "$lock"' EXIT

rows="$("$registry" list --team "$team" | jq -c '[.[] | select(.status != "Retired" and .tier != "Orchestrator")]')"
[ "$(printf '%s' "$rows" | jq length)" != 0 ] || die "no live rows for team '$team'"

# 1. Safe point. herdr must answer (a failed call is not "idle"), every agent must be idle or done, and no
# background task may be running (its transcript; the pane footer when there is no transcript).
hd agent list >/dev/null 2>&1 || die "herdr is not answering; $team is unchanged"
busy=()
while IFS= read -r r; do
  n="$(printf '%s' "$r" | jq -r .name)"; ref="$(printf '%s' "$r" | jq -r '.herdr_ref // ""')"
  st="$(hd agent get "$ref" 2>/dev/null | jq -r '.result.agent.agent_status // "gone"' 2>/dev/null || echo gone)"
  case "$st" in
    idle | done) ;;
    gone) busy+=("$n (not running)"); continue ;;
    *) busy+=("$n ($st)"); continue ;;
  esac
  tr_="$(printf '%s' "$r" | jq -r '.transcript // ""')"
  if type transcript_bg_running >/dev/null 2>&1 && [ -n "$tr_" ] && [ -r "$tr_" ]; then
    [ "$(transcript_bg_running "$tr_")" = 0 ] || busy+=("$n (background task)")
  elif hd agent read "$ref" --source visible 2>/dev/null | tail -n 8 | grep -Eq '[0-9]+ (shell|monitor)s?([ ,.]|$)'; then
    busy+=("$n (background task)")
  fi
done < <(printf '%s' "$rows" | jq -c '.[]')
if [ "${#busy[@]}" -gt 0 ]; then
  ev_log next_deferred team="$team" issue="$issue" detail="not at a safe point"
  die "$team is not at a safe point (${busy[*]}); nothing changed, run next again later"
fi

# 2. Claim.
if [ -x "$FLEET_SCRIPTS/linear.sh" ]; then
  rc=0; "$FLEET_SCRIPTS/linear.sh" claim "$issue" || rc=$?
  case "$rc" in
    0) ;;
    3) if [ "$(cfg_int machines 1)" -gt 1 ]; then die "claims are unavailable (no Linear key, or linear_writes off) and machines > 1 in config.toml, so $issue cannot be claimed. $team keeps its current issue"; fi
       warn "claims unavailable; moving $team to $issue unclaimed" ;;
    *) die "could not claim $issue; $team keeps its current issue" ;;
  esac
fi

# 3. Reassign.
ra=(reassign "$team" "$issue"); [ -z "$assignment" ] || ra+=(--assignment "$assignment"); [ -z "$issue_url" ] || ra+=(--issue-url "$issue_url")
"$registry" "${ra[@]}" >/dev/null
ev_log next team="$team" issue="$issue"

# 4. Restart every agent with its full brief: workers first, so the lead's brief names live workers.
failed=()
restart() { # restart <row name> [brief text]: failures are reported on stdout as the name
  local args=("$1" --restart) errf; [ -z "${2:-}" ] || args+=(--brief-text "$2")
  errf="$FLEET_STATE_DIR/next.$$.$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_').err"
  if ! "$FLEET_SCRIPTS/respawn.sh" "${args[@]}" >/dev/null 2>"$errf"; then
    warn "could not restart $1: $(head -n 1 "$errf" 2>/dev/null)"
    "$registry" set "$1" status=Failed >/dev/null 2>&1 || true
    printf '%s\n' "$1"
  fi
  rm -f "$errf"
}
wfail="$FLEET_STATE_DIR/next.$$.failed"; : >"$wfail"
for n in $(printf '%s' "$rows" | jq -r '.[] | select(.tier != "Lead") | .name'); do restart "$n" >>"$wfail" & done
wait
for n in $(printf '%s' "$rows" | jq -r '.[] | select(.tier == "Lead") | .name'); do restart "$n" "$brief_text" >>"$wfail"; done
while IFS= read -r n; do [ -z "$n" ] || failed+=("$n"); done <"$wfail"
rm -f "$wfail"

if [ "${#failed[@]}" -gt 0 ]; then
  warn "not restarted: ${failed[*]} (rows set to Failed)"
  exit 1
fi
jq -cn --arg t "$team" --arg i "$issue" '{team: $t, issue: $i, moved: true}'
