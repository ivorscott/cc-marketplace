#!/usr/bin/env bash
# The overlap check at plan time: do the files a plan will touch overlap the files of an open PR or a live team in the
# same repo, on any machine? Two PRs that change the same code at once conflict; sharing a repo does not.
#
#   overlap.sh <team | plan-file> [--json]
#
# The plan carries a `Files:` block (the planner's brief asks for it): a line `Files:` (a heading or bold is fine) and
# the paths after it, one per list line (`- path`, a note after the path is ignored), up to the first line that is not a
# list line. Paths are repo-relative. It compares them with the changed files of every open PR of the same repo (one
# `gh pr list`, all machines' PRs), and with the plan files of the other live teams on that repo: this machine's from
# their plan files, other machines' from the `f` list in their published summaries (linear.sh peers). A path is compared
# only inside its own repo (owner/name): the same path in another repo never counts. Nothing is written.
#
# The answer is one of, then the reason on the next line:
#   none                 no overlap: build now, even with another team live in the same repo
#   wait #N              the plan overlaps a PR much (more than 2 files or a quarter of the plan): the builder waits for
#                        #N to merge and then builds on top of it. A live team with no PR yet: `wait team <name>`.
#   merge-after #N       the overlap is small (at most 2 files and at most a quarter of the plan): build now and put the
#                        line `Merge after #N` in the PR body, so the merge queue marks it "merge after #N"
# A file the plan missed is caught later by the automatic catch-up (catchup.sh), so the worst case is one extra CI run.
# --json prints {answer, ref, files, reason}. Exit 0 with an answer; exit 2 when it cannot answer (no plan file, no
# `Files:` block, gh cannot list the PRs): never "none" by default.
# The Orchestrator's, not an agent's (it reads the other machines through linear.sh): tick runs it once when a team's
# planner is done, and tells the lead the answer.
# Command: Check a plan's files against open PRs and live teams in the same repo · e.g. fleet overlap build-api
set -euo pipefail
. "$(dirname "$0")/common.sh"

arg="${1:-}"; json=false
[ -n "$arg" ] || die "usage: overlap.sh <team | plan-file> [--json]"
[ "${2:-}" != --json ] || json=true

plan=""; team=""; repo_dir=""
if [ -f "$arg" ]; then
  plan="$arg"; repo_dir="$(cd "$(dirname "$arg")/../.." 2>/dev/null && pwd -P || true)"; team="$(basename "$arg" .md)"
else
  team="$arg"
  repo_dir="$("$FLEET_SCRIPTS/registry.sh" list --team "$team" | jq -r '[.[].repo // empty | select(. != "")] | first // ""')"
  [ -n "$repo_dir" ] || die "no live team $team with a repo" "Run fleet status for the teams"
  plan="$repo_dir/.fleet/plan/$team.md"
fi
[ -f "$plan" ] || die "no plan file at $plan" "Ask the planner to write the plan with a Files: block"
mine="$(plan_files "$plan")"
[ -n "$mine" ] || die "the plan has no Files: block" "Ask the planner to list the files the change will touch under Files:"
slug="$(repo_slug "$repo_dir")"
[ -n "$slug" ] || die "cannot tell the repo of $repo_dir (no origin remote)" "Overlap needs the repo's owner/name"

# Candidates: {ref, label, files} for each open PR of the repo (not this team's own) and each other live team's plan.
cands='[]'
prs="$("$FLEET_GH" pr list --repo "$slug" --state open --limit 200 --json number,url,headRefName,files,isCrossRepository 2>/dev/null)" &&
  printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1 || die "cannot list the open PRs of $slug" "Run gh auth status"
own="$("$FLEET_SCRIPTS/registry.sh" list | jq -c --arg t "$team" '[.[] | select(.team == $t) | .pr // empty | select(. != "")]')"
cands="$(jq -c --argjson own "$own" '[.[] | select(.url as $u | ($own | index($u)) == null)
  | {kind: "pr", ref: "#\(.number)", team: "", files: [(.files // [])[] | .path // empty]}]' <<<"$prs")"
# teams on this machine in the same repo that have no PR yet: their plan files
while IFS= read -r t; do
  [ -n "$t" ] && [ "$t" != "$team" ] || continue
  [ -z "$("$FLEET_SCRIPTS/registry.sh" list --team "$t" | jq -r '[.[].pr // empty | select(. != "")] | first // empty')" ] || continue
  pf="$repo_dir/.fleet/plan/$t.md"; [ -f "$pf" ] || continue
  cands="$(jq -c --arg t "$t" --argjson f "$(plan_files "$pf" | jq -Rsc 'split("\n") | map(select(. != ""))')" '. + [{kind: "team", ref: $t, team: $t, files: $f}]' <<<"$cands")"
done < <("$FLEET_SCRIPTS/registry.sh" list --live | jq -r --arg r "$repo_dir" '[.[] | select(.tier != "Orchestrator" and .repo == $r) | .team] | unique[]')
# other machines' teams with no PR yet: the `f` list of their published summary, repo-qualified (owner/name:path)
peers="${FLEET_PEERS_JSON:-}"; [ -n "$peers" ] || peers="$("$FLEET_SCRIPTS/linear.sh" peers 2>/dev/null)" || peers='[]'
if printf '%s' "$peers" | jq -e 'type == "array"' >/dev/null 2>&1; then
  cands="$(jq -c --arg s "$slug" --slurpfile c <(printf '%s' "$cands") '$c[0] + [.[] | .machine as $m | (.summary // [])[] | select((.pr // "") == "" and ((.f // []) | length) > 0)
    | {kind: "team", ref: "\(.t) (\($m))", team: .t, files: [.f[] | select(startswith($s + ":")) | ltrimstr($s + ":")]} | select(.files | length > 0)]' <<<"$peers")"
fi

# Compare: the plan's files with each candidate's; only the same repo's PRs and plans are in cands, so paths never cross repos.
res="$(jq -nc --argjson mine "$(printf '%s\n' "$mine" | jq -Rsc 'split("\n") | map(select(. != ""))')" --argjson c "$cands" '
  ($mine | length) as $n
  | [$c[] | . as $x | ([$mine[] | select(. as $p | $x.files | index($p) != null)]) as $hit | select($hit | length > 0)
      | {kind, ref, files: $hit, small: (($hit | length) <= 2 and (($hit | length) * 4 <= $n))}] as $h
  | if ($h | length) == 0 then {answer: "none", ref: "", files: [], reason: "no open PR or live team in the repo touches the plan'"'"'s files"}
    else (([$h[] | select(.small | not)] | first) // $h[0]) as $d
      | {answer: (if $d.small then "merge-after" else "wait" end), ref: $d.ref, kind: $d.kind, files: $d.files,
         reason: "\($d.ref) touches \($d.files | join(", "))"} end')"
if $json; then printf '%s\n' "$res"; exit 0; fi
jq -r 'if .answer == "none" then "none" elif .kind == "team" then "\(.answer) team \(.ref)" else "\(.answer) \(.ref)" end, "Overlap: \(.reason)."' <<<"$res"
