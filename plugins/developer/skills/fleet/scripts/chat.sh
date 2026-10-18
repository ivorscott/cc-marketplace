#!/usr/bin/env bash
# The chat channel's settings and message format. Coordination only, never the lock.
# This script never posts or reads: the Orchestrator does that with its own chat tools.
#
#   chat.sh channel                 chat_channel from config.toml (opaque text; empty when unset)
#   chat.sh allow                   chat_allow from config.toml as a JSON array (permission rules
#                                   for the Orchestrator's own settings; boot gives them to no agent)
#   chat.sh format <event> [words...]
#                                   one line: fleet[<machine key>] <event> <words...>
#                                   events: claim pr merge escalation takeover rebase
set -euo pipefail
. "$(dirname "$0")/common.sh"

case "${1:-}" in
  channel) cfg_str chat_channel '' ;;
  allow) config_list chat_allow ;;
  format)
    ev="${2:?usage: chat.sh format <event> [words...]}"; shift 2
    case "$ev" in claim | pr | merge | escalation | takeover | rebase) ;; *) die "unknown event: $ev (claim pr merge escalation takeover rebase)" ;; esac
    printf 'fleet[%s] %s%s\n' "$(machine_key)" "$ev" "${*:+ $*}" ;;
  *) echo "usage: chat.sh channel|allow|format <event> [words...]" >&2; exit 2 ;;
esac
