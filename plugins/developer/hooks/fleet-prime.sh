#!/usr/bin/env bash
# SessionStart hook for /fleet agents. Inert unless FLEET_NAME is set, which only
# happens in panes /fleet booted. After a start, resume, clear or compaction it
# re-injects the agent's identity and assignment from the registry, so a fresh
# context picks up exactly where the work lives: outside the agent.
set -u
cat >/dev/null 2>&1 || true
[ -n "${FLEET_NAME:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
reg="${FLEET_REGISTRY:-${XDG_STATE_HOME:-$HOME/.local/state}/fleet/fleet.json}"
[ -f "$reg" ] || exit 0
row="$(jq -c --arg n "$FLEET_NAME" '.agents[$n] // empty' "$reg" 2>/dev/null)"
[ -n "$row" ] || exit 0
cli="registry.sh"
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && cli="$CLAUDE_PLUGIN_ROOT/skills/fleet/scripts/registry.sh"
printf '%s' "$row" | jq -r --arg cli "$cli" '
  "You are fleet agent \(.name) (\(.tier), team \(.team), template \(.template)).",
  "Assignment: \(.assignment)",
  (if (.worktree // "") != "" then "Work only inside your worktree: \(.worktree) (branch \(.branch))." else empty end),
  (if (.expertise_file // "") != "" then "Read your expertise file before continuing: \(.expertise_file)" else empty end),
  "Registry status: \(.status). When your part is finished, run `\($cli) done \(.name) --outcome <Shipped|Partial|Failed> --summary \"<one line>\"`, then stop."'
