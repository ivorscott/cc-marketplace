#!/usr/bin/env bash
# Park a team: close its panes, keep everything else, free its slot.
#
#   park.sh <team>          park it
#   park.sh <team> --undo   bring it back: restarts its agents with the resume brief (unpark.sh); refused when a cap is full
#
# The rows become Parked (parked_at, parked_reason = park). Their worktrees,
# branches, plans and reports stay, and so does the Linear claim (nothing is written to Linear). Tick skips a
# Parked team: it is never Stalled or Zombie, is not nudged or respawned, gets no next issue, and still covers
# its repo for repo_without_team. A Parked team does not count against max_teams.
#
# It refuses at once, changing nothing, when herdr does not answer, when a worktree of the team has changes
# that are not committed (an untracked file under reports/, where the tester keeps its report, does not count), or
# when it has commits that are on no remote. It never waits.
# It prints "Parked <team>: slot free, worktrees and claim kept.", then the team table (references/output.md).
# Command: Free a team's slot and keep its work · e.g. fleet park build-api
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
[ -z "${FLEET_ROLE:-}" ] || die "park is the Orchestrator's; an agent (FLEET_ROLE=$FLEET_ROLE) may not run it"
registry="$FLEET_SCRIPTS/registry.sh"

team="${1:?usage: park.sh <team> [--undo]}"; shift
reason=""
while [ $# -gt 0 ]; do
  case "$1" in
    --undo) exec "$FLEET_SCRIPTS/unpark.sh" "$team" ;;
    --reason) reason="${2:?--reason needs a value}"; shift 2 ;;
    *) die "unknown option: $1" "Run fleet help park" ;;
  esac
done
[ -n "$reason" ] || reason=park

rows="$("$registry" list --team "$team" | jq -c '[.[] | select(.tier != "Orchestrator" and .status != "Retired")]')"
[ "$(printf '%s' "$rows" | jq length)" != 0 ] || die "no live rows for team '$team'"
[ "$(printf '%s' "$rows" | jq '[.[] | select(.status == "Parked")] | length')" = 0 ] || die "team '$team' is already parked"

# herdr first: with it down the panes cannot be closed, and rows must not say Parked while the panes live on.
hd agent list >/dev/null 2>&1 || die "herdr is not answering; $team is not parked and no row changed"

# Work that would be lost or stranded: refuse for the whole team, naming every worktree. An untracked file under
# reports/ is not: the tester keeps its report there uncommitted, so a signed-off team would otherwise never park.
# Tracked changes anywhere (reports/ too) and untracked files anywhere else still refuse. git quotes a path with
# unusual characters, hence both forms.
refused=""
while IFS=$'\t' read -r name wt; do
  [ -n "$wt" ] && [ -d "$wt" ] || continue
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null | grep -v -e '^?? reports/' -e '^?? "reports/' | head -n 1)" ]; then refused="$refused
  $name: uncommitted changes in $wt"; continue; fi
  if [ "$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)" != 0 ]; then refused="$refused
  $name: commits in $wt that are on no remote"; fi
done < <(printf '%s' "$rows" | jq -r '.[] | [.name, (.worktree // "")] | @tsv')
[ -z "$refused" ] || die "not parking $team; commit and push first:$refused"

"$registry" park "$team" "$reason" >/dev/null
while IFS=$'\t' read -r name pane; do
  [ -n "$pane" ] || continue
  hd pane close "$pane" >/dev/null 2>&1 || warn "could not close pane $pane of $name; its row is Parked"
done < <(printf '%s' "$rows" | jq -r '.[] | [.name, (.pane // "")] | @tsv')
ev_log parked team="$team" detail="$reason"
herdr_meta "$team" # the panel shows it Parked
reply "$(render_line parked team="$team")" "$(render_table)"
