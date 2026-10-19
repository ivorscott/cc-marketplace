#!/usr/bin/env bash
# One scheduled tick, run by launchd through the launcher schedule.sh installs, with no model involved:
# tick.sh does the claims, the event log and the classification; this script decides who must hear about it.
#
#   loop-tick.sh
#
# Wake: only judgment events reach the Orchestrator: pr_ready, pr_merged, an escalation of severity P0 or P1,
# dead, claim_takeover, needs_input, brief_failed, and pr_opened when the lead could not be told (tick reports it
# once and never retries, so the Orchestrator must hand it on). Anything else is already in the event log and waits for
# the Orchestrator's next look. A quiet tick prints nothing. One wake per tick, all its events in one message,
# through tell.sh to the Orchestrator's pane (registry row `orchestrator`, else orchestrator_ref in config.toml).
# The wake text is a FIXED TEMPLATE, one line per event:
#   fleet tick: <type> <team> <issue> <PR url> <esc id>
# built from enumerated fields only, each cut to safe characters. An agent's free text (an escalation's
# message, a PR title) is never typed into the Orchestrator's pane; the Orchestrator reads it from the registry.
# No live pane (or herdr down): `notify` and an orchestrator_wake_missed event.
#
# Alerts (notify with alert_cmd), at most once per cause per 4 hours: an escalation P0/P1, a login that expired
# on this Mac (any agent, or the Orchestrator), no Orchestrator reply 15 minutes after a wake, herdr down, and
# 3 failed loop runs in a row. A failed run is never hidden: it is printed (launchd writes it to loop.log),
# counted, and the exit status says so. No acks and no automatic respawn of the Orchestrator.
# State: $FLEET_STATE_DIR/loop.state.json (its own file, so a tick rewriting tick.state.json cannot race it).
# Overlapping runs are excluded by tick.sh's tick lock (slice A), not here.
# FLEET_TICK replaces tick.sh in tests. UNVERIFIED: that herdr reached from a launchd job finds the server.
set -euo pipefail
. "$(dirname "$0")/common.sh"
# launchd is not a herdr pane; tick.sh needs to be told it may talk to herdr.
[ -n "${FLEET_SESSION:-}" ] || export HERDR_ENV=1

mkdir -p "$FLEET_STATE_DIR"
LS="$FLEET_STATE_DIR/loop.state.json"
now_iso="${FLEET_NOW:-$(now)}"; now_epoch="$(jq -rn --arg t "$now_iso" '$t | fromdateiso8601')"
jq -e 'type == "object"' "$LS" >/dev/null 2>&1 || echo '{}' >"$LS"
ls_set() { jq -c "$@" "$LS" >"$LS.new" && mv "$LS.new" "$LS"; } # ls_set <jq args> <program on the state>
trap 'rm -f "$LS.new" "${errf:-}"' EXIT

# alert <cause> <message>: notify with alert_cmd, at most once per cause per 4 hours.
alert() {
  local last
  last="$(jq -r --arg c "$1" '.alerts[$c] // 0' "$LS")"
  [ $((now_epoch - last)) -ge 14400 ] || return 0
  ls_set --arg c "$1" --argjson n "$now_epoch" '.alerts = ((.alerts // {}) + {($c): $n})'
  notify "Fleet needs you" "$2" request alert
}

# --- the tick ---------------------------------------------------------------------------------------
errf="$(mktemp "${TMPDIR:-/tmp}/fleet-loop-err.XXXXXX")"
rc=0; out="$("${FLEET_TICK:-$FLEET_SCRIPTS/tick.sh}" 2>"$errf")" || rc=$?
if [ "$rc" != 0 ]; then
  fails="$(jq -r '(.fails // 0) + 1' "$LS")"
  ls_set --argjson f "$fails" '.fails = $f'
  msg="loop-tick: tick.sh failed (exit $rc): $(tail -n 1 "$errf")"
  printf '%s\n' "$msg" >&2
  [ "$fails" -lt 3 ] || alert loop_failed "fleet loop: $fails failed runs in a row"
  exit 1
fi
cat "$errf" >&2
ls_set --argjson n "$now_epoch" '.fails = 0 | .last_good = $n'
herdr_down=false
if grep -q 'herdr agent list failed' "$errf"; then
  herdr_down=true; alert herdr_down "fleet loop: herdr is not answering; no agent was classified"
fi

# --- login expired: any agent (tick's needs_input) or the Orchestrator itself --------------------------
orow="$("$FLEET_SCRIPTS/registry.sh" get orchestrator 2>/dev/null || echo '{}')"
otr="$(printf '%s' "$orow" | jq -r '.transcript // ""' 2>/dev/null || true)"
if printf '%s' "${out:-[]}" | jq -e 'type == "array" and any(.[]; type == "object" and .type == "needs_input" and .detail == "login expired")' >/dev/null 2>&1 ||
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

[ -n "$out" ] || exit 0
if ! printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
  ls_set '.fails = ((.fails // 0) + 1)'
  printf 'loop-tick: tick.sh printed something that is not an event array\n' >&2; exit 1
fi

# --- alerts for P0/P1, the wake lines -----------------------------------------------------------------------
while IFS= read -r eid; do
  [ -n "$eid" ] || continue
  alert "esc:$eid" "fleet loop: escalation $eid needs you (see the registry)"
done < <(printf '%s' "$out" | jq -r '.[] | select(type == "object" and .type == "escalation" and (.severity | IN("P0", "P1")) and (.id | type == "string")) | .id' | tr -cd 'A-Za-z0-9._:\n-')

safe() { tr -cd 'A-Za-z0-9._:/@#-' | cut -c1-80; }
lines=""; n=0
while IFS=$'\t' read -r t team issue url eid; do
  [ -n "$t" ] || continue
  lines="${lines}fleet tick: $(printf '%s' "$t" | safe) $(printf '%s' "$team" | safe) $(printf '%s' "$issue" | safe) $(printf '%s' "$url" | safe) $(printf '%s' "$eid" | safe)
"
  n=$((n + 1))
done < <(printf '%s' "$out" | jq -r '
  def f($k): (.[$k] // "") | tostring | if . == "" then "-" else . end;
  .[] | select(type == "object")
  | select((.type | IN("pr_ready", "pr_merged", "dead", "claim_takeover", "needs_input", "brief_failed"))
      or (.type == "escalation" and (.severity | IN("P0", "P1")))
      or (.type == "pr_opened" and .lead_told == false))
  | [(.type | tostring), f("team"), f("issue"), f("url"), f("id")] | @tsv')
[ "$n" -gt 0 ] || exit 0

# --- one wake -------------------------------------------------------------------------------------------------
target="$("$FLEET_SCRIPTS/registry.sh" get orchestrator 2>/dev/null | jq -r '.herdr_ref // ""' || true)"
[ -n "$target" ] || target="$(cfg_str orchestrator_ref "")"
if ! $herdr_down && [ -n "$target" ] && "$FLEET_SCRIPTS/tell.sh" "$target" "${lines%$'\n'}" >/dev/null 2>"$errf"; then
  ls_set --arg w "$now_iso" '.wake_at = (.wake_at // $w)'
  exit 0
fi
# No live pane to tell (or herdr is down): a notification instead, and a record that the wake was missed.
notify "Fleet needs you" "$(printf '%s' "${lines%$'\n'}" | tr '\n' ';' | cut -c1-300)" request
ev_log orchestrator_wake_missed team= name=orchestrator detail="$n events; no live Orchestrator pane"
