#!/usr/bin/env bash
# The redact check the house rules require before sign-off and before every push: count the private terms in what a
# branch adds, without ever printing them.
#
#   redact-check.sh --range <base>..<head>
#
# The terms are in $FLEET_STATE_DIR/private/redact_terms.txt (default ~/.local/state/fleet/private/redact_terms.txt),
# outside every repo: one term per line, blank lines and lines starting with "#" ignored. It should be mode 600; a
# file that is group- or world-readable gets a warning, and the check still runs. Run it in the repo (the cwd). It
# reads the lines the branch adds since it left <base> (`git diff <base>...<head>`, from the merge base, so a line the
# default branch deleted later is not counted as added) and the commit messages in the range (`git log <base>..<head>`),
# and matches each term as a fixed string, case-insensitive. A three-dot range works the same. A line that holds a term counts once. The reply is counts only, "Redact
# check <range>: <n> matches." (references/output.md): never a term, a line or a file name.
# The check gates pushes to public repos only. The repo is the cwd's origin (repo_slug): `private_repos` / `public_repos`
# in config.toml (lists of owner/name) decide first, else `gh repo view --json visibility`. A private or internal repo
# prints "Redact check <range>: skipped (private repo)." and exits 0; public, or a visibility that cannot be read,
# runs the check as above (unreadable counts as public, so it never passes as clean by accident).
# Exit codes: 0 clean, 1 at least one match (stderr says how many lines, never which), 2 when the check cannot run
# (no terms file, no terms in it, or a range git cannot read). "Not configured" never passes as clean. Every agent
# may run it (agent-lib.sh puts it in the base allow list).
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
base="${range%%..*}"; head="${range##*..}"
# repo_private: the repo's visibility, from config first and gh second; true only when it is known to be not public.
repo_private() {
  local slug vis; slug="$(repo_slug .)"; [ -n "$slug" ] || return 1
  [ "$(config_list public_repos | jq -r --arg s "$slug" 'index($s) != null')" != true ] || return 1
  [ "$(config_list private_repos | jq -r --arg s "$slug" 'index($s) != null')" != true ] || return 0
  vis="$("$FLEET_GH" repo view "$slug" --json visibility -q .visibility 2>/dev/null)" || return 1
  case "$vis" in PRIVATE | INTERNAL | private | internal) return 0 ;; *) return 1 ;; esac
}
if repo_private; then render_line redact range="$range" skipped=1; exit 0; fi
src="$FLEET_STATE_DIR/private/redact_terms.txt"
[ -f "$src" ] || cannot "no terms file at $src, so the check cannot run" "Write the private terms there, one per line, mode 600"
[ -z "$(find "$src" -prune \( -perm -040 -o -perm -004 \) 2>/dev/null)" ] || warn "$src is readable by others; chmod 600 it"
git rev-list "$base..$head" >/dev/null 2>&1 && git merge-base "$base" "$head" >/dev/null 2>&1 ||
  cannot "git cannot read the range $range here" "Run it in the repo, with a range git knows"

tf="$(mktemp "${TMPDIR:-/tmp}/fleet-redact.XXXXXX")"; trap 'rm -f "$tf"' EXIT; chmod 600 "$tf"
sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$src" | grep -v -e '^$' -e '^#' >"$tf" || true
[ -s "$tf" ] || cannot "no terms in $src, so the check cannot run" "Write the private terms there, one per line"
added="$(git diff --no-color --no-ext-diff --unified=0 "$base...$head" -- 2>/dev/null | grep '^+' | grep -v '^+++ ' || true)"
msgs="$(git log --format=%B "$base..$head" -- 2>/dev/null || true)"
n=$(( $(printf '%s\n' "$added" | grep -c -i -F -f "$tf" || true) + $(printf '%s\n' "$msgs" | grep -c -i -F -f "$tf" || true) ))
render_line redact range="$range" count="$n"
[ "$n" = 0 ] || die "$n lines in $range hold a private term" "Remove them before you push"
