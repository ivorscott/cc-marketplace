#!/usr/bin/env bash
# What a worktree holds that only it holds, shared by retire.sh (keep a worktree that has it) and park.sh
# (refuse to park a team that has it). Source it; don't run it. Needs jq.

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
