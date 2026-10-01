#!/usr/bin/env bash
# Retire a team or one agent: close what /fleet created, remove clean worktrees, and
# mark the rows Retired. Ask the agents to push WIP and summarise BEFORE running this.
#
#   retire.sh <team | team/role> [--outcome O]
#   retire.sh --summary <team | team/role> [...]
#
# --summary changes nothing. It prints, as JSON, what the user needs to see before (and
# after) a retire: every agent's outcome and summary, the PRs the summaries name, the
# UNVERIFIED items, escalations (open = the row still carries .escalation), discovered
# work, and the worktrees a retire would keep. PRs are found as "PR #n" (GitHub style) or
# "MR !n" (GitLab style) in summaries; each carries its repo's {host, project}. The
# Orchestrator adds live PR state with that host's CLI and the next issues from whatever
# tracker is connected, then renders the summary (SKILL.md, route F).
#
# Never closes panes or workspaces the registry doesn't record as fleet-created. A
# worktree with uncommitted changes is kept and reported (untracked files by name, also
# under `kept_untracked` in the JSON), never force-removed. Retiring a
# whole team also runs `env.sh down <team>` for its test cluster (only one the registry
# created); if that fails the env is kept and reported.
set -euo pipefail
. "$(dirname "$0")/common.sh"
registry="$FLEET_SCRIPTS/registry.sh"

# untracked_in <worktree>: one untracked path per line.
untracked_in() { git -C "$1" status --porcelain --untracked-files=all 2>/dev/null | sed -n 's/^?? //p'; }

# remote_of <repo dir>: {host, project} from the origin remote, for any forge (GitHub,
# GitLab, self-hosted, ...). Handles scp-style (git@host:a/b.git) and URL remotes
# (https://host[:port]/a/b, ssh://git@host/a/b). No remote: host null, project = dir name.
remote_of() {
  local url host path
  url="$(git -C "$1" remote get-url origin 2>/dev/null || true)"; url="${url%.git}"; url="${url%/}"
  case "$url" in
    *://*) url="${url#*://}"; url="${url#*@}"; host="${url%%/*}"; host="${host%%:*}"; path="${url#*/}" ;;
    *@*:*) url="${url#*@}"; host="${url%%:*}"; path="${url#*:}" ;;
    *) host=""; path="" ;;
  esac
  [ -n "$path" ] && [ "$path" != "$url" ] || { host=""; path="$(basename "$1")"; }
  jq -cn --arg h "$host" --arg p "$path" '{host: (if $h == "" then null else $h end), project: $p}'
}

summary() {
  [ "$#" -gt 0 ] || die "usage: retire.sh --summary <team | team/role> [...]"
  local rows="[]" t r wts="[]" repos="{}" wt repo dirty untracked
  for t in "$@"; do
    r="$("$registry" list | jq --arg x "$t" '[.[] | select(.name == $x or .team == $x)]')"
    [ "$(printf '%s' "$r" | jq length)" != "0" ] || die "nothing matches '$t'"
    rows="$(jq -cn --argjson a "$rows" --argjson b "$r" '$a + $b | unique_by(.name)')"
  done
  while IFS= read -r repo; do
    repos="$(printf '%s' "$repos" | jq -c --arg d "$repo" --argjson g "$(remote_of "$repo")" '. + {($d): $g}')"
  done < <(printf '%s' "$rows" | jq -r '[.[].repo | select(. != null and . != "")] | unique[]')
  while IFS=$'\t' read -r wt; do
    [ -d "$wt" ] || continue
    dirty="$(git -C "$wt" status --porcelain 2>/dev/null | head -1)"
    untracked="$(untracked_in "$wt")"
    wts="$(printf '%s' "$wts" | jq -c --arg w "$wt" --arg b "$(git -C "$wt" branch --show-current 2>/dev/null)" \
      --argjson d "$([ -n "$dirty" ] && echo true || echo false)" --arg u "$untracked" \
      '. + [{path: $w, branch: $b, kept: $d, untracked: ($u | split("\n") | map(select(. != "")))}]')"
  done < <(printf '%s' "$rows" | jq -r '.[] | select((.worktree // "") != "") | .worktree')
  printf '%s' "$rows" | jq --argjson repos "$repos" --argjson wts "$wts" '
    def text: (.summary // "");
    {
      teams: ([.[].team] | unique),
      agents: [.[] | {name, tier, status, outcome: (.outcome // null), summary: (.summary // null)}],
      prs: ([.[] | . as $a | text | [scan("\\b(?:PR ?#|MR ?!)([0-9]+)")[0]]
              | map(($repos[$a.repo] // {host: null, project: null}) as $r
                    | {host: $r.host, repo: $r.project, number: tonumber, from: $a.name})] | add // []
            | unique_by([.host, .repo, .number])),
      unverified: [.[] | select(text | test("unverified"; "i")) | {name, summary}],
      escalations: [.[] | . as $a | (.escalations // [])[]
                    | {name: $a.name, severity, message, at, open: (($a.escalation // "") != "")}]
                    | sort_by(.at) | reverse,
      discovered: [.[] | . as $a | (.discovered // [])[] | {name: $a.name, message, at}],
      worktrees: $wts
    }'
}

if [ "${1:-}" = "--summary" ]; then shift; summary "$@"; exit 0; fi
require_herdr

target="${1:?usage: retire.sh <team | team/role> [--outcome O]}"; shift
outcome=""; [ "${1:-}" = "--outcome" ] && outcome="${2:-}"

rows="$("$registry" list | jq --arg x "$target" '[.[] | select((.name == $x or .team == $x) and .status != "Retired")]')"
[ "$(printf '%s' "$rows" | jq length)" != "0" ] || die "nothing live matches '$target'"

kept="[]"; kept_envs="[]"; kept_untracked="{}"
whole_team=false; printf '%s' "$rows" | jq -e --arg x "$target" 'all(.team == $x)' >/dev/null && [ "${target%%/*}" = "$target" ] && whole_team=true

if $whole_team; then
  env_state="$("$registry" env-get "$target" 2>/dev/null | jq -r '.state // "Down"' || true)"
  if [ -n "$env_state" ] && [ "$env_state" != "Down" ]; then
    "$FLEET_SCRIPTS/env.sh" down "$target" >&2 ||
      { warn "kept environment of $target: env.sh down failed"; kept_envs="$(jq -cn --arg t "$target" '[$t]')"; }
  fi
  ws="$(printf '%s' "$rows" | jq -r '[.[].workspace | select(. != null and . != "")] | first // ""')"
  [ -n "$ws" ] && { hd workspace close "$ws" >/dev/null 2>&1 || warn "could not close workspace $ws"; }
else
  for pane in $(printf '%s' "$rows" | jq -r '.[].pane // empty'); do
    hd pane close "$pane" >/dev/null 2>&1 || warn "could not close pane $pane"
  done
fi

while IFS=$'\t' read -r wt repo; do
  [ -d "$wt" ] || continue
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null | head -3 | tr '\n' ' ')"
  if [ -n "$dirty" ]; then
    warn "kept $wt: uncommitted changes ($dirty)"; kept="$(printf '%s' "$kept" | jq -c --arg w "$wt" '. + [$w]')"
    # Name every untracked file: they are what a retired agent's report or notes are made of.
    untracked="$(untracked_in "$wt")"
    if [ -n "$untracked" ]; then
      while IFS= read -r f; do warn "  untracked in $wt: ?? $f"; done <<<"$untracked"
      kept_untracked="$(printf '%s' "$kept_untracked" | jq -c --arg w "$wt" --arg u "$untracked" '. + {($w): ($u | split("\n"))}')"
    fi
  else
    git -C "$repo" worktree remove "$wt" 2>/dev/null || { warn "kept $wt: git worktree remove failed"; kept="$(printf '%s' "$kept" | jq -c --arg w "$wt" '. + [$w]')"; }
  fi
done < <(printf '%s' "$rows" | jq -r '.[] | select((.worktree // "") != "") | [.worktree, .repo] | @tsv')

if [ -n "$outcome" ]; then "$registry" retire "$target" --outcome "$outcome"; else "$registry" retire "$target"; fi
printf '%s' "$rows" | jq --argjson kept "$kept" --argjson ke "$kept_envs" --argjson ku "$kept_untracked" '{retired: [.[].name], kept_worktrees: $kept} + (if ($ke | length) > 0 then {kept_envs: $ke} else {} end) + (if ($ku | length) > 0 then {kept_untracked: $ku} else {} end)'
