#!/usr/bin/env bash
# Rules check: do a repo's own fleet rules repeat or redefine the central ones, and do the rules an agent gets fit the budget?
#
#   rules.sh [--line] [<repo-dir>...]
#
# Read-only, no model call. The central rules are rules/house.md and, unless `company_rules = "none"`, rules/company.md.
# For each repo it reads <repo>/.claude/fleet-rules.md and reports, one line each:
#   repeats    a section of the repo file holds lines that equal a central line (after dropping the bullet, the indent,
#              case, extra spaces and a trailing "(prevents ...)" note; lines under 20 characters are ignored)
#   redefines  a section has a central section's title but a different body: the repo overrides the central rule
#   over       the fleet-supplied rules (house + layer + repo file + contract + fleet-run block) pass 8 KB
# then a size line: `api 4.6 KB of 8 KB (house 3.3, company 1.9, repo 0.4, contract+run 1.1)`. The repo's CLAUDE.md and
# the role templates are not counted. Exit 0 clean, 1 findings or over budget, 2 cannot run (no house.md, bad dir).
# With no repo it checks the repos of live registry rows and `repos` in config.toml. --line prints the one line boot
# shows: `Rules 4.1 KB of 8 KB, check ok`, or `Rules check: 2 findings (fleet rules check <repo>)`.
# Command: Check a repo's fleet rules for repeats of the central rules and the 8 KB budget · e.g. fleet rules check ~/code/app-api
set -euo pipefail
. "$(dirname "$0")/common.sh"

BUDGET=8192
line_mode=0; [ "${1:-}" = check ] && shift
[ "${1:-}" = "--line" ] && { line_mode=1; shift; }

[ -f "$FLEET_SKILL_DIR/rules/house.md" ] || { echo "rules: house rules missing: $FLEET_SKILL_DIR/rules/house.md. Reinstall the plugin." >&2; exit 2; }

repos=("$@")
if [ "${#repos[@]}" = 0 ]; then
  while IFS= read -r r; do [ -n "$r" ] && repos+=("$r"); done < <(
    { "$FLEET_SCRIPTS/registry.sh" list 2>/dev/null | jq -r '.[] | select(.status != "Retired") | .repo // empty' 2>/dev/null || true
      config_list repos | jq -r '.[]' 2>/dev/null || true; } | sort -u)
  [ "${#repos[@]}" -gt 0 ] || { echo "Rules check: no repos to check."; exit 0; }
fi
for r in "${repos[@]}"; do [ -d "$r" ] || { echo "rules: not a directory: $r. Pass a repo directory." >&2; exit 2; }; done

# norm: a line as the comparison sees it.
norm() { sed -E 's/ *\(prevents [^)]*\)//; s/^[[:space:]]*(- |\* )?//; s/[[:space:]]+/ /g; s/[[:space:]]+$//' | tr '[:upper:]' '[:lower:]'; }
central="$(mktemp)"; trap 'rm -f "$central"' EXIT
src_files="house.md"; [ "$(cfg_str company_rules company)" = none ] || src_files="house.md company.md"
titles=""
for f in $src_files; do
  while IFS= read -r l; do n="$(printf '%s\n' "$l" | norm)"; [ "${#n}" -ge 20 ] && printf '%s\t%s\n' "$n" "$f"; done <"$FLEET_SKILL_DIR/rules/$f" >>"$central" || true
  titles="$titles$({ grep '^## ' "$FLEET_SKILL_DIR/rules/$f" || true; } | sed 's/^## //' | tr '[:upper:]' '[:lower:]' | awk -v f="$f" '{ print $0 "\t" f }')"$'\n'
done

kb() { awk -v b="$1" 'BEGIN { printf "%.1f", b / 1024 }'; }
rc=0
for r in "${repos[@]}"; do
  name="$(basename "$r")"; f="$r/.claude/fleet-rules.md"; found=()
  if [ -f "$f" ]; then
    title=""; hits=0; src=""
    flush() {
      [ -n "$title" ] || return 0
      local t; t="$(printf '%s\n' "$title" | tr '[:upper:]' '[:lower:]')"
      local ts; ts="$(printf '%s' "$titles" | awk -F'\t' -v t="$t" '$1 == t { print $2; exit }')"
      if [ "$hits" -gt 0 ]; then found+=("$name: repeats $src \"$title\" ($hits lines)")
      elif [ -n "$ts" ]; then found+=("$name: redefines $ts \"$title\"")
      fi
    }
    while IFS= read -r l || [ -n "$l" ]; do
      case "$l" in
        "## "*) flush; title="${l#\#\# }"; hits=0; src="" ;;
        *) n="$(printf '%s\n' "$l" | norm)"
           if [ "${#n}" -ge 20 ]; then
             m="$(awk -F'\t' -v n="$n" '$1 == n { print $2; exit }' "$central")"
             if [ -n "$m" ]; then hits=$((hits + 1)); src="$m"; fi
           fi ;;
      esac
    done <"$f"
    flush
  fi
  h="$(rules_bytes house)"; d="$(rules_bytes layer)"; p="$(rules_bytes repo "$r")"; c="$(rules_bytes contract)"
  total=$((h + d + p + c))
  [ "$total" -le "$BUDGET" ] || found+=("$name: over the budget: $(kb "$total") KB of $(kb "$BUDGET") KB")
  if [ "$line_mode" = 1 ]; then
    if [ "${#found[@]}" = 0 ]; then printf 'Rules %s KB of %s KB, check ok\n' "$(kb "$total")" "$(kb "$BUDGET")"
    else printf 'Rules check: %d findings (fleet rules check %s)\n' "${#found[@]}" "$r"; fi
  else
    [ "${#found[@]}" = 0 ] || printf '%s\n' "${found[@]}"
    printf '%s %s KB of %s KB (house %s, company %s, repo %s, contract+run %s)\n' "$name" "$(kb "$total")" "$(kb "$BUDGET")" "$(kb "$h")" "$(kb "$d")" "$(kb "$p")" "$(kb "$c")"
  fi
  [ "${#found[@]}" = 0 ] || rc=1
done
exit "$rc"
