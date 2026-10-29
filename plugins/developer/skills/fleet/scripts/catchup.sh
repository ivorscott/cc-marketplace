#!/usr/bin/env bash
# Bring a finished team back to catch its PR up with the base branch after another PR merged ahead of it and now
# conflicts with it (revive.sh does the bringing back; this gives the lead the merge procedure). tick.sh runs this on a conflict when the team is Parked or any of its agents is Done, Zombie or
# gone (a team whose agents are live is only told). Local teams only: a team another machine holds is that machine's.
#
#   catchup.sh <team> <pr-url> [<merged-by>]
#
# <merged-by> names the PR(s) merged ahead of it, for the lead's brief. A Parked team comes back through unpark.sh (the
# same max_teams and teams_per_repo checks, FLEET_FORCE=1 overrides); any other team that is not live is checked against
# the same caps. A catch-up is a fix on an open PR, so it goes over both without FLEET_FORCE (revive.sh --fix). Then each agent that is Done or Zombie, or whose pane is gone, is started again in its own worktree
# with respawn.sh --revive, lead first (a live agent is left alone), and the lead gets a brief (tell.sh --brief) with the
# procedure: git fetch origin; git merge origin/main in the PR's branch (a merge commit, no history is rewritten);
# resolve the conflicts; run the repo's verify; a plain git push; the tester signs the new head off again. A conflict
# it cannot resolve is a P1 escalation. Nothing is charged to the respawn budget; tick.sh counts the rounds per PR
# (at most 2, then a P1 escalation instead of another round). It prints "Caught up <team>: ..." and logs
# `catchup` to the event log. Exit 1 with the reason on stderr when the team is not brought back (a cap is full, herdr
# does not answer), the team as it was.
# Command: Bring a finished team back to merge main into its conflicting PR · e.g. fleet catchup build-api https://github.com/acme/app-api/pull/12
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
[ -z "${FLEET_ROLE:-}" ] || die "catchup is the Orchestrator's; an agent (FLEET_ROLE=$FLEET_ROLE) may not run it"
registry="$FLEET_SCRIPTS/registry.sh"

usage="usage: catchup.sh <team> <pr-url> [<merged-by>]"
team="${1:?$usage}"; pr="${2:?$usage}"; by="${3:-}"

# What the lead must do, as the lead's brief puts it (no history is rewritten: a merge commit and a plain push).
procedure="$(
  printf 'PR %s conflicts with its base now' "$pr"
  if [ -n "$by" ]; then printf ' (%s merged ahead of it)' "$by"; fi
  printf '. Bring it up to date by merging, in your PR branch:\n1. git fetch origin\n2. git merge origin/main (a merge commit; no history is rewritten)\n'
  printf '3. resolve the conflicts, keeping both sides intent\n4. run the repo'"'"'s verify command and show its result\n5. a plain git push of your branch\n'
  printf '6. have the tester sign off the new head (registry.sh signoff) so the PR is ready again\n'
  printf 'Your builder and tester are started again in their worktrees for this. If a conflict cannot be resolved safely, escalate it P1 with the files in conflict and do not push a guess.\n'
)"
why="another PR merged ahead of $pr and it conflicts now; your team was finished and has been brought back to catch it up"
out="$("$FLEET_SCRIPTS/revive.sh" "$team" --text "$procedure" --why "$why" --event catchup --fix --pr "$pr${by:+ after $by}")" || exit 1
printf 'Caught up %s: %s; lead told to merge main into %s.\n' "$team" "$(printf '%s' "$out" | sed 's/^Revived [^:]*: //; s/ back\.$/ back/')" "$pr"
