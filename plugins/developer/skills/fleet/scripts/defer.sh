#!/usr/bin/env bash
# Deferred items become issues: what a team's PR leaves for the owner (copy to review, an open question, a later fix) is
# filed as a Linear issue linked to the PR, never left only in a PR body, and recorded on the team's lead
# (registry.sh note <team>/lead deferred ...), which is where the morning report's "Needs your eyes" reads it.
#
#   defer.sh <team> [--pr URL]          read the PR body and file each item not filed yet
#   defer.sh <team> --item TEXT [--pr URL]   file one item the Orchestrator found elsewhere (a review comment, a report)
#
# The PR body lists them under a line `Deferred:`, `Left for the owner:`, `For the owner:` or `Needs the owner:` (a heading or
# bold is fine), as list lines (`- text`) up to the first line that is not one. Each is filed once: an item whose text a
# deferred note of the lead already holds is skipped. The issue is made in the team's issue's Linear team, linked to the PR,
# and the note is `<item> → <ISSUE> <url>`. With no Linear key, or writes off, the item is still noted
# (`<item> → not filed: <why>`) so the report lists it, and filed by a later run once writes are on. Prints one line per item:
# `Deferred <ISSUE>: <item>`. tick runs the first form once when a PR becomes ready. Orchestrator only.
# Command: File what a PR defers to the owner as linked issues · e.g. fleet defer build-api
set -euo pipefail
. "$(dirname "$0")/common.sh"
[ -z "${FLEET_ROLE:-}" ] || die "defer is the Orchestrator's; an agent (FLEET_ROLE=$FLEET_ROLE) may not run it"
registry="$FLEET_SCRIPTS/registry.sh"

usage="usage: defer.sh <team> [--pr URL] [--item TEXT]"
team="${1:?$usage}"; shift
pr=""; item=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) pr="${2:?--pr needs a URL}"; shift 2 ;;
    --item) item="${2:?--item needs text}"; shift 2 ;;
    *) die "unknown option: $1" "$usage" ;;
  esac
done
rows="$("$registry" list --team "$team" | jq -c '[.[] | select(.status != "Retired" and .tier != "Orchestrator")]')"
lead="$(jq -r '[.[] | select(.tier == "Lead") | .name] | first // ""' <<<"$rows")"
[ -n "$lead" ] || die "no live team '$team'" "Run fleet status"
issue="$(jq -r '[.[].issue // empty | select(. != "")] | first // ""' <<<"$rows")"
[ -n "$pr" ] || pr="$(jq -r '[.[].pr // empty | select(. != "")] | first // ""' <<<"$rows")"

items=()
if [ -n "$item" ]; then items+=("$item")
else
  [ -n "$pr" ] || exit 0
  body="$(forge_pr_json "$pr" 2>/dev/null | jq -r '.body // ""')" || exit 0
  while IFS= read -r l; do [ -z "$l" ] || items+=("$l"); done < <(printf '%s\n' "$body" | awk '
    on && /^[[:space:]]*[-*][[:space:]]+/ { l = $0; sub(/^[[:space:]]*[-*][[:space:]]+/, "", l); gsub(/\r/, "", l); print l; seen = 1; next }
    on && /^[[:space:]]*$/ { if (seen) exit; next }
    on { exit }
    /^[#*[:space:]]*(Deferred|Left for the owner|For the owner|Needs the owner)[*[:space:]]*:?[*[:space:]]*$/ { on = 1; seen = 0 }')
fi
[ "${#items[@]}" -gt 0 ] || exit 0

have_key=false; why="no Linear key"
if "$FLEET_SCRIPTS/linear.sh" has-key >/dev/null 2>&1; then
  if [ "$(linear_writes)" != off ] && [ -n "$issue" ]; then have_key=true; else why="Linear writes are off or the team has no issue"; fi
fi
for it in "${items[@]}"; do
  key="${it:0:80}"
  # Filed already (a deferred note of the lead starting with the item), unless it was only noted and writes are on now.
  prev="$(jq -r --arg l "$lead" --arg k "$key" --slurpfile r <("$registry" list --with-archived) '[$r[0][] | select(.name == $l) | (.notes // [])[] | select(.kind == "deferred" and (.message | startswith($k)))] | last | .message // ""' <<<"null")"
  if [ -n "$prev" ]; then
    case "$prev" in *"not filed:"*) $have_key || continue ;; *) continue ;; esac
  fi
  if $have_key; then
    if out="$("$FLEET_SCRIPTS/linear.sh" create-issue "$issue" "Follow-up from $issue: ${it:0:70}" "$it

Left for the owner by the team on $issue.${pr:+ PR: $pr}" ${pr:+--link "$pr"} 2>"$FLEET_STATE_DIR/defer.err")"; then
      id="$(jq -r .identifier <<<"$out")"; url="$(jq -r .url <<<"$out")"
      "$registry" note "$lead" deferred "$it → $id $url" >/dev/null
      printf 'Deferred %s: %s\n' "$id" "$it"
      continue
    fi
    why="could not file it: $(tail -n 1 "$FLEET_STATE_DIR/defer.err" | sed 's/^fleet: //')"
  fi
  "$registry" note "$lead" deferred "$it → not filed: $why" >/dev/null
  printf 'Deferred (not filed: %s): %s\n' "$why" "$it"
done
rm -f "$FLEET_STATE_DIR/defer.err"
