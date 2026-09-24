#!/usr/bin/env bash
# Retire a team or one agent: close what /fleet created, remove clean worktrees, and
# mark the rows Retired. Ask the agents to push WIP and summarise BEFORE running this.
#
#   retire.sh <team | team/role> [--outcome O]
#
# Never closes panes or workspaces the registry doesn't record as fleet-created. A
# worktree with uncommitted changes is kept and reported, never force-removed.
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"

target="${1:?usage: retire.sh <team | team/role> [--outcome O]}"; shift
outcome=""; [ "${1:-}" = "--outcome" ] && outcome="${2:-}"

rows="$("$registry" list | jq --arg x "$target" '[.[] | select((.name == $x or .team == $x) and .status != "Retired")]')"
[ "$(printf '%s' "$rows" | jq length)" != "0" ] || die "nothing live matches '$target'"

kept="[]"
whole_team=false; printf '%s' "$rows" | jq -e --arg x "$target" 'all(.team == $x)' >/dev/null && [ "${target%%/*}" = "$target" ] && whole_team=true

if $whole_team; then
  ws="$(printf '%s' "$rows" | jq -r '[.[].workspace | select(. != null and . != "")] | first // ""')"
  [ -n "$ws" ] && { hd workspace close "$ws" >/dev/null 2>&1 || warn "could not close workspace $ws"; }
else
  for pane in $(printf '%s' "$rows" | jq -r '.[].pane // empty'); do
    hd pane close "$pane" >/dev/null 2>&1 || warn "could not close pane $pane"
  done
fi

while IFS=$'\t' read -r wt repo; do
  [ -d "$wt" ] || continue
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null | head -3 | tr '\n' ' ')"
  if [ -n "$dirty" ]; then
    warn "kept $wt: uncommitted changes ($dirty)"; kept="$(printf '%s' "$kept" | jq -c --arg w "$wt" '. + [$w]')"
  else
    git -C "$repo" worktree remove "$wt" 2>/dev/null || { warn "kept $wt: git worktree remove failed"; kept="$(printf '%s' "$kept" | jq -c --arg w "$wt" '. + [$w]')"; }
  fi
done < <(printf '%s' "$rows" | jq -r '.[] | select((.worktree // "") != "") | [.worktree, .repo] | @tsv')

if [ -n "$outcome" ]; then "$registry" retire "$target" --outcome "$outcome"; else "$registry" retire "$target"; fi
printf '%s' "$rows" | jq --argjson kept "$kept" '{retired: [.[].name], kept_worktrees: $kept}'
