#!/usr/bin/env bash
# Send text to a fleet agent and check that it arrived. A message that did not arrive is a
# failure, never a silent success.
#
#   tell.sh <team/role | herdr agent> <text> [--no-confirm] [--brief]
#   --brief marks the text as a brief: the outcome is logged as brief_delivered / brief_failed in
#   the event log (the text itself never is).
#
# Prints {"delivered":true,...} and exits 0 once delivery is seen. Not delivered: prints
# {"delivered":false,"reason":...} and exits 1; the pane is back at its shell or the agent
# is gone: exits 2. --no-confirm only checks that herdr accepted the send (for slash
# commands, which change neither the agent's state nor the transcript).
#
# Delivery is seen when, within tell_confirm_secs (a constant, 15 seconds; FLEET_TELL_CONFIRM_SECS in tests), the first of these
# shows up (structured signals first, screen text last):
#   (a) the agent's Claude Code transcript (the row's `transcript` file) gains a line after the
#       send with type "user" whose string .message.content starts with the first 40 characters
#       of the text;
#   (b) herdr `agent get` shows .state_change_seq increased, or agent_status went to working or
#       blocked;
#   (c) fallback: the first 40 characters appear in the transcript part of
#       `herdr agent read --source recent-unwrapped`. The input box at the bottom (from the
#       second-to-last horizontal rule on) is excluded, so Claude's greyed suggested reply
#       cannot pass for an echoed message.
# Not seen: press enter once and look again; if the text is not on screen, send it again.
# UNVERIFIED: state_change_seq and revision are observed in `agent get` JSON, not documented by
# herdr (`herdr --skill`), so they are a signal, not a contract; the transcript format may change
# between Claude Code versions; the screen handling encodes what Claude Code's screen is expected
# to look like (DEV-368).
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr

usage="usage: tell.sh <team/role | herdr agent> <text> [--no-confirm] [--brief]"
target="${1:?$usage}"; text="${2:?$usage}"; shift 2
confirm=true; is_brief=false
while [ $# -gt 0 ]; do
  case "$1" in
    --no-confirm) confirm=false; shift ;;
    --brief) is_brief=true; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

ref="$target"; pane=""; transcript=""
case "$target" in
  */*)
    row="$("$FLEET_SCRIPTS/registry.sh" get "$target")" || exit 1
    ref="$(printf '%s' "$row" | jq -r '.herdr_ref // ""')"; pane="$(printf '%s' "$row" | jq -r '.pane // ""')"
    transcript="$(printf '%s' "$row" | jq -r '.transcript // ""')"
    [ -n "$ref" ] || die "$target has no herdr_ref" ;;
  *) r="$("$FLEET_SCRIPTS/registry.sh" list | jq -c --arg r "$target" '[.[] | select(.herdr_ref == $r)] | first // {}')"
     pane="$(printf '%s' "$r" | jq -r '.pane // ""')"; transcript="$(printf '%s' "$r" | jq -r '.transcript // ""')" ;;
esac

verdict() { # verdict <delivered true|false> <reason> <exit code>
  if $is_brief; then
    ev_log "$([ "$1" = true ] && echo brief_delivered || echo brief_failed)" team="${target%%/*}" name="$target" detail="$2"
  fi
  jq -cn --argjson d "$1" --arg r "$2" --arg t "$target" '{delivered: $d, target: $t} + (if $r != "" then {reason: $r} else {} end)'
  exit "$3"
}

agent_state() { hd agent get "$ref" 2>/dev/null | jq -r '.result.agent.agent_status // "gone"' 2>/dev/null || echo gone; }
agent_seq() { hd agent get "$ref" 2>/dev/null | jq -r '.result.agent.state_change_seq // ""' 2>/dev/null || true; }
[ "$(agent_state)" != "gone" ] || { warn "not delivered to $target: agent not found in herdr"; verdict false "agent not found" 2; }
if [ -n "$pane" ] && ! hd pane process-info --pane "$pane" 2>/dev/null |
  jq -e '.result.process_info | .foreground_process_group_id != .shell_pid' >/dev/null 2>&1; then
  warn "not delivered to $target: pane is a shell"; verdict false "pane is a shell" 2
fi

# transcript <screen>: the screen without its input box.
transcript() {
  printf '%s\n' "$1" | awk '
    { line[NR] = $0; if ($0 ~ /^[[:space:]]*(─|╭|╰|└|┌)/) rule[++n] = NR }
    END {
      stop = NR
      if (n >= 2) stop = rule[n - 1] - 1
      else if (n == 1) stop = rule[1] - 1
      for (i = 1; i <= stop; i++) if (n > 0 || line[i] !~ /^[[:space:]]*(❯|│)/) print line[i]
    }'
}
screen() { hd agent read "$ref" --source recent-unwrapped 2>/dev/null | tail -n 60 || true; }
needle="$(printf '%s' "$text" | head -1 | cut -c1-40)"
# An empty (or all-space) needle can't be told apart on screen: then only (a) and (b) count.
[ -n "${needle//[[:space:]]/}" ] || needle=""
# The screen signal (c) is about text that appears AFTER the send: more copies of the needle in the
# transcript region than before, or the region's last lines changed and now hold it. So a text sent
# twice can still confirm, and a copy already on screen cannot.
echo_count() { if [ -z "$needle" ]; then echo 0; else transcript "$1" | grep -cF -- "$needle" || true; fi; }
echo_tail() { transcript "$1" | tail -n 3; }
echoed_new() { # echoed_new <screen>
  [ -n "$needle" ] || return 1
  [ "$(echo_count "$1")" -gt "$n0" ] && return 0
  [ "$(echo_tail "$1")" != "$tail0" ] && echo_tail "$1" | grep -qF -- "$needle"
}

before_state="$(agent_state)"; before_seq="$(agent_seq)"
needle40="$(jq -rn --arg t "$text" '$t[0:40]')"
lines0=0; [ -r "$transcript" ] && lines0="$(wc -l <"$transcript" | tr -d ' ')"
before_screen="$(screen)"; n0="$(echo_count "$before_screen")"; tail0="$(echo_tail "$before_screen")"

send() { hd agent prompt "$ref" "$text" >/dev/null 2>&1; }
send || { warn "not delivered to $target: herdr agent prompt failed"; verdict false "herdr rejected the send" 1; }
$confirm || verdict true "" 0

secs="$(const_int tell_confirm_secs 15)"; poll="${FLEET_TELL_POLL:-1}"
arrived() { # structured signals first: transcript user line, herdr state; then the screen
  local s q
  if [ -n "$transcript" ] && [ -r "$transcript" ] &&
    tail -n +$((lines0 + 1)) "$transcript" 2>/dev/null | jq -e --arg n "$needle40" \
      'select(.type == "user" and (.message.content | type == "string") and (.message.content | startswith($n)))' >/dev/null 2>&1; then
    return 0
  fi
  s="$(agent_state)"; q="$(agent_seq)"
  case "$s" in working | blocked) [ "$before_state" = "$s" ] || return 0 ;; esac
  case "$before_seq" in "" | *[!0-9]*) ;; *) case "$q" in "" | *[!0-9]*) ;; *) [ "$q" -gt "$before_seq" ] && return 0 ;; esac ;; esac
  ! echoed_new "$(screen)" || return 0
  return 1
}
wait_for() { # wait_for <polls>
  local t=0
  while :; do
    arrived && return 0
    [ "$t" -ge "$1" ] && return 1
    sleep "$poll"; t=$((t + 1))
  done
}

if wait_for "$secs"; then verdict true "" 0; fi
# Retry once: the text may be sitting in the box unsent.
hd agent send-keys "$ref" enter >/dev/null 2>&1 || true
if wait_for "$((secs / 3 + 1))"; then verdict true "" 0; fi
if ! screen | grep -qF -- "$needle"; then send || true; fi
if wait_for "$secs"; then verdict true "" 0; fi
warn "not delivered to $target: no state change and no echo after ${secs}s plus one retry"
verdict false "no confirmation after retry" 1
