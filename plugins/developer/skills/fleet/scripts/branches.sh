#!/usr/bin/env bash
# Delete a repo's stale remote branches, the ones that are safe to delete: a merged or closed PR's branch, or a branch
# with no PR whose every commit is already in the default branch.
#
#   branches.sh [<repo>] [--dry-run]
#
# <repo> is a path or an entry of `repos` in config.toml (by path, folder name or owner/name); it defaults to the repo of
# the current directory. It runs `git fetch --prune origin`, decides every remote branch with common.sh branch_verdict, and
# prints two tables, Delete and Keep, each branch with its reason. Never deleted: the default branch, release/*,
# renovate/*, a branch with an open PR, another machine's branch while its claim is live (or its holder cannot be read),
# a branch a live team of this machine names, a branch with no PR and commits that are not in the default branch, and any
# branch whose PR state gh cannot read. Deletes are `git push origin --delete <branch>`, one at a time, never forced; a
# delete that fails is a warning and the branch is listed under Keep.
#
# --dry-run prints the same tables and deletes nothing (and does not need the permission rule). A real run needs
# Bash(git push origin --delete:*) in permissions.allow (the user settings, or the repo's .claude/settings*.json); without
# it nothing is deleted and one line says how to add it. Only `fleet run init` adds that rule, after the owner's yes.
# tick runs this once a day per configured repo (the Branches deleted section of the morning report); retire runs the
# same rules on a retired team's own branches.
# Command: Delete a repo's stale remote branches that are safe to delete · e.g. fleet branches --dry-run
set -euo pipefail
. "$(dirname "$0")/common.sh"

usage() { sed -n '2,/^# Command:/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

dry=false; repo_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=true; shift ;;
    -h | --help | help) usage; exit 0 ;;
    -*) die "unknown option: $1" "Run fleet help branches" ;;
    *) [ -z "$repo_arg" ] || die "one repo at a time: $repo_arg and $1" "Run fleet help branches"; repo_arg="$1"; shift ;;
  esac
done

# resolve_repo <arg>: a directory, or the `repos` entry whose path, folder name or owner/name is <arg>
resolve_repo() {
  local a="$1" r
  if [ -z "$a" ]; then git rev-parse --show-toplevel 2>/dev/null || die "not in a git repo" "Run it from a repo or name one: fleet branches <repo>"; return; fi
  if [ -d "$a" ]; then (cd "$a" && git rev-parse --show-toplevel 2>/dev/null) || die "$a is not a git repo"; return; fi
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if [ "$(basename "$r")" = "$a" ] || [ "$(repo_slug "$r")" = "$a" ]; then printf '%s\n' "$r"; return; fi
  done < <(config_list repos | jq -r '.[]')
  die "no repo '$a'" "Give a path, or a repos entry of config.toml"
}
repo="$(resolve_repo "$repo_arg")"
[ -n "$(git -C "$repo" remote get-url origin 2>/dev/null)" ] || die "$repo has no origin remote"
git -C "$repo" fetch --prune origin >/dev/null 2>&1 || die "git fetch --prune origin failed in $repo" "Check the network and the remote, then run it again"
def="$(default_branch "$repo")"
[ -n "$def" ] || die "cannot tell the default branch of $repo" "Run git remote set-head origin --auto in it"
name="$(repo_slug "$repo")"; [ -n "$name" ] || name="$(basename "$repo")"

del_rows=""; keep_rows=""; ndel=0; nkeep=0
add_keep() { keep_rows="$keep_rows| $1 | $(printf '%s' "$2" | tr '|' '/') |"$'\n'; nkeep=$((nkeep + 1)); }
add_del() { del_rows="$del_rows$1"$'\t'"$2"$'\n'; ndel=$((ndel + 1)); }
while IFS= read -r b; do
  [ -n "$b" ] && [ "$b" != HEAD ] || continue
  v="$(branch_verdict "$repo" "$b" "$def")"
  if [ "${v%%$'\t'*}" = delete ]; then add_del "$b" "${v#*$'\t'}"; else add_keep "$b" "${v#*$'\t'}"; fi
done < <(git -C "$repo" for-each-ref --format='%(refname:strip=3)' refs/remotes/origin/ | sort)

deleted=""; off=""; ndeleted=0
if ! $dry && [ "$ndel" -gt 0 ]; then
  if branch_delete_allowed "$repo"; then
    while IFS=$'\t' read -r b why; do
      [ -n "$b" ] || continue
      if branch_delete "$repo" "$b" "$def"; then deleted="$deleted$b"$'\t'"$why"$'\n'; ndeleted=$((ndeleted + 1)); ev_log branches_deleted name="$name" detail="$b (${why%% http*})"
      else warn "could not delete $b in $name"; add_keep "$b" "delete failed"; fi
    done <<<"$del_rows"
  else off="$BRANCH_OFF_LINE"; fi
fi

if $dry; then head="Branches of $name: $ndel to delete, $nkeep kept. Dry run: nothing deleted."
elif [ -n "$off" ]; then head="Branches of $name: $ndel to delete, $nkeep kept. $off."
else head="Branches of $name: deleted $ndeleted, kept $nkeep."; fi
dtab=""
if $dry || [ -n "$off" ]; then
  [ "$ndel" -eq 0 ] || dtab="$(printf '### Delete\n\n| Branch | Why |\n|---|---|\n'; while IFS=$'\t' read -r b why; do [ -z "$b" ] || printf '| %s | %s |\n' "$b" "$why"; done <<<"$del_rows")"
else
  [ "$ndeleted" -eq 0 ] || dtab="$(printf '### Deleted\n\n| Branch | Why |\n|---|---|\n'; while IFS=$'\t' read -r b why; do [ -z "$b" ] || printf '| %s | %s |\n' "$b" "$why"; done <<<"$deleted")"
fi
ktab=""
[ "$nkeep" -eq 0 ] || ktab="$(printf '### Keep\n\n| Branch | Why |\n|---|---|\n%s' "$keep_rows")"
reply "$head" "$dtab" "${ktab%$'\n'}"
