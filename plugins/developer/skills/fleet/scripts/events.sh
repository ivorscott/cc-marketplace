#!/usr/bin/env bash
# The herdr event subscriber: the fast path for two wakes, with tick.sh staying the fallback.
#
#   events.sh run       subscribe to herdr's event socket and write wakes until stopped (the launchd job's command)
#   events.sh feed      read event lines on stdin, as `run` would, then exit (tests, and a replay of a captured stream)
#   events.sh status    one line: whether the subscriber is up, from events.alive
#
# herdr 0.9.1 offers `events.subscribe` only on its unix socket (no CLI verb), so `run` talks to it with `nc -U`
# (no new dependency). It subscribes to pane.exited and pane.agent_status_changed and reads one JSON object per line:
#   pane.exited                 on a row that is not Retired, Parked or the Orchestrator: wake `dead` at once
#   pane.agent_status_changed   to blocked: wake `input_pending` (the existing wake type); any other state forgets it
# Stalled and every other event stay tick's. The wake is the same fixed template loop-tick.sh writes, appended with the
# same helpers (wake_append, wake_line in common.sh):
#   fleet tick: <type> <team> <name> <issue> <PR url> <esc id>
# Nothing from the event is ever written to wakes.log except enumerated fields from the registry row, cut to safe
# characters. The first line after subscribing is the acknowledgement; any later line that is not one of the two events
# (the events_lost frame, junk) and an EOF all count as events_lost: resubscribe with a capped backoff, then reconcile
# with `herdr api snapshot` (a pane gone or blocked on a live row gets the same wake, once).
# Dedupe with tick: each wake is recorded in $FLEET_STATE_DIR/events.seen.json; when the subscriber is alive,
# loop-tick.sh drops tick's own dead or input_pending line for an agent recorded there. The subscriber touches
# $FLEET_STATE_DIR/events.alive on every event and every 30 seconds; older than 2 minutes (or absent) means down, and tick
# writes every wake itself, as before.
# Overrides: FLEET_HERDR_SOCK (default ~/.config/herdr/herdr.sock), FLEET_NC (nc), FLEET_EVENTS_ONCE=1 (one connection
# cycle, no backoff sleep: tests), FLEET_NOW (the clock).
# UNVERIFIED until run against a real herdr: the frame shapes (event name and pane fields are read from several likely
# keys), the events_lost frame, the socket path of a named session, and launchd KeepAlive (schedule.sh install).
# Command: Check the herdr event subscriber · e.g. fleet events status
set -euo pipefail
. "$(dirname "$0")/common.sh"

ALIVE="$FLEET_STATE_DIR/events.alive"
SEEN="$FLEET_STATE_DIR/events.seen.json"
SOCK="${FLEET_HERDR_SOCK:-$HOME/.config/herdr/herdr.sock}"
NC="${FLEET_NC:-nc}"
SEEN_TTL=3600
mkdir -p "$FLEET_STATE_DIR"

epoch() { jq -rn --arg t "${FLEET_NOW:-$(now)}" '$t | fromdateiso8601'; }
beat() { : >"$ALIVE"; }

# seen_has <name> <type> <pane>: this wake already went out for this pane (and was not taken by tick yet).
seen_has() { [ -f "$SEEN" ] && [ "$(jq -r --arg k "$1|$2" --arg p "$3" '(.[$k] // {}).pane == $p' "$SEEN" 2>/dev/null)" = true ]; }
seen_set() { # <name> <type> <pane>
  local cur='{}'; [ ! -f "$SEEN" ] || cur="$(cat "$SEEN")"
  printf '%s' "$cur" | jq -c --arg k "$1|$2" --arg p "$3" --argjson n "$(epoch)" --argjson ttl "$SEEN_TTL" \
    'with_entries(select(.value.at > $n - $ttl)) + {($k): {pane: $p, at: $n}}' >"$SEEN.$$.new" && mv "$SEEN.$$.new" "$SEEN"
}
seen_clear() { # <name> <type>
  [ -f "$SEEN" ] || return 0
  jq -c --arg k "$1|$2" 'del(.[$k])' "$SEEN" >"$SEEN.$$.new" && mv "$SEEN.$$.new" "$SEEN"
}

# row_for_pane <pane id>: the one live, non-Orchestrator row on that pane, as "team<TAB>name", else nothing.
row_for_pane() {
  "$FLEET_SCRIPTS/registry.sh" list 2>/dev/null | jq -r --arg p "$1" '[.[] | select((.pane // "") == $p and .tier != "Orchestrator"
    and .status != "Retired" and .status != "Parked")] | first // empty | [(.team // "-"), .name] | @tsv'
}

# wake <type> <team> <name> <pane>: once per (agent, type, pane) until tick takes it or the state is cleared.
wake() {
  seen_has "$3" "$1" "$4" && return 0
  wake_append "$(wake_line "$1" "$2" "$3" - - -)"
  seen_set "$3" "$1" "$4"
}

# handle <line>: 0 handled, 2 events_lost (anything that is not the acknowledgement or one of the two events).
acked=0
handle() {
  local kind pane st team name parsed
  parsed="$(printf '%s' "$1" | jq -r '
    if type != "object" then "lost\t\t"
    else (.event // .type // .method // "") as $e
      | ((.data // .params // .result // .) | if type == "object" then . else {} end) as $d
      | ($d.pane_id // $d.pane // .pane_id // "") as $p
      | ($d.agent_status // $d.status // $d.state // .agent_status // "") as $s
      | if $e == "pane.exited" or $e == "pane.agent_status_changed" then [$e, ($p | tostring), ($s | tostring)]
        elif $e == "" and (has("result") or has("id")) then ["ack", "", ""]
        else ["lost", "", ""] end | @tsv end' 2>/dev/null)" || parsed=$'lost\t\t'
  IFS=$'\t' read -r kind pane st <<<"$parsed"
  case "$kind" in
    ack) if [ "$acked" = 0 ]; then acked=1; return 0; fi; return 2 ;;
    pane.exited | pane.agent_status_changed)
      beat
      [ -n "$pane" ] || return 0
      IFS=$'\t' read -r team name <<<"$(row_for_pane "$pane")"
      [ -n "${name:-}" ] || return 0
      if [ "$kind" = pane.exited ]; then wake dead "$team" "$name" "$pane"
      elif [ "$st" = blocked ]; then wake input_pending "$team" "$name" "$pane"
      else seen_clear "$name" input_pending; fi
      return 0 ;;
    *) return 2 ;;
  esac
}

# reconcile: after events_lost, one `herdr api snapshot` against the registry. A live row whose pane is gone (the snapshot
# lists panes and this one is not among them) or blocked gets the same wake as an event would have given it, once.
# A snapshot with no pane records at all is not trusted (no mass deaths from a shape this does not know).
reconcile() {
  local snap rows team name pane gone blocked
  snap="$(hd api snapshot 2>/dev/null)" || return 0
  [ "$(printf '%s' "$snap" | jq '[.. | objects | select(has("pane_id"))] | length' 2>/dev/null || echo 0)" != 0 ] || return 0
  while IFS=$'\t' read -r team name pane gone blocked; do
    [ -n "$name" ] || continue
    if [ "$gone" = true ]; then wake dead "$team" "$name" "$pane"
    elif [ "$blocked" = true ]; then wake input_pending "$team" "$name" "$pane"; fi
  done < <(jq -rn --slurpfile s <(printf '%s' "$snap") --slurpfile r <("$FLEET_SCRIPTS/registry.sh" list 2>/dev/null) '
    [$s[0] | .. | objects | select(has("pane_id")) | {id: (.pane_id | tostring), st: (.agent_status // "")}] as $panes
    | $r[0][] | select((.pane // "") != "" and .tier != "Orchestrator" and .status != "Retired" and .status != "Parked")
    | .pane as $p | ([$panes[] | select(.id == $p)] | first) as $m
    | [(.team // "-"), .name, $p, ($m == null | tostring), (($m.st // "") == "blocked" | tostring)] | @tsv')
}

# pump: read lines from fd 3 until EOF or a lost frame; every 30 seconds without a line only refreshes events.alive.
pump() {
  local line rc
  acked=0; beat
  while :; do
    if IFS= read -r -t 30 -u 3 line; then
      rc=0; handle "$line" || rc=$?
      [ "$rc" != 2 ] || return 2
    else
      [ $? -gt 128 ] || return 2 # EOF
      beat
    fi
  done
}

case "${1:-}" in
  feed)
    exec 3<&0; beat
    pump || { reconcile; exit 0; }
    ;;
  run)
    command -v "$NC" >/dev/null 2>&1 || { warn "nc is not installed, so the event subscriber cannot run; tick polling still catches dead and blocked agents"; exit 1; }
    sub='{"id":"fleet","method":"events.subscribe","params":{"subscriptions":[{"type":"pane.exited"},{"type":"pane.agent_status_changed"}]}}'
    delay=1
    while :; do
      if [ -S "$SOCK" ] || [ -n "${FLEET_NC:-}" ]; then
        # nc reads its requests from a fifo this script keeps open (nc stops when its stdin ends) and writes events to fd 3.
        # nc is exec'd by the process substitution, so it is the only other holder of fd 3 and EOF is its exit.
        fifo="$(mktemp -u "${TMPDIR:-/tmp}/fleet-events.XXXXXX")"; mkfifo "$fifo"
        exec 3< <(exec "$NC" -U "$SOCK" <"$fifo" 2>/dev/null)
        exec 5>"$fifo"; printf '%s\n' "$sub" >&5
        pump && true
        exec 3<&- 5>&-; rm -f "$fifo"; pkill -P $$ 2>/dev/null || true
        reconcile # events_lost, an EOF or a server restart: one snapshot, wakes deduped
        delay=1
      fi
      [ -z "${FLEET_EVENTS_ONCE:-}" ] || exit 0
      sleep "$delay"; delay=$((delay * 2 > 60 ? 60 : delay * 2))
    done
    ;;
  status)
    if ! command -v "$NC" >/dev/null 2>&1; then echo "Event subscriber: down (nc is not installed; tick polls)."; exit 0; fi
    if events_alive "$(epoch)"; then echo "Event subscriber: up."
    elif [ -f "$ALIVE" ]; then echo "Event subscriber: down (events.alive is stale; tick polls). Run fleet schedule install."
    else echo "Event subscriber: not running (tick polls). Run fleet schedule install."; fi
    ;;
  *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
