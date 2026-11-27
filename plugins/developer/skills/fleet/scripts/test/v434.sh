#!/usr/bin/env bash
# 4.3.4 cases (DEV-1257): the house rules say testers never commit, every role ends with done, and a missing tool is installed.
# Sourced by run.sh (ok/eq/check, $SCRIPTS).

v434_smoke() {
  local h="$SCRIPTS/../rules/house.md"
  eq "v434 house: a tester verifies and signs off, never commits or pushes" "$(grep -c '^- A tester verifies and signs off; it never commits and never pushes' "$h")" "1"
  eq "v434 house: every role, planners included, ends with its done step" "$(grep -c '^- Every role, planners included, ends its work with its done step.*PR and the head SHA' "$h")" "1"
  eq "v434 house: with installs allowed a missing tool is installed, UNVERIFIED only for what cannot run" "$(grep -c '^- When installs are allowed, install a missing tool yourself (list what, where, why.*UNVERIFIED only for what cannot run here' "$h")" "1"
  eq "v434 house: the install rewrite still hits one line and keeps the new rule" \
    "$(bash -c '. "$1/common.sh"; sed "s/^- Installing is allowed only when.*$/X/" "$2" | grep -c "^X$"' _ "$SCRIPTS" "$h"):$(grep -c '^- Installing is allowed only when' "$h")" "1:1"
}
v434_full() { v434_smoke; }
