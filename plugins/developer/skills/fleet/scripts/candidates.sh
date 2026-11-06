#!/usr/bin/env bash
# The work a team could boot now, and what was skipped and why: the Orchestrator trusts this list and keeps no exclude list.
#
#   candidates.sh
#
# One line per bootable issue, `- DEV-1 · P2 · title · ready`, by priority then identifier, then one `skipped:` line with
# each issue left out and the reason in one word: verify, done, canceled, duplicate, other-team (a team key outside
# tracker_teams), no-role (no `role:` label unless candidates_allow_unlabelled = true), claimed (another machine's live
# claim), blocked (an open issue blocks it), other-state; or held (a registry row already works on it). A bootable issue
# is `ready` (Todo or Backlog) or `in-progress-lapsed` (In Progress with no live claim). "Nothing bootable." when none.
# tracker_teams, role_label_prefix and candidates_allow_unlabelled are in config.toml (config.example.toml). Needs a
# Linear key; without one it says so and exits 3. Tick's slot_free reads the same filters (linear.sh candidates).
# Command: List the work a team could boot now, and what was skipped and why · e.g. fleet candidates
set -euo pipefail
. "$(dirname "$0")/common.sh"

"$FLEET_SCRIPTS/linear.sh" has-key >/dev/null 2>&1 || { warn "no Linear key, so candidates cannot be read"; exit 3; }
d="$("$FLEET_SCRIPTS/linear.sh" candidates --detail)" || die "could not read the candidates" "Run fleet candidates again"
held="$("$FLEET_SCRIPTS/registry.sh" list | jq -c '[.[] | select(.status != "Retired" and (.issue // "") != "") | .issue] | unique')"
render_candidates "$d" "$held"
