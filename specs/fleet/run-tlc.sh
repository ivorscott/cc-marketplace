#!/usr/bin/env bash
# Run the fleet protocol model with TLC.
#   run-tlc.sh            every configuration: the must-hold ones pass, each expected-failing one reports
#                         exactly its violation (a vanished counterexample fails too)
#   run-tlc.sh fleet-gate one configuration by name
# TLA2TOOLS points at tla2tools.jar (default ~/.local/share/tla/tla2tools.jar).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
jar=${TLA2TOOLS:-$HOME/.local/share/tla/tla2tools.jar}
[ -f "$jar" ] || { echo "run-tlc: tla2tools.jar not found at $jar (set TLA2TOOLS)" >&2; exit 2; }

# name -> the property it must violate; empty means it must pass.
expect() {
  case "$1" in
    fleet-stale) echo NoStalePush ;;
    fleet-label) echo LabelAtMostOne ;;
    fleet-draft) echo Authority ;;
    fleet-relay) echo RelayRule ;;
    fleet|fleet-gate|fleet-authority) echo "" ;;
    *) echo "run-tlc: unknown configuration $1" >&2; return 2 ;;
  esac
}

run_one() {
  local name=$1 want out meta rc=0 line
  want=$(expect "$name")
  meta=$(mktemp -d)
  out=$(cd "$here" && java -XX:+UseParallelGC -cp "$jar" tlc2.TLC -workers auto -deadlock \
    -metadir "$meta" -config "$name.cfg" fleet.tla 2>&1) || rc=$?
  rm -rf "$meta"
  line=$(printf '%s\n' "$out" | grep -E 'states generated' | tail -1 || true)
  if [ -z "$want" ]; then
    if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'No error has been found'; then
      echo "PASS $name: ${line:-no state line}"
      return 0
    fi
    printf '%s\n' "$out" | tail -30 >&2
    echo "FAIL $name: expected a clean run, TLC exited $rc" >&2
    return 1
  fi
  # TLC exits 12 for a violated invariant.
  if [ "$rc" -eq 12 ] && printf '%s\n' "$out" | grep -q "Invariant $want is violated"; then
    echo "PASS $name: counterexample for $want as expected"
    return 0
  fi
  printf '%s\n' "$out" | tail -30 >&2
  echo "FAIL $name: expected Invariant $want violated (exit 12), TLC exited $rc" >&2
  return 1
}

if [ $# -gt 0 ]; then
  run_one "$1"
  exit
fi

bad=0
for n in fleet fleet-gate fleet-authority fleet-stale fleet-label fleet-draft fleet-relay; do
  run_one "$n" || bad=1
done
exit "$bad"
