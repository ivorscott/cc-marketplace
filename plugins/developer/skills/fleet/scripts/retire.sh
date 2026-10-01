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
# Never closes panes or workspaces the registry doesn't record as fleet-created. Worktrees
# are big (node_modules, build output), so a retire removes them, but only after looking:
#   - build outputs (node_modules/, *.tsbuildinfo, dist/, .next/, coverage/) are ignored;
#   - untracked reports (*.md at the worktree root or under reports/) are copied to
#     <archive>/<team>-<role>/ (verified with cmp) and then the worktree is removed;
#   - a worktree is KEPT, and the files or commits named, when it has unpushed commits,
#     untracked source files or uncommitted edits to tracked files. A kept worktree is
#     never force-removed. JSON: kept_untracked (source files), kept_unpushed, kept_modified,
#     archived ({worktree: archive dir}); the last three appear only when non-empty.
# The archive root is $FLEET_ARCHIVE_DIR, default $PWD/reports/fleet-archive (the
# Orchestrator's own reports/). Retiring a
# whole team also runs `env.sh down <team>` for its test cluster (only one the registry
# created); if that fails the env is kept and reported.
set -euo pipefail
. "$(dirname "$0")/common.sh"
registry="$FLEET_SCRIPTS/registry.sh"

# is_build <path>: a build output at any depth (node_modules/, *.tsbuildinfo, dist/, .next/, coverage/).
is_build() {
  case "/$1" in
    */node_modules | */node_modules/* | */dist | */dist/* | */.next | */.next/* | */coverage | */coverage/* | *.tsbuildinfo) return 0 ;;
  esac
  return 1
}

# untracked_in <worktree>: one untracked, non-build-output path per line. Collapsed
# directories are listed (never walked inside node_modules) and expanded only if not build output.
untracked_in() {
  local p f
  while IFS= read -r p; do
    is_build "$p" && continue
    if [ "${p%/}" != "$p" ]; then
      while IFS= read -r f; do is_build "$f" || printf '%s\n' "$f"; done < <(git -C "$1" ls-files --others --exclude-standard -- "$p" 2>/dev/null)
    else printf '%s\n' "$p"; fi
  done < <(git -C "$1" status --porcelain --untracked-files=normal 2>/dev/null | sed -n 's/^?? //p')
}

# is_report <path>: an *.md at the worktree root or anywhere under a reports/ directory.
is_report() {
  case "$1" in
    */*) case "$1" in reports/*.md | */reports/*.md) return 0 ;; esac ;;
    *.md) return 0 ;;
  esac
  return 1
}

# classify <worktree>: sets C_REPORTS, C_SOURCE (untracked, one per line), C_UNPUSHED (short
# SHAs) and C_MODIFIED (tracked changes, `git status` format) for what a retire must keep or archive.
classify() {
  local f
  C_REPORTS=""; C_SOURCE=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_report "$f"; then C_REPORTS="$C_REPORTS${C_REPORTS:+$'\n'}$f"; else C_SOURCE="$C_SOURCE${C_SOURCE:+$'\n'}$f"; fi
  done < <(untracked_in "$1")
  # No remote at all means nowhere to push to: nothing counts as unpushed.
  C_UNPUSHED=""
  [ -z "$(git -C "$1" remote 2>/dev/null)" ] || C_UNPUSHED="$(git -C "$1" rev-list --abbrev-commit HEAD --not --remotes 2>/dev/null || true)"
  C_MODIFIED="$(git -C "$1" status --porcelain --untracked-files=no 2>/dev/null || true)"
}

# lines_json <text>: a JSON array of the non-empty lines.
lines_json() { printf '%s' "$1" | jq -Rsc 'split("\n") | map(select(. != ""))'; }

# archive_reports <worktree> <name>: copy C_REPORTS to <archive>/<team>-<role>/ and verify each copy.
archive_reports() {
  local dest="${FLEET_ARCHIVE_DIR:-$PWD/reports/fleet-archive}/${2//\//-}" f
  ARCHIVE_DIR="$dest"
  [ -n "$C_REPORTS" ] || return 0
  while IFS= read -r f; do
    mkdir -p "$dest/$(dirname "$f")" && cp -p "$1/$f" "$dest/$f" && cmp -s "$1/$f" "$dest/$f" || return 1
  done <<<"$C_REPORTS"
}

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
  local rows="[]" t r wts="[]" repos="{}" wt repo keep
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
    classify "$wt"
    keep=false; [ -z "$C_SOURCE$C_UNPUSHED$C_MODIFIED" ] || keep=true
    wts="$(printf '%s' "$wts" | jq -c --arg w "$wt" --arg b "$(git -C "$wt" branch --show-current 2>/dev/null)" \
      --argjson k "$keep" --argjson u "$(lines_json "$C_SOURCE")" --argjson a "$(lines_json "$C_REPORTS")" \
      --argjson p "$(lines_json "$C_UNPUSHED")" --argjson m "$(lines_json "$C_MODIFIED")" \
      '. + [{path: $w, branch: $b, kept: $k, untracked: $u, archive: $a, unpushed: $p, modified: $m}]')"
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

kept_unpushed="{}"; kept_modified="{}"; archived="{}"
keep_wt() { kept="$(printf '%s' "$kept" | jq -c --arg w "$1" '. + [$w]')"; }
while IFS=$'\t' read -r wt repo wname; do
  [ -d "$wt" ] || continue
  classify "$wt"
  if [ -n "$C_SOURCE$C_UNPUSHED$C_MODIFIED" ]; then
    warn "kept $wt: it holds work that is not pushed or not tracked"; keep_wt "$wt"
    if [ -n "$C_UNPUSHED" ]; then
      warn "  unpushed commits in $wt: $(printf '%s' "$C_UNPUSHED" | tr '\n' ' ')"
      kept_unpushed="$(printf '%s' "$kept_unpushed" | jq -c --arg w "$wt" --argjson u "$(lines_json "$C_UNPUSHED")" '. + {($w): $u}')"
    fi
    if [ -n "$C_MODIFIED" ]; then
      while IFS= read -r f; do warn "  uncommitted in $wt: $f"; done <<<"$C_MODIFIED"
      kept_modified="$(printf '%s' "$kept_modified" | jq -c --arg w "$wt" --argjson u "$(lines_json "$C_MODIFIED")" '. + {($w): $u}')"
    fi
    if [ -n "$C_SOURCE" ]; then
      while IFS= read -r f; do warn "  untracked in $wt: ?? $f"; done <<<"$C_SOURCE"
      kept_untracked="$(printf '%s' "$kept_untracked" | jq -c --arg w "$wt" --argjson u "$(lines_json "$C_SOURCE")" '. + {($w): $u}')"
    fi
  elif ! archive_reports "$wt" "$wname"; then
    warn "kept $wt: could not archive its reports to $ARCHIVE_DIR"; keep_wt "$wt"
  elif git -C "$repo" worktree remove --force "$wt" 2>/dev/null; then
    # --force only because build outputs are untracked; classify proved nothing else is there.
    if [ -n "$C_REPORTS" ]; then
      warn "archived $(printf '%s\n' "$C_REPORTS" | grep -c .) report(s) from $wt to $ARCHIVE_DIR"
      archived="$(printf '%s' "$archived" | jq -c --arg w "$wt" --arg d "$ARCHIVE_DIR" '. + {($w): $d}')"
    fi
  else warn "kept $wt: git worktree remove failed"; keep_wt "$wt"; fi
done < <(printf '%s' "$rows" | jq -r '.[] | select((.worktree // "") != "") | [.worktree, .repo, .name] | @tsv')

if [ -n "$outcome" ]; then "$registry" retire "$target" --outcome "$outcome"; else "$registry" retire "$target"; fi
printf '%s' "$rows" | jq --argjson kept "$kept" --argjson ke "$kept_envs" --argjson ku "$kept_untracked" \
  --argjson kp "$kept_unpushed" --argjson km "$kept_modified" --argjson ar "$archived" '{retired: [.[].name], kept_worktrees: $kept}
  + (if ($ke | length) > 0 then {kept_envs: $ke} else {} end) + (if ($ku | length) > 0 then {kept_untracked: $ku} else {} end)
  + (if ($kp | length) > 0 then {kept_unpushed: $kp} else {} end) + (if ($km | length) > 0 then {kept_modified: $km} else {} end)
  + (if ($ar | length) > 0 then {archived: $ar} else {} end)'
