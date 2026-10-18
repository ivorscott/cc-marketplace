#!/usr/bin/env bash
# Send text to a fleet agent and check that it arrived. A message that did not arrive is a
# failure, never a silent success.
#
#   tell.sh <team/role | herdr agent> <text> [--no-confirm]
#
# Prints {"delivered":true,...} and exits 0 once delivery is seen. Not delivered: prints
# {"delivered":false,"reason":...} and exits 1; the pane is back at its shell or the agent
# is gone: exits 2. --no-confirm only checks that herdr accepted the send (for slash
# commands, which change neither the agent's state nor the transcript).
#
# Delivery is seen when, within tell_confirm_secs (config.toml, default 15), either
#   (a) the agent's status changes to working or blocked, or
#   (b) the first 40 characters of the text show up in the transcript part of
#       `herdr agent read --source recent-unwrapped`. The input box at the bottom (from the
#       second-to-last horizontal rule on) is excluded, so Claude's greyed suggested reply
#       cannot pass for an echoed message.
# Not seen: press enter once and look again; if the text is not on screen, send it again.
# UNVERIFIED against real herdr output: the rule and glyph handling encodes what Claude
# Code's screen is expected to look like (DEV-368).
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr

usage="usage: tell.sh <team/role | herdr agent> <text> [--no-confirm]"
target="${1:?$usage}"; text="${2:?$usage}"; shift 2
confirm=true
while [ $# -gt 0 ]; do
  case "$1" in
    --no-confirm) confirm=false; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

ref="$target"; pane=""
case "$target" in
  */*)
    row="$("$FLEET_SCRIPTS/registry.sh" get "$target")" || exit 1
    ref="$(printf '%s' "$row" | jq -r '.herdr_ref // ""')"; pane="$(printf '%s' "$row" | jq -r '.pane // ""')"
    [ -n "$ref" ] || die "$target has no herdr_ref" ;;
  *) pane="$("$FLEET_SCRIPTS/registry.sh" list | jq -r --arg r "$target" '[.[] | select(.herdr_ref == $r) | .pane // ""] | first // ""')" ;;
esac

verdict() { # verdict <delivered true|false> <reason> <exit code>
  jq -cn --argjson d "$1" --arg r "$2" --arg t "$target" '{delivered: $d, target: $t} + (if $r != "" then {reason: $r} else {} end)'
  exit "$3"
}

agent_state() { hd agent get "$ref" 2>/dev/null | jq -r '.result.agent.agent_status // "gone"' 2>/dev/null || echo gone; }
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
echoed() { transcript "$1" | grep -qF -- "$needle"; }

before_state="$(agent_state)"
seen_before=false; echoed "$(screen)" && seen_before=true

send() { hd agent prompt "$ref" "$text" >/dev/null 2>&1; }
send || { warn "not delivered to $target: herdr agent prompt failed"; verdict false "herdr rejected the send" 1; }
$confirm || verdict true "" 0

secs="$(cfg_int tell_confirm_secs 15)"; poll="${FLEET_TELL_POLL:-1}"
arrived() { # the state changed to working/blocked, or the text is newly in the transcript
  local s; s="$(agent_state)"
  case "$s" in working | blocked) [ "$before_state" = "$s" ] || return 0 ;; esac
  $seen_before || ! echoed "$(screen)" || return 0
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
