#!/usr/bin/env bash
# One scheduled tick, run by launchd through the launcher schedule.sh installs, with no model involved:
# tick.sh does the claims, the event log and the classification; this script decides who must hear about it.
#
#   loop-tick.sh
#
# Wake: every event someone must act on reaches the Orchestrator: pr_ready, pr_merged, any escalation (P0/P1
# for the user, P2 the Orchestrator answers itself), dead, stalled (after the nudge), claim_takeover, claim_lost, the claim sweep's
# claim_released, claim_held_pr and claim_lapsed, needs_input,
# brief_failed, stale_version (a decision for the user), weekly_summary (tick writes the metrics report), and
# pr_opened when the lead could not be told
# (WAKE_TYPES in common.sh; tick renders each one's reply into notices.log for `fleet status`). disk and
# repo_without_team go to notify/alert_cmd instead. Nothing is reported to no one.
# A quiet tick prints nothing. A wake is lines appended to $FLEET_STATE_DIR/wakes.log, never typed into a pane: the
# Orchestrator follows that file (Monitor on `tail -n 0 -F`, SKILL.md "Tick"), so a wake needs no delivery and
# nothing is queued or retried. The lines are a FIXED TEMPLATE, one per event:
#   fleet tick: <type> <team> <name> <issue> <PR url> <esc id>
# built from enumerated fields only, each cut to safe characters. An agent's free text (an escalation's
# message, a PR title) never reaches the file; the Orchestrator reads it from the registry. The same line twice in
# one tick is written once. wakes.log is mode 600 and holds at most 500 lines: past that it moves to wakes.log.1
# and a new one starts, so a follower sees only new lines. With no Orchestrator registered (registry.sh
# orchestrator here) nobody follows it, and with no transcript of it to read the no-reply alert cannot work, so in
# both cases the lines also go to a desktop notification.
#
# Alerts (notify with alert_cmd; the text is "Alert: <what happened>. <next step>."), at most once per cause per 4
# hours: an escalation P0/P1 (per agent and id), an agent that went Failed (per agent; a dead one is respawned, and a second
# death is a P1 escalation),
# a login that expired on this Mac (any agent, or the Orchestrator), no Orchestrator reply 15 minutes after a
# wake (the Orchestrator is not watching), herdr down, low disk, a repo with no team, 3 failed loop runs in a row,
# and no good tick within 2x tick_secs. A good tick is one that ran tick.sh and got an event array (or
# nothing) back; a failure, tick_skipped (the lock is held) or junk output is a failed run: printed (launchd
# writes it to loop.log), counted, and the exit status says so. No acks and no automatic Orchestrator respawn.
# State: $FLEET_STATE_DIR/loop.state.json (its own file, so a tick rewriting tick.state.json cannot race it).
# Overlapping runs are excluded by tick.sh's tick lock, not here.
# FLEET_TICK replaces tick.sh in tests. UNVERIFIED: that herdr reached from a launchd job finds the server.
set -euo pipefail
. "$(dirname "$0")/common.sh"
# launchd is not a herdr pane; tick.sh needs to be told it may talk to herdr.
[ -n "${FLEET_SESSION:-}" ] || export HERDR_ENV=1

mkdir -p "$FLEET_STATE_DIR"
LS="$FLEET_STATE_DIR/loop.state.json"
now_iso="${FLEET_NOW:-$(now)}"; now_epoch="$(jq -rn --arg t "$now_iso" '$t | fromdateiso8601')"
jq -e 'type == "object"' "$LS" >/dev/null 2>&1 || echo '{}' >"$LS"
# ls_set <jq args> <program on the state>. Each run writes its own temp file, so two overlapping runs never
# interleave writes into one file (the last rename wins, and the state stays valid JSON).
ls_set() { jq -c "$@" "$LS" >"$LS.$$.new" && mv "$LS.$$.new" "$LS"; }
trap 'rm -f "$LS.$$.new" "${errf:-}"' EXIT

# alert <cause key> <what happened> <next step>: notify with alert_cmd, at most once per cause per 4 hours. The text
# is the alert entry of references/output.md, "Alert: <what happened>. <next step>."
alert() {
  local last
  last="$(jq -r --arg c "$1" '.alerts[$c] // 0' "$LS")"
  [ $((now_epoch - last)) -ge 14400 ] || return 0
  ls_set --arg c "$1" --argjson n "$now_epoch" '.alerts = ((.alerts // {}) + {($c): $n})'
  notify "Fleet needs you" "$(render_line alert cause="$2" next="$3")" request alert
}

# Alerts older than 4 hours no longer suppress anything, so they are dropped (the state stays bounded). An older
# version's wake queue (pending, wake_misses) is dropped too: wakes.log needs none.
ls_set --argjson n "$now_epoch" '.alerts = ((.alerts // {}) | with_entries(select(.value > $n - 14400))) | .since = (.since // $n)
  | del(.pending, .wake_misses)'
WL="$FLEET_STATE_DIR/wakes.log"; (umask 077; touch "$WL")

# --- the tick ---------------------------------------------------------------------------------------
errf="$(mktemp "${TMPDIR:-/tmp}/fleet-loop-err.XXXXXX")"
rc=0; out="$("${FLEET_TICK:-$FLEET_SCRIPTS/tick.sh}" 2>"$errf")" || rc=$?
cat "$errf" >&2
# A good tick ran tick.sh and got an event array (or nothing) back. Anything else is a failed run, and the
# fails counter resets only on a good tick.
why=""
if [ "$rc" != 0 ]; then why="tick.sh failed (exit $rc): $(tail -n 1 "$errf")"
elif grep -q 'tick_skipped' "$errf"; then why="tick.sh skipped: another tick holds the lock"
elif [ -n "$out" ] && ! printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then why="tick.sh printed something that is not an event array"
fi
if [ -n "$why" ]; then
  fails="$(jq -r '(.fails // 0) + 1' "$LS")"
  ls_set --argjson f "$fails" '.fails = $f'
  printf 'loop-tick: %s\n' "$why" >&2
  [ "$fails" -lt 3 ] || alert loop_failed "the fleet loop failed $fails runs in a row" "Read loop.log in the fleet state dir"
  secs="$(cfg_int tick_secs 300)"; lg="$(jq -r '.last_good // .since // 0' "$LS")"
  [ $((now_epoch - lg)) -le $((2 * secs)) ] || alert loop_unhealthy "no good fleet tick in $(((now_epoch - lg) / 60)) min" "Run fleet schedule status"
  exit 1
fi
ls_set --argjson n "$now_epoch" '.fails = 0 | .last_good = $n'
if grep -q 'herdr agent list failed' "$errf"; then
  alert herdr_down "herdr is not answering, so no agent was classified" "Start the herdr server"
fi
[ -n "$out" ] || out='[]'

# --- login expired: any agent (tick's needs_input) or the Orchestrator itself --------------------------
orow="$("$FLEET_SCRIPTS/registry.sh" get orchestrator 2>/dev/null || echo '{}')"
otr="$(printf '%s' "$orow" | jq -r '.transcript // ""' 2>/dev/null || true)"
if printf '%s' "$out" | jq -e 'any(.[]; type == "object" and .type == "needs_input" and .detail == "login expired")' >/dev/null 2>&1 ||
  [ "$(api_error_detail "$otr")" = "login expired" ]; then
  alert login_expired "a login has expired on this Mac" "Run /login in the agent's pane"
fi

# --- no reply to the last wake --------------------------------------------------------------------------
wake_at="$(jq -r '.wake_at // ""' "$LS")"
if [ -n "$wake_at" ] && [ -n "$otr" ] && [ -f "$otr" ]; then
  if tail -n 200 "$otr" | jq -Rre --arg w "$wake_at" 'fromjson? // empty | select(type == "object" and .type == "assistant" and (.timestamp | type == "string") and .timestamp > $w) | 1' >/dev/null 2>&1; then
    ls_set 'del(.wake_at)'
  elif [ $((now_epoch - $(jq -rn --arg t "$wake_at" '$t | fromdateiso8601'))) -ge 900 ]; then
    alert no_reply "the Orchestrator has not answered a wake for 15 minutes" "Open its pane and run fleet status"
  fi
fi

# --- alerts: P0/P1, low disk, a repo with no team -------------------------------------------------------------
safe() { tr -cd 'A-Za-z0-9._:/@#-' | cut -c1-80; }
while IFS=$'\t' read -r cause what; do
  [ -n "$cause" ] || continue
  cause="$(printf '%s' "$cause" | safe)" # what is cut to safe characters per field in jq below
  case "$cause" in
    esc:*) alert "$cause" "escalation $what needs you" "Run fleet escalations --open" ;;
    disk) alert disk "free disk is low ($what GB)" "Free space, or retire a finished team" ;;
    repo_without_team:*) alert "$cause" "repo $what has no team" "Boot one, or drop it from repos in config.toml" ;;
    failed:*) alert "$cause" "agent $what failed" "Run fleet status" ;;
  esac
done < <(printf '%s' "$out" | jq -r 'def s: (. // "-") | tostring | gsub("[^A-Za-z0-9._:/@#-]"; "") | .[0:80];
  .[] | select(type == "object")
  | if .type == "escalation" and (.severity | IN("P0", "P1")) and (.id | type == "string") then ["esc:\(.name | s):\(.id | s)", "\(.id | s) from \(.name | s)"]
    elif .type == "disk" then ["disk", (.free_gb | s)]
    elif .type == "repo_without_team" then ["repo_without_team:\(.name | s)", (.name | s)]
    elif .type == "failed" then ["failed:\(.name | s)", (.name | s)]
    else empty end | @tsv')

# --- the wake lines: one per event, appended to wakes.log -------------------------------------------------------
lines=""
while IFS=$'\t' read -r t team name issue url eid; do
  [ -n "$t" ] || continue
  lines="${lines:+$lines
}fleet tick: $(printf '%s' "$t" | safe) $(printf '%s' "$team" | safe) $(printf '%s' "$name" | safe) $(printf '%s' "$issue" | safe) $(printf '%s' "$url" | safe) $(printf '%s' "$eid" | safe)"
done < <(printf '%s' "$out" | jq -r --arg wake "$WAKE_TYPES" '
  def f($k): (.[$k] // "") | tostring | if . == "" then "-" else . end;
  .[] | '"$WAKE_JQ"'
  | [(.type | tostring), f("team"), f("name"), f("issue"), f("url"), f("id")] | @tsv')
# The same line twice in one tick is written once.
lines="$(printf '%s\n' "$lines" | awk 'NF && !seen[$0]++' | tail -n 500)"
[ -n "$lines" ] || exit 0
n="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"

# --- one wake: the lines go to wakes.log, which keeps at most 500 ----------------------------------------------
[ $(($(wc -l <"$WL" | tr -d ' ') + n)) -le 500 ] || mv -f "$WL" "$WL.1"
(umask 077; printf '%s\n' "$lines" >>"$WL"); chmod 600 "$WL" 2>/dev/null || true
# A registered Orchestrator follows the file, and no reply within 15 minutes alerts (above), a check that reads its
# transcript. With none registered nobody follows it, and with no transcript to read (none recorded, or the file is
# gone) no reply could ever be seen: either way the desktop hears too, so no wake reaches no one.
if [ -n "$(printf '%s' "$orow" | jq -r '.herdr_ref // ""' 2>/dev/null || true)" ] && [ -n "$otr" ] && [ -f "$otr" ]; then
  ls_set --arg w "$now_iso" '.wake_at = (.wake_at // $w)'
else
  notify "Fleet needs you" "$(printf '%s' "$lines" | tr '\n' ';' | cut -c1-300)" request
fi
