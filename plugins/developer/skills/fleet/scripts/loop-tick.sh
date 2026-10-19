#!/usr/bin/env bash
# One scheduled tick, run by launchd through the launcher schedule.sh installs, with no model involved:
# tick.sh does the claims, the event log and the classification; this script decides who must hear about it.
#
#   loop-tick.sh
#
# Wake: every event someone must act on reaches the Orchestrator: pr_ready, pr_merged, any escalation (P0/P1
# for Ivor, P2 the Orchestrator answers itself), dead, stalled (after the nudge), claim_takeover, needs_input,
# brief_failed, weekly_summary (the Orchestrator writes the metrics report), and pr_opened when the lead could
# not be told. disk and repo_without_team go to notify/alert_cmd instead. Nothing is reported to no one.
# A quiet tick prints nothing. One wake per tick, all its lines in one message, through tell.sh to the target:
# orchestrator_ref in config.toml, else the `orchestrator` row (registry.sh orchestrator here) if its pane is
# in `herdr agent list`. The wake text is a FIXED TEMPLATE, one line per event:
#   fleet tick: <type> <team> <name> <issue> <PR url> <esc id>
# built from enumerated fields only, each cut to safe characters. An agent's free text (an escalation's
# message, a PR title) is never typed into the Orchestrator's pane; the Orchestrator reads it from the registry.
# A wake that is not delivered (no target, pane gone, herdr down, tell.sh failed) stays queued in the loop
# state and is sent again, with any new lines, on the next run; each miss is a notify and an
# orchestrator_wake_missed event with the reason, and the third miss in a row is an alert (wake_undelivered).
#
# Alerts (notify with alert_cmd), at most once per cause per 4 hours: an escalation P0/P1 (per agent and id),
# a login that expired on this Mac (any agent, or the Orchestrator), no Orchestrator reply 15 minutes after a
# wake, herdr down, low disk, a repo with no team, 3 failed loop runs in a row, no good tick within 2x
# tick_secs, and a wake undelivered 3 times. A good tick is one that ran tick.sh and got an event array (or
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

# alert <cause> <message>: notify with alert_cmd, at most once per cause per 4 hours.
alert() {
  local last
  last="$(jq -r --arg c "$1" '.alerts[$c] // 0' "$LS")"
  [ $((now_epoch - last)) -ge 14400 ] || return 0
  ls_set --arg c "$1" --argjson n "$now_epoch" '.alerts = ((.alerts // {}) + {($c): $n})'
  notify "Fleet needs you" "$2" request alert
}

# Alerts older than 4 hours no longer suppress anything, so they are dropped (the state stays bounded).
ls_set --argjson n "$now_epoch" '.alerts = ((.alerts // {}) | with_entries(select(.value > $n - 14400))) | .since = (.since // $n)'

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
  [ "$fails" -lt 3 ] || alert loop_failed "fleet loop: $fails failed runs in a row"
  secs="$(cfg_int tick_secs 300)"; lg="$(jq -r '.last_good // .since // 0' "$LS")"
  [ $((now_epoch - lg)) -le $((2 * secs)) ] || alert loop_unhealthy "fleet loop: no good tick in $(((now_epoch - lg) / 60)) min"
  exit 1
fi
ls_set --argjson n "$now_epoch" '.fails = 0 | .last_good = $n'
herdr_down=false
if grep -q 'herdr agent list failed' "$errf"; then
  herdr_down=true; alert herdr_down "fleet loop: herdr is not answering; no agent was classified"
fi
[ -n "$out" ] || out='[]'

# --- login expired: any agent (tick's needs_input) or the Orchestrator itself --------------------------
orow="$("$FLEET_SCRIPTS/registry.sh" get orchestrator 2>/dev/null || echo '{}')"
otr="$(printf '%s' "$orow" | jq -r '.transcript // ""' 2>/dev/null || true)"
if printf '%s' "$out" | jq -e 'any(.[]; type == "object" and .type == "needs_input" and .detail == "login expired")' >/dev/null 2>&1 ||
  [ "$(api_error_detail "$otr")" = "login expired" ]; then
  alert login_expired "fleet loop: a login has expired on this Mac; run /login"
fi

# --- no reply to the last wake --------------------------------------------------------------------------
wake_at="$(jq -r '.wake_at // ""' "$LS")"
if [ -n "$wake_at" ] && [ -n "$otr" ] && [ -f "$otr" ]; then
  if tail -n 200 "$otr" | jq -Rre --arg w "$wake_at" 'fromjson? // empty | select(type == "object" and .type == "assistant" and (.timestamp | type == "string") and .timestamp > $w) | 1' >/dev/null 2>&1; then
    ls_set 'del(.wake_at)'
  elif [ $((now_epoch - $(jq -rn --arg t "$wake_at" '$t | fromdateiso8601'))) -ge 900 ]; then
    alert no_reply "fleet loop: the Orchestrator has not answered a wake for 15 minutes"
  fi
fi

# --- alerts: P0/P1, low disk, a repo with no team -------------------------------------------------------------
safe() { tr -cd 'A-Za-z0-9._:/@#-' | cut -c1-80; }
while IFS=$'\t' read -r cause what; do
  [ -n "$cause" ] || continue
  cause="$(printf '%s' "$cause" | safe)" # what is cut to safe characters per field in jq below
  case "$cause" in
    esc:*) alert "$cause" "fleet loop: escalation $what needs you (see the registry)" ;;
    disk) alert disk "fleet loop: free disk is low ($what GB)" ;;
    repo_without_team:*) alert "$cause" "fleet loop: repo $what has no team" ;;
  esac
done < <(printf '%s' "$out" | jq -r 'def s: (. // "-") | tostring | gsub("[^A-Za-z0-9._:/@#-]"; "") | .[0:80];
  .[] | select(type == "object")
  | if .type == "escalation" and (.severity | IN("P0", "P1")) and (.id | type == "string") then ["esc:\(.name | s):\(.id | s)", "\(.id | s) from \(.name | s)"]
    elif .type == "disk" then ["disk", (.free_gb | s)]
    elif .type == "repo_without_team" then ["repo_without_team:\(.name | s)", (.name | s)]
    else empty end | @tsv')

# --- the wake lines: queued ones first, then this tick's --------------------------------------------------
lines="$(jq -r '(.pending // [])[] | strings' "$LS")"
while IFS=$'\t' read -r t team name issue url eid; do
  [ -n "$t" ] || continue
  lines="${lines:+$lines
}fleet tick: $(printf '%s' "$t" | safe) $(printf '%s' "$team" | safe) $(printf '%s' "$name" | safe) $(printf '%s' "$issue" | safe) $(printf '%s' "$url" | safe) $(printf '%s' "$eid" | safe)"
done < <(printf '%s' "$out" | jq -r '
  def f($k): (.[$k] // "") | tostring | if . == "" then "-" else . end;
  .[] | select(type == "object")
  | select((.type | IN("pr_ready", "pr_merged", "dead", "failed", "stalled", "claim_takeover", "needs_input", "brief_failed", "weekly_summary"))
      or (.type == "escalation" and (.severity | IN("P0", "P1", "P2")))
      or (.type == "pr_opened" and .lead_told == false))
  | [(.type | tostring), f("team"), f("name"), f("issue"), f("url"), f("id")] | @tsv')
# The same line twice (a requeued line the tick reports again) is sent once; the queue keeps the last 50.
lines="$(printf '%s\n' "$lines" | awk 'NF && !seen[$0]++' | tail -n 50)"
[ -n "$lines" ] || exit 0
n="$(printf '%s\n' "$lines" | wc -l | tr -d ' ')"

# --- one wake -------------------------------------------------------------------------------------------------
target="$(cfg_str orchestrator_ref "")"; miss=""
if [ -z "$target" ]; then
  oref="$(printf '%s' "$orow" | jq -r '.herdr_ref // ""' 2>/dev/null || true)"
  opane="$(printf '%s' "$orow" | jq -r '.pane // ""' 2>/dev/null || true)"
  if [ -z "$oref" ]; then miss="no orchestrator registered"
  elif $herdr_down; then miss="herdr is down"
  elif hd agent list 2>/dev/null | jq -e --arg p "$opane" --arg r "$oref" 'any(.result.agents[]?; .pane_id == $p or .name == $r)' >/dev/null 2>&1; then target="$oref"
  else miss="orchestrator pane gone"; fi
elif $herdr_down; then miss="herdr is down"
fi
if [ -z "$miss" ]; then
  if "$FLEET_SCRIPTS/tell.sh" "$target" "$lines" >/dev/null 2>"$errf"; then
    ls_set --arg w "$now_iso" '.wake_at = (.wake_at // $w) | del(.pending, .wake_misses)'
    exit 0
  fi
  miss="wake not delivered"
fi
# Not delivered: keep the lines for the next run, tell Ivor's desktop, and record the miss with its reason.
misses="$(jq -r '(.wake_misses // 0) + 1' "$LS")"
ls_set --argjson m "$misses" --arg l "$lines" '.pending = ($l | split("\n") | map(select(. != ""))) | .wake_misses = $m'
notify "Fleet needs you" "$(printf '%s' "$lines" | tr '\n' ';' | cut -c1-300)" request
ev_log orchestrator_wake_missed team= name=orchestrator detail="$n events; $miss"
[ "$misses" -lt 3 ] || alert wake_undelivered "fleet loop: $n fleet events have not reached the Orchestrator ($miss); run registry.sh orchestrator here in its pane"
