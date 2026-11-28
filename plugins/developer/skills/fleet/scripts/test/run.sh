#!/usr/bin/env bash
# The fleet's tests, by area. Offline: a temporary fleet root, shims for herdr, gh, docker and Linear; nothing live.
#
#   bash scripts/test/run.sh                 every area (CI runs this)
#   bash scripts/test/run.sh <area>...       only those areas: commands, registry, tick, teams, lifecycle
#
# One case per behaviour someone depends on. An area is test/<area>.sh, defining <area>_suite.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
AREAS=(lifecycle commands registry tick teams)
want=("$@"); [ ${#want[@]} -gt 0 ] || want=("${AREAS[@]}")
for a in "${want[@]}"; do
  [ -f "$HERE/$a.sh" ] || { echo "no area $a (test/$a.sh)" >&2; exit 2; }
  # shellcheck source=/dev/null
  . "$HERE/$a.sh"
  "${a}_suite"
done
printf '\n%d passed, %d failed\n' "$pass" "$failn"
[ "$failn" = 0 ]
