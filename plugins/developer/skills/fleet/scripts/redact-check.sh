#!/usr/bin/env bash
# The redact check the house rules require before sign-off and before every push: count the private terms in what a
# branch adds, without ever printing them.
#
#   redact-check.sh --range <base>..<head>
#
# The terms are `redact_terms` (an array of strings) in $FLEET_CONFIG_DIR/config.toml, the private config that never
# enters a repo. Run it in the repo (the cwd). It reads the lines the range adds (`git diff <base>..<head>`) and the
# commit messages in the range, and matches each term as a fixed string, case-insensitive. A line that holds a term
# counts once. The reply is counts only, "Redact check <range>: <n> matches." (references/output.md): never a term, a
# line or a file name.
# Exit codes: 0 clean, 1 at least one match (stderr says how many lines, never which), 2 when the check cannot run
# (no terms set, or a range git cannot read).
# "Not configured" never passes as clean. Every agent may run it (agent-lib.sh puts it in the base allow list).
# Command: Count the private terms in what a branch adds (counts only) · e.g. fleet redact-check --range origin/main..HEAD
set -euo pipefail
. "$(dirname "$0")/common.sh"

cannot() { printf 'fleet: %s. %s.\n' "$1" "$2" >&2; exit 2; } # cannot <what failed> <next step>: the check did not run
range=""
while [ $# -gt 0 ]; do
  case "$1" in
    --range) range="${2:-}"; shift 2 || shift ;;
    *) cannot "unknown argument: $1" "Run redact-check.sh --range <base>..<head>" ;;
  esac
done
case "$range" in ?*..?*) ;; *) cannot "no range given" "Run redact-check.sh --range <base>..<head>" ;; esac
terms="$(config_list redact_terms | jq -c '[.[] | select(length > 0)]')"
[ "$(jq length <<<"$terms")" -gt 0 ] || cannot "no redact_terms are set, so the check cannot run" "Add redact_terms to the private config.toml"
git rev-list "$range" >/dev/null 2>&1 || cannot "git cannot read the range $range here" "Run it in the repo, with a range git knows"

tf="$(mktemp "${TMPDIR:-/tmp}/fleet-redact.XXXXXX")"; trap 'rm -f "$tf"' EXIT; chmod 600 "$tf"
jq -r '.[]' <<<"$terms" >"$tf"
added="$(git diff --no-color --no-ext-diff --unified=0 "$range" -- 2>/dev/null | grep '^+' | grep -v '^+++ ' || true)"
msgs="$(git log --format=%B "$range" -- 2>/dev/null || true)"
n=$(( $(printf '%s\n' "$added" | grep -c -i -F -f "$tf" || true) + $(printf '%s\n' "$msgs" | grep -c -i -F -f "$tf" || true) ))
render_line redact range="$range" count="$n"
[ "$n" = 0 ] || die "$n lines in $range hold a private term" "Remove them before you push"
