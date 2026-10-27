#!/usr/bin/env bash
# Retire a team or one agent: close what /fleet created, remove clean worktrees, and
# mark the rows Retired. Ask the agents to push WIP and summarise BEFORE running this.
#
#   retire.sh <team | team/role> [--outcome O] [--verify]
#   retire.sh --summary <team | team/role> [...]
#
# Retiring a whole team also moves its issue on Linear, once per issue and only while linear_writes allows writes (a
# failure warns, never fails the retire): Shipped → Done, or Verify with --verify, once every PR of the issue merged (an
# open PR leaves it as it is, with a warning); Abandoned or Failed, or no outcome reported (shown as Abandoned) → Todo,
# and this machine's claim is released. A PR whose body says it is "Part of" another issue (any case, before an issue
# reference) leaves the issue In Progress with its label. The Retired line then ends "Issue → <state>.".
#
# --summary changes nothing, and a retire never waits on it: it is how to read what a retire would keep. It prints, per target:
#   Retire <team>? Outcome <X>. Unpushed: <none|list>. Kept: <none|list>. Reply yes to retire.
# (the outcomes the rows reported, Abandoned when none did; the worktrees with commits on no remote; every worktree
# a retire would keep, with why). A retire prints
#   Retired <team> (<outcome>): PRs <links|none>. Archived to <path>. Kept: <list>.
# ("Nothing archived." when no report was copied; "Kept: ..." only when something was kept), then the team table
# (references/output.md). The files and commits that kept a worktree are named on stderr.
#
# A team name with no live rows but leftovers of an earlier boot (worktrees under $FLEET_WORKTREES/<team>, fleet/<team>/*
# branches: an interrupted boot, or a retire that kept work) is tidied instead of refused: what would lose nothing is
# removed, the rest kept and named (boot refuses a name with leftovers and names this).
# Never closes panes or workspaces the registry doesn't record as fleet-created. Worktrees
# are big (node_modules, build output), so a retire removes them, but only after looking:
#   - build outputs (node_modules/, *.tsbuildinfo, dist/, .next/, coverage/, .terraform/, test-results/, bin/) are
#     ignored;
#   - untracked reports (*.md at the worktree root or under reports/) are copied to
#     <archive>/<team>-<role>/ (verified with cmp) and then the worktree is removed;
#   - a worktree is KEPT, and the files or commits named, when it has unpushed commits,
#     untracked source files or uncommitted edits to tracked files. A kept worktree is
#     never force-removed. A retire also closes the rows' open escalations ("closed at retire").
# The archive root is the team repo's reports/fleet-archive (the row's repo; $FLEET_ARCHIVE_DIR overrides it). Once a
# whole team's worktrees are gone, its empty $FLEET_WORKTREES/<team> directory goes too. Retiring a
# whole team also runs `env.sh down <team>` for its test cluster (only one the registry
# created); if that fails the env is kept and reported.
# Command: Shut a team (or one agent) down safely · e.g. fleet retire build-api --outcome Shipped
set -euo pipefail
. "$(dirname "$0")/common.sh"
registry="$FLEET_SCRIPTS/registry.sh"

# is_build <path>: a build output at any depth (node_modules/, *.tsbuildinfo, dist/, .next/, coverage/, .terraform/,
# test-results/, bin/).
is_build() {
  case "/$1" in
    */node_modules | */node_modules/* | */dist | */dist/* | */.next | */.next/* | */coverage | */coverage/* | *.tsbuildinfo) return 0 ;;
    */.terraform | */.terraform/* | */test-results | */test-results/* | */bin | */bin/*) return 0 ;;
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

# keep_why: what in the last classified worktree keeps it ("unpushed commits, untracked files"); empty when nothing.
keep_why() {
  local w=""
  [ -z "$C_UNPUSHED" ] || w="unpushed commits"
  [ -z "$C_MODIFIED" ] || w="$w${w:+, }uncommitted changes"
  [ -z "$C_SOURCE" ] || w="$w${w:+, }untracked files"
  printf '%s' "$w"
}

# archive_reports <worktree> <name> <repo>: copy C_REPORTS to <archive>/<team>-<role>/ and verify each copy. The
# archive is the team repo's reports/fleet-archive ($FLEET_ARCHIVE_DIR overrides it), kept out of that repo's git
# through its .git/info/exclude, so a `git add -A` in the main checkout never commits fleet reports.
archive_reports() {
  local dest="${FLEET_ARCHIVE_DIR:-${3:-$PWD}/reports/fleet-archive}/${2//\//-}" f
  ARCHIVE_DIR="$dest"
  [ -n "$C_REPORTS" ] || return 0
  [ -n "${FLEET_ARCHIVE_DIR:-}" ] || git_exclude "${3:-$PWD}" 'reports/fleet-archive/'
  while IFS= read -r f; do
    mkdir -p "$dest/$(dirname "$f")" && cp -p "$1/$f" "$dest/$f" && cmp -s "$1/$f" "$dest/$f" || return 1
  done <<<"$C_REPORTS"
}

# summary <target...>: one "Retire <target>? ..." line per target: the outcome the rows reported (Abandoned when
# none did), the worktrees with commits on no remote, and every worktree a retire would keep, with why.
summary() {
  [ "$#" -gt 0 ] || die "usage: retire.sh --summary <team | team/role> [...]"
  local t r wt role unp kept why nc
  for t in "$@"; do
    r="$("$registry" list | jq -c --arg x "$t" '[.[] | select((.name == $x or .team == $x) and .status != "Retired")]')"
    [ "$(printf '%s' "$r" | jq length)" != "0" ] || die "nothing live matches '$t'" "Run fleet status for the teams"
    unp=""; kept=""
    while IFS=$'\t' read -r wt role; do
      [ -d "$wt" ] || continue
      classify "$wt"
      if [ -n "$C_UNPUSHED" ]; then
        nc="$(printf '%s\n' "$C_UNPUSHED" | grep -c .)"; unp="$unp${unp:+, }$role ($nc commit$([ "$nc" = 1 ] || echo s))"
      fi
      why="$(keep_why)"; [ -z "$why" ] || kept="$kept${kept:+, }$role ($why)"
    done < <(printf '%s' "$r" | jq -r '.[] | select((.worktree // "") != "") | [.worktree, (.name | split("/")[1:] | join("/"))] | @tsv')
    render_line retire_ask team="$t" outcome="$(printf '%s' "$r" | jq -r '[.[].outcome // empty | select(. != "")] | unique | join("/")')" unpushed="$unp" kept="$kept"
  done
}

if [ "${1:-}" = "--summary" ]; then shift; summary "$@"; exit 0; fi
require_herdr

target="${1:?usage: retire.sh <team | team/role> [--outcome O] [--verify]}"; shift
outcome=""; verify=false
while [ $# -gt 0 ]; do
  case "$1" in
    --outcome) outcome="${2:-}"; shift; [ $# = 0 ] || shift ;;
    --verify) verify=true; shift ;;
    *) die "unknown option: $1" "Run fleet help retire" ;;
  esac
done

kept=""; archived=""
keep() { kept="$kept${kept:+, }$1 ($2)"; } # keep <what> <why>: named on the Retired line

# leftovers <team>: no live rows, but an earlier boot of the name left worktrees under $FLEET_WORKTREES/<team> or
# fleet/<team>/* branches (an interrupted boot, or a retire that kept work). Each is removed when nothing on it would be
# lost: a worktree as classify says, its untracked reports archived first as a live retire does; a branch with git
# branch -D only when none of its commits is on no other branch and no remote. The rest are kept and named. Returns 1
# when there is nothing.
leftovers() {
  local team="$1" wt r b n why role repos="" found=0
  for wt in "$FLEET_WORKTREES/$team"/*; do
    [ -d "$wt" ] || continue
    found=1; role="$(basename "$wt")"
    r="$(git -C "$wt" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
    repos="$repos${r:+$r$'\n'}"
    classify "$wt"; why="$(keep_why)"
    if [ -n "$why" ]; then warn "kept $wt: $why"; keep "$role" "$why"
    elif [ -z "$r" ]; then keep "$role" "git worktree remove failed"
    elif ! archive_reports "$wt" "$team/$role" "$r"; then warn "kept $wt: could not archive its reports to $ARCHIVE_DIR"; keep "$role" "its reports could not be archived"
    elif git -C "$r" worktree remove --force "$wt" 2>/dev/null; then
      if [ -n "$C_REPORTS" ]; then warn "archived $(printf '%s\n' "$C_REPORTS" | grep -c .) report(s) from $wt to $ARCHIVE_DIR"; archived="$(dirname "$ARCHIVE_DIR")"; fi
    else keep "$role" "git worktree remove failed"; fi
  done
  repos="$(printf '%s%s\n' "$repos" "$("$registry" list | jq -r --arg t "$team" '.[] | select(.team == $t) | .repo // empty')" | grep . | sort -u || true)"
  while IFS= read -r r; do
    [ -d "$r" ] || continue
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      found=1
      ! grep -qx "branch refs/heads/$b" <<<"$(git -C "$r" worktree list --porcelain 2>/dev/null)" || continue # held by a kept worktree
      n="$(git -C "$r" rev-list "$b" --not --exclude="refs/heads/$b" --branches --remotes 2>/dev/null | grep -c . || true)"
      if [ "$n" = 0 ]; then git -C "$r" branch -D "$b" >/dev/null 2>&1 || keep "$b" "git branch -D failed"
      else warn "kept branch $b in $r: $n commit(s) on no other branch or remote"; keep "$b" "$n commit$([ "$n" = 1 ] || echo s) on no other branch or remote"; fi
    done < <(git -C "$r" for-each-ref --format='%(refname:short)' "refs/heads/fleet/$team/" 2>/dev/null)
  done <<<"$repos"
  rmdir "$FLEET_WORKTREES/$team" 2>/dev/null || true
  [ "$found" = 1 ]
}

rows="$("$registry" list | jq --arg x "$target" '[.[] | select((.name == $x or .team == $x) and .status != "Retired")]')"
if [ "$(printf '%s' "$rows" | jq length)" = "0" ]; then
  if [ "${target%%/*}" = "$target" ] && leftovers "$target"; then
    reply "$(render_line retired team="$target" outcome="${outcome:-Abandoned}" archived="$archived" kept="$kept")" "$(render_table)"
    exit 0
  fi
  die "nothing live matches '$target'"
fi
whole_team=false; printf '%s' "$rows" | jq -e --arg x "$target" 'all(.team == $x)' >/dev/null && [ "${target%%/*}" = "$target" ] && whole_team=true

if $whole_team; then
  env_state="$("$registry" env-get "$target" 2>/dev/null | jq -r '.state // "Down"' || true)"
  if [ -n "$env_state" ] && [ "$env_state" != "Down" ]; then
    "$FLEET_SCRIPTS/env.sh" down "$target" >&2 ||
      { warn "kept environment of $target: env.sh down failed"; keep "test cluster" "env.sh down failed"; }
  fi
  ws="$(printf '%s' "$rows" | jq -r '[.[].workspace | select(. != null and . != "")] | first // ""')"
  [ -n "$ws" ] && { hd workspace close "$ws" >/dev/null 2>&1 || warn "could not close workspace $ws"; }
else
  for pane in $(printf '%s' "$rows" | jq -r '.[].pane // empty'); do
    hd pane close "$pane" >/dev/null 2>&1 || warn "could not close pane $pane"
  done
fi

while IFS=$'\t' read -r wt repo wname; do
  [ -d "$wt" ] || continue
  classify "$wt"; role="${wname#*/}"
  if [ -n "$C_SOURCE$C_UNPUSHED$C_MODIFIED" ]; then
    warn "kept $wt: it holds work that is not pushed or not tracked"; keep "$role" "$(keep_why)"
    [ -z "$C_UNPUSHED" ] || warn "  unpushed commits in $wt: $(printf '%s' "$C_UNPUSHED" | tr '\n' ' ')"
    if [ -n "$C_MODIFIED" ]; then while IFS= read -r f; do warn "  uncommitted in $wt: $f"; done <<<"$C_MODIFIED"; fi
    if [ -n "$C_SOURCE" ]; then while IFS= read -r f; do warn "  untracked in $wt: ?? $f"; done <<<"$C_SOURCE"; fi
  elif ! archive_reports "$wt" "$wname" "$repo"; then
    warn "kept $wt: could not archive its reports to $ARCHIVE_DIR"; keep "$role" "its reports could not be archived"
  elif git -C "$repo" worktree remove --force "$wt" 2>/dev/null; then
    # --force only because build outputs are untracked; classify proved nothing else is there.
    if [ -n "$C_REPORTS" ]; then
      warn "archived $(printf '%s\n' "$C_REPORTS" | grep -c .) report(s) from $wt to $ARCHIVE_DIR"
      archived="$(dirname "$ARCHIVE_DIR")"
    fi
  else warn "kept $wt: git worktree remove failed"; keep "$role" "git worktree remove failed"; fi
done < <(printf '%s' "$rows" | jq -r '.[] | select((.worktree // "") != "") | [.worktree, .repo, .name] | @tsv')
! $whole_team || rmdir "$FLEET_WORKTREES/$target" 2>/dev/null || true # the team's own worktrees directory, once empty
# The planner's plan goes with its team: .fleet/plan/<team>.md in the team's repo (and the folders, once empty).
if $whole_team; then
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    rm -f "$r/.fleet/plan/$target.md"; rmdir "$r/.fleet/plan" "$r/.fleet" 2>/dev/null || true
  done < <(printf '%s' "$rows" | jq -r '[.[].repo // empty | select(. != "")] | unique[]')
fi

if [ -n "$outcome" ]; then "$registry" retire "$target" --outcome "$outcome"; else "$registry" retire "$target"; fi
for n in $(printf '%s' "$rows" | jq -r '.[].name'); do ev_log retired team="$(printf '%s' "$rows" | jq -r --arg n "$n" '.[] | select(.name == $n) | .team')" name="$n"; done
outcomes="$("$registry" list | jq -r --argjson names "$(printf '%s' "$rows" | jq -c '[.[].name]')" '[.[] | select(.name as $n | $names | index($n)) | .outcome // empty] | unique | join("/")')"
prs="$(printf '%s' "$rows" | jq -r '[.[] | (.pr // empty), (.prs // [])[] | select(. != "")] | unique[]' | while IFS= read -r u; do pr_link "$u"; done | paste -sd, - | sed 's/,/, /g')"

# Linear: a whole team's issue follows its outcome, once per issue and only while linear_writes allows writes; a
# failure warns and never fails the retire. Shipped → Done (Verify with --verify), only once every PR of the issue
# merged (an open one leaves it as it is, to move when it merges); Abandoned or Failed, or no outcome at all (which the
# Retired line shows as Abandoned) → Todo, and this machine's claim is released. A PR whose body says it is "Part of"
# another issue (PART_OF_JQ: one slice of a bigger issue) leaves the issue In Progress with its label.
issue_state=""
case "${outcomes:-Abandoned}" in Shipped) want=Done; ! $verify || want=Verify ;; Abandoned | Failed) want=Todo ;; *) want="" ;; esac
if $whole_team && [ -n "$want" ] && [ "$(linear_writes)" != off ] && "$FLEET_SCRIPTS/linear.sh" has-key >/dev/null 2>&1; then
  lerr="$(mktemp "${TMPDIR:-/tmp}/fleet-retire.XXXXXX")"
  while IFS= read -r iss; do
    [ -n "$iss" ] || continue
    partof=false; unmerged=""
    for u in $(printf '%s' "$rows" | jq -r --arg i "$iss" '[.[] | select(.issue == $i) | (.pr // empty), (.prs // [])[] | select(. != "")] | unique[]'); do
      j="$(forge_pr_json "$u" 2>/dev/null)" || j='{}'
      if jq -e "$PART_OF_JQ"'(.body // "") | part_of != null' >/dev/null 2>&1 <<<"$j"; then partof=true; fi
      [ "$want" = Todo ] || [ "$(jq -r '.state // ""' <<<"$j" 2>/dev/null)" = MERGED ] || unmerged="$unmerged${unmerged:+, }$u"
    done
    if $partof; then warn "$iss stays In Progress: its PR is part of a bigger issue"; continue; fi
    if [ -n "$unmerged" ]; then warn "$iss stays as it is: $unmerged is not merged (or could not be read); move it to $want once it merges"; continue; fi
    if "$FLEET_SCRIPTS/linear.sh" state "$iss" "$want" >/dev/null 2>"$lerr"; then issue_state="$want"
    else warn "could not move $iss to $want on Linear: $(tail -n 1 "$lerr")"; continue; fi
    [ "$want" != Todo ] || "$FLEET_SCRIPTS/linear.sh" release "$iss" >/dev/null 2>"$lerr" || warn "could not release $iss on Linear: $(tail -n 1 "$lerr")"
  done < <(printf '%s' "$rows" | jq -r '[.[].issue // empty | select(. != "")] | unique[]')
  rm -f "$lerr"
fi

"$registry" archive >/dev/null || warn "archive failed; retired rows stay in the live registry"
# One agent retired: its team's panel shows the rest (a whole team's workspace is closed with it).
$whole_team || herdr_meta "${target%%/*}"
reply "$(render_line retired team="$target" outcome="$outcomes" prs="$prs" archived="$archived" kept="$kept" issue_state="$issue_state")" "$(render_table)"
