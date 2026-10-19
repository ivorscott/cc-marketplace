#!/usr/bin/env bash
# PreToolUse hook (Bash) for /fleet agents. Inert unless FLEET_ROLE is set (only in panes /fleet booted):
# the Orchestrator and the user's own sessions are not fleet agents and are never restricted.
#
#   Every fleet agent: a command that names the Linear key (the file linear_api_key or the variable
#   LINEAR_API_KEY) is denied, and so is `herdr pane run|send-text|send-keys` to any pane (it types
#   into someone else's shell). `herdr agent prompt|send-keys|read` is allowed only to an agent of
#   the agent's own team (FLEET_TEAM), and prompt and send-keys only for leads: a worker cannot drive
#   anyone. A target that cannot be read off the command (a variable, a substitution) is denied.
#
# A guardrail, not a boundary: a command can build the key's name at run time, and the key file is
# mode 600 for the user the agents run as, so any same-uid process can read it.
set -u
input="$(cat 2>/dev/null || true)"
[ -n "${FLEET_ROLE:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
[ -n "$cmd" ] || exit 0

deny() { jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'; exit 0; }

if printf '%s' "$cmd" | grep -qi 'linear_api_key'; then
  deny "fleet bash guard: the command names the Linear key; only the Orchestrator reads it."
fi
case "$cmd" in *herdr*) ;; *) exit 0 ;; esac

# The same sanitising agent_name does in common.sh, so a team's agents share one prefix.
team="$(printf '%s' "${FLEET_TEAM:-}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"

# One segment per simple command: split on ; & | ( ) and newlines.
while IFS= read -r seg; do
  read -r -a w <<<"${seg//[\"\'\`]/ }"
  i=0
  while [ "$i" -lt "${#w[@]}" ]; do
    case "${w[$i]##*/}" in herdr) ;; *) i=$((i + 1)); continue ;; esac
    i=$((i + 1))
    while [ "$i" -lt "${#w[@]}" ]; do # herdr's own options before the group
      case "${w[$i]}" in --session | --socket) i=$((i + 2)) ;; --*) i=$((i + 1)) ;; *) break ;; esac
    done
    group="${w[$i]:-}"; sub="${w[$((i + 1))]:-}"; target="${w[$((i + 2))]:-}"
    case "$group $sub" in
      "pane run" | "pane send-text" | "pane send-keys")
        deny "fleet bash guard: herdr $group $sub types into a pane, which fleet agents may not do." ;;
      "agent prompt" | "agent send-keys" | "agent read")
        if [ "$sub" != read ] && [ "${FLEET_ROLE:-}" != lead ]; then
          deny "fleet bash guard: only a lead may herdr agent $sub, and only to its own team."
        fi
        case "$target" in
          "" | -* | *'$'* | *'~'*) deny "fleet bash guard: herdr agent $sub needs a literal agent name of your own team." ;;
        esac
        case "$target" in
          "$team"-*) [ -z "$team" ] && deny "fleet bash guard: no team known for this agent." ;;
          *) deny "fleet bash guard: $target is not an agent of your team (${FLEET_TEAM:-none})." ;;
        esac ;;
    esac
  done
done < <(printf '%s\n' "$cmd" | tr ';&|()' '\n\n\n\n\n')
exit 0
