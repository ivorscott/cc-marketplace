#!/usr/bin/env bash
# SessionStart (clear): when the fleet's self-driving run is on and this pane is the registered Orchestrator, put the
# run back into the new conversation. Silent everywhere else: other panes, team agents, no herdr, run off.
# fleet run init copies this file to ~/.claude/hooks/ and registers it; it finds the newest installed plugin itself,
# so a plugin update never breaks it.
set -u
[ -n "${HERDR_PANE_ID:-}" ] || exit 0
F="$(ls -d "$HOME"/.claude/plugins/cache/cc-marketplace/developer/*/skills/fleet/scripts 2>/dev/null | sort -V | tail -1)"
[ -n "$F" ] && [ -x "$F/fleet" ] || exit 0
"$F/fleet" run status 2>/dev/null | grep -q '^Run: running' || exit 0
pane="$("$F/registry.sh" get orchestrator 2>/dev/null | jq -r '.pane // empty' 2>/dev/null)"
[ "$pane" = "$HERDR_PANE_ID" ] || exit 0
msg="The fleet's self-driving loop (fleet run) is running from this pane and must keep running after /clear. Restore it now: run \`$F/fleet run start\` (it re-registers this session as the Orchestrator), then follow the rules it prints and the developer:fleet skill's R. Run section until \`fleet run stop\`."
jq -n --arg m "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
