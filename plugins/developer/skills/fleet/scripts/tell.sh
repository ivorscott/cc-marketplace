#!/usr/bin/env bash
# Send text to a fleet agent and check that it arrived. A message that did not arrive is a
# failure, never a silent success.
#
#   tell.sh <team/role | herdr agent> <text> [--no-confirm] [--brief]
#   tell.sh <team/role> - --brief-file PATH
#
# --brief sends the text as a FILE: it is written to $FLEET_STATE_DIR/briefs/<team>/<role>/<id>.md (mode 600)
# and the agent gets one pointer line, "Read your brief: <path> (id <id>)", so a long brief is never pasted
# into a prompt. tell waits for the agent to be idle first (brief_idle_secs, default 60) and fails without
# sending when it is not. A brief counts as delivered ONLY when the agent's transcript shows the id after the
# send, as a user line or a queued_command attachment; a state change does not count, except for a row with no
# transcript (another harness), where it is all there is. The row's last_brief records the file. --brief-file re-sends the pointer to an
# existing brief (tick does it once for a Failed row). The outcome is logged as brief_delivered /
# brief_failed in the event log (the brief text never is). UNVERIFIED: the queued_command attachment shape.
#
# Prints `Told <team/role>: "<first 60 characters>" (delivered)` and exits 0 once delivery is seen, or "(queued)" for
# a message to an agent busy in a long turn: it was working at the send and still is after the wait, and herdr took
# the text, which Claude Code holds as a queued message until the turn ends (no enter is pressed). Not delivered:
# the error form on stderr, "tell: not delivered to <target>: <why>. <next step>.", and exit 1; the pane is back at
# its shell or the agent is gone: exit 2. --no-confirm only checks that herdr accepted the send (for slash commands,
# which change neither the agent's state nor the transcript), and the line ends "(sent)".
#
# Delivery is seen when, within the tell confirm wait (15s), the first of these shows up:
#   (a) the agent's Claude Code transcript (the row's `transcript` file) gains a line after the
#       send with type "user" whose string .message.content starts with the first 40 characters
#       of the text, or a queued_command attachment whose prompt does;
#   (b) herdr `agent get` shows .state_change_seq increased, or agent_status went to working or
#       blocked. herdr's Claude integration (its hooks) gives these; boot and status say when it is
#       not current.
# The screen is never read. Not seen: press enter once (the text may sit in the box unsent) and look again.
# UNVERIFIED: state_change_seq is observed in `agent get` JSON, not documented by herdr (`herdr --skill`),
# so it is a signal, not a contract; the transcript format may change between Claude Code versions.
# Command: Send a team's lead (or one agent) a message and check it arrived · e.g. fleet tell build-api/lead "focus on token expiry"
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr

usage="usage: tell.sh <team/role | herdr agent> <text> [--no-confirm] [--brief | --brief-file PATH]"
target="${1:?$usage}"; text="${2:?$usage}"; shift 2
confirm=true; is_brief=false; brief_file=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-confirm) confirm=false; shift ;;
    --brief) is_brief=true; shift ;;
    --brief-file) is_brief=true; brief_file="${2:?--brief-file needs a path}"; shift 2 ;;
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

# --- a brief goes as a file: written first, so last_brief names THIS brief even when an early exit follows ---
if $is_brief; then
  case "$target" in */*) bteam="${target%%/*}"; brole="${target#*/}" ;; *) bteam=agent; brole="$target" ;; esac
  bteam="$(printf '%s' "$bteam" | tr -c 'A-Za-z0-9_.-' '_')"; brole="$(printf '%s' "$brole" | tr -c 'A-Za-z0-9_.-' '_')"
  if [ -n "$brief_file" ]; then
    [ -f "$brief_file" ] || die "no brief file $brief_file"
    bid="$(basename "$brief_file" .md)"
  else
    bid="b$(date -u +%Y%m%d%H%M%S)$$$RANDOM"
    bdir="$FLEET_STATE_DIR/briefs/$bteam/$brole"
    (umask 077; mkdir -p "$bdir" && printf '%s\n' "$text" >"$bdir/$bid.md") || die "cannot write the brief file in $bdir"
    chmod 600 "$bdir/$bid.md"; brief_file="$bdir/$bid.md"
  fi
  case "$target" in */*) "$FLEET_SCRIPTS/registry.sh" set "$target" last_brief="$brief_file" >/dev/null 2>&1 || true ;; esac
  text="Read your brief: $brief_file (id $bid)"
fi

verdict() { # verdict <delivered true|false> <reason> <exit code>
  if $is_brief; then
    ev_log "$([ "$1" = true ] && echo brief_delivered || echo brief_failed)" team="${target%%/*}" name="$target" detail="$2"
    # brief_failed_at (with the row's issue then) marks the row for tick's one re-send of this brief's pointer;
    # a delivered brief clears it, and a Failed row comes back as the restart intended: a lead Working, a
    # worker Idle (waiting for the lead).
    case "$target" in */*)
      brow="$("$FLEET_SCRIPTS/registry.sh" get "$target" 2>/dev/null || echo '{}')"
      if [ "$1" = true ]; then
        if [ "$(printf '%s' "$brow" | jq -r '.status // ""')" = Failed ]; then
          "$FLEET_SCRIPTS/registry.sh" set "$target" brief_failed_at= brief_failed_issue= brief_failed_line= brief_resent= \
            status="$([ "$(printf '%s' "$brow" | jq -r '.tier // ""')" = Lead ] && echo Working || echo Idle)" >/dev/null 2>&1 || true
        else "$FLEET_SCRIPTS/registry.sh" set "$target" brief_failed_at= brief_failed_issue= brief_failed_line= >/dev/null 2>&1 || true; fi
      # brief_failed_line: the transcript's length at the send, so a pointer that shows up later (status.sh) is this
      # send's and not an earlier delivery of the same brief.
      else "$FLEET_SCRIPTS/registry.sh" set "$target" brief_failed_at="$(now)" brief_failed_issue="$(printf '%s' "$brow" | jq -r '.issue // ""')" \
        brief_failed_line="${lines0:-0}" >/dev/null 2>&1 || true; fi ;;
    esac
  fi
  if [ "$1" = true ]; then
    render_line told name="$target" text="$(jq -rn --arg t "$text" '$t | split("\n")[0] | .[0:60]')" how="${how:-$($confirm && echo delivered || echo sent)}"
  elif [ "$3" = 2 ]; then render_error tell "not delivered to $target: $2" "Respawn it (fleet respawn $target) or retire it" >&2
  else render_error tell "not delivered to $target: $2" "Look at its pane, then send it again" >&2; fi
  exit "$3"
}

agent_state() { hd agent get "$ref" 2>/dev/null | jq -r '.result.agent.agent_status // "gone"' 2>/dev/null || echo gone; }
agent_seq() { hd agent get "$ref" 2>/dev/null | jq -r '.result.agent.state_change_seq // ""' 2>/dev/null || true; }
[ "$(agent_state)" != "gone" ] || verdict false "agent not found in herdr" 2
if [ -n "$pane" ] && ! hd pane process-info --pane "$pane" 2>/dev/null |
  jq -e '.result.process_info | .foreground_process_group_id != .shell_pid' >/dev/null 2>&1; then
  verdict false "its pane is back at the shell" 2
fi

# --- a brief waits for idle -------------------------------------------------------------------------------
if $is_brief; then
  # Wait for idle: typing into a busy agent queues the line behind its turn, or loses it.
  idle_secs="$(cfg_int brief_idle_secs 60)"; poll="${FLEET_TELL_POLL:-1}"; w=0
  until case "$(agent_state)" in idle | done) true ;; *) false ;; esac; do
    if [ "$w" -ge "$idle_secs" ]; then verdict false "not idle after ${idle_secs}s" 1; fi
    sleep "$poll"; w=$((w + 1))
  done
fi
before_state="$(agent_state)"; before_seq="$(agent_seq)"
needle40="$(jq -rn --arg t "$text" '$t[0:40]')"
lines0=0; [ -r "$transcript" ] && lines0="$(wc -l <"$transcript" | tr -d ' ')"

send() { hd agent prompt "$ref" "$text" >/dev/null 2>&1; }
send || verdict false "herdr rejected the send" 1
$confirm || verdict true "" 0

secs="$(const_int TELL_CONFIRM_SECS 15)"; poll="${FLEET_TELL_POLL:-1}"
# state_moved: herdr's state moved since the send: agent_status went to working or blocked, or state_change_seq rose.
state_moved() {
  local s q
  s="$(agent_state)"; q="$(agent_seq)"
  case "$s" in working | blocked) [ "$before_state" = "$s" ] || return 0 ;; esac
  case "$before_seq" in "" | *[!0-9]*) ;; *) case "$q" in "" | *[!0-9]*) ;; *) [ "$q" -gt "$before_seq" ] && return 0 ;; esac ;; esac
  return 1
}
# brief_seen: the brief's id in the transcript after the send (a user line or a queued_command attachment); a row
# with no transcript known has only the state to go by. Nothing else confirms a brief.
brief_seen() {
  if [ -n "$transcript" ]; then brief_in_transcript "$transcript" "$bid" $((lines0 + 1)); else state_moved; fi
}
arrived() { # the transcript's user line, then herdr's state; never the screen
  if $is_brief; then brief_seen; return; fi
  if [ -n "$transcript" ] && [ -r "$transcript" ] &&
    tail -n +$((lines0 + 1)) "$transcript" 2>/dev/null | jq -e --arg n "$needle40" \
      'select((.type == "user" and (.message.content | type == "string") and (.message.content | startswith($n)))
        or ((.attachment.type? // "") == "queued_command" and ((.attachment.prompt? // "") | tostring | startswith($n))))' >/dev/null 2>&1; then
    return 0
  fi
  state_moved
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
# Working at the send and still working: Claude Code queued the text behind the turn it is in. That is delivery, and
# an enter now would only go into its input line.
if ! $is_brief && [ "$before_state" = working ] && [ "$(agent_state)" = working ]; then how=queued; verdict true "" 0; fi
# Press enter once: the text may be sitting in the box unsent.
hd agent send-keys "$ref" enter >/dev/null 2>&1 || true
if wait_for "$((secs / 3 + 1))"; then verdict true "" 0; fi
verdict false "no transcript line and no state change after ${secs}s and one enter" 1
