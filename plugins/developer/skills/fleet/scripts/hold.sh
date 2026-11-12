#!/usr/bin/env bash
# Hold a ready PR back on purpose, and let it go again. A held PR is not ready to merge: the merge queue and fleet status
# list it as "On hold" with its note (not "merge the PR"), tick sends no pr_ready for it, the morning report lists it
# under On hold, and the overlap check ignores it, so new work branches from main and the held PR catches up later.
# A PR that depends on a held one waits for it. The hold lives on this machine (holds.json in the state dir); a PR
# body line that starts with "Hold:" does the same for the overlap check on every machine.
#
#   hold.sh <PR> --note "<why>"    hold a PR; the note is required and is shown wherever the PR is listed
#   hold.sh unhold <PR>            let it go: it is ready again if nothing else keeps it back, and pr_ready fires again
#
# <PR> is a PR URL, or #N or N for a PR a registry row names (an error names the candidates when N is unknown or
# matches more than one repo). Holding a PR that is held already replaces its note. Prints "Held <url>: <note>. ..."
# or "Unheld <url>: back in the merge queue.". The Orchestrator's: an agent (FLEET_ROLE set) may not run it.
# Command: Hold a PR back from the merge queue with a note, so new work branches from main · e.g. fleet hold #12 --note "wait for the release"
set -euo pipefail
. "$(dirname "$0")/common.sh"
[ -z "${FLEET_ROLE:-}" ] || die "hold is the Orchestrator's; an agent (FLEET_ROLE=$FLEET_ROLE) may not run it"

unhold=false
if [ "${1:-}" = unhold ]; then unhold=true; shift; fi
ref=""; note=""; have_note=false
while [ $# -gt 0 ]; do
  case "$1" in
    --note) [ $# -ge 2 ] || die "--note needs a value" "Run fleet help hold"; note="$2"; have_note=true; shift 2 ;;
    -*) die "unknown option: $1" "Run fleet help hold" ;;
    *) [ -z "$ref" ] || die "one PR at a time, got '$ref' and '$1'" "Run fleet help hold"; ref="$1"; shift ;;
  esac
done
[ -n "$ref" ] || die "usage: hold.sh <PR> --note \"<why>\" | hold.sh unhold <PR>" "Run fleet help hold"
if $unhold; then ! $have_note || die "unhold takes no --note" "Run fleet help hold"
else
  note="$(printf '%s' "$note" | tr '\n' ' ' | sed -e 's/^ *//' -e 's/ *$//')"
  [ -n "$note" ] || die "hold needs a note: --note \"<why>\"" "Say why the PR is held"
fi

# Resolve <PR> to a URL.
url=""
case "$ref" in
  https://*/pull/[0-9]* | https://*/merge_requests/[0-9]*) url="$ref" ;;
  \#[0-9]* | [0-9]*)
    n="${ref#\#}"
    case "$n" in *[!0-9]*) die "'$ref' is not a PR number or URL" "Pass a PR URL, or #N" ;; esac
    cand="$("$FLEET_SCRIPTS/registry.sh" list | jq -r --arg n "$n" '[.[] | select(type == "object" and .status != "Retired")
      | ([.pr // empty] + [(.prs // [])[]?]) [] | strings | select(test("/(pull|merge_requests)/" + $n + "$"))] | unique | .[]')"
    # A PR already held also resolves, so a PR whose row is gone can still be let go.
    held_c="$(holds_json | jq -r --arg n "$n" 'keys[] | select(test("/(pull|merge_requests)/" + $n + "$"))')"
    cand="$(printf '%s\n%s\n' "$cand" "$held_c" | sed '/^$/d' | sort -u)"
    case "$(printf '%s' "$cand" | grep -c .)" in
      0) die "no PR #$n in the registry" "Pass the PR URL" ;;
      1) url="$cand" ;;
      *) die "#$n matches more than one PR: $(printf '%s' "$cand" | paste -sd ' ' - | sed 's/ /, /g')" "Pass the PR URL" ;;
    esac ;;
  *) die "'$ref' is not a PR URL or number" "Pass a PR URL, or #N" ;;
esac

if $unhold; then
  hold_clear "$url" || die "$url is not held" "Run fleet status for the held PRs"
  ev_log unhold pr="$url"
  reply "$(render_line unheld pr="$url")"
else
  hold_set "$url" "$note"
  ev_log hold pr="$url" detail="$note"
  reply "$(render_line held pr="$url" note="$note")"
fi
