#!/usr/bin/env bash
# 4.2.6 cases (DEV-691): a team's worktrees branch from the fresh default branch on origin. Sourced by run.sh after
# v42x.sh, which gives it v42x_boot_state, v42x_boot and the helpers. A new file so the shared test files see as few
# edits as possible. No network: origins are local bare repos.
v426_g() { git -c user.email=t@t -c user.name=t "$@"; }
v426_fixture() { # v426_fixture <state name> [default branch]: state, a bare origin and a clone one commit behind it (clone in $V426_C, origin tip in $V426_NEW, clone tip in $V426_OLD)
  v42x_boot_state "$1" L2 'machines = 1'
  local br="${2:-main}" o="$FLEET_STATE_DIR/origin.git" up="$FLEET_STATE_DIR/upstream"
  V426_C="$FLEET_STATE_DIR/clone"
  git init -q --bare -b "$br" "$o"; git clone -q "$o" "$V426_C" 2>/dev/null
  v426_g -C "$V426_C" checkout -q -b "$br" 2>/dev/null; v426_g -C "$V426_C" commit -q --allow-empty -m base; git -C "$V426_C" push -q origin "$br" 2>/dev/null
  git -C "$o" symbolic-ref HEAD "refs/heads/$br"; git -C "$V426_C" remote set-head origin "$br" >/dev/null 2>&1 || true
  git clone -q "$o" "$up" 2>/dev/null; v426_g -C "$up" commit -q --allow-empty -m newer; git -C "$up" push -q origin "$br" 2>/dev/null
  V426_OLD="$(git -C "$V426_C" rev-parse HEAD)"; V426_NEW="$(git -C "$up" rev-parse HEAD)"
}
v426_wt() { "$REG" get "build-$1/$2" | jq -r .worktree; } # v426_wt <focus> <role>
v426_idle() { local r; for r in lead planner builder tester; do echo idle >"$AS/build-$1-$r"; done; } # the agents are at a safe point

v426_freshbase() { # origin ahead of the clone; the user's checkout stays put; the reply names the base
  v426_fixture fresh
  local rc; rc="$(v42x_boot --no-issue build fb "$V426_C" task)"
  eq "v426 fresh: builder and tester start at the fetched origin/main, not the stale local HEAD" \
    "$rc:$(git -C "$(v426_wt fb builder)" rev-parse HEAD):$(git -C "$(v426_wt fb tester)" rev-parse HEAD)" "0:$V426_NEW:$V426_NEW"
  eq "v426 fresh: the user's checkout keeps its HEAD and branch" "$(git -C "$V426_C" rev-parse HEAD):$(git -C "$V426_C" branch --show-current)" "$V426_OLD:main"
  eq "v426 fresh: the branch does not track origin/main" "$(git -C "$(v426_wt fb builder)" config --get branch.fleet/build-fb/builder.remote || echo none)" none
  check "v426 fresh: the reply names the base ref and its short sha" grep -q "branched from origin/main at $(git -C "$V426_C" rev-parse --short "$V426_NEW")" "$FLEET_STATE_DIR/boot.out"
}
v426_offline() { # an unreachable origin, and no origin at all: boot goes on from the local default branch and warns
  v426_fixture offline
  git -C "$V426_C" remote set-url origin "$FLEET_STATE_DIR/gone.git"
  local rc; rc="$(v42x_boot --no-issue build fo "$V426_C" task)"
  eq "v426 offline: an unreachable origin boots from the local branch and warns" \
    "$rc:$(git -C "$(v426_wt fo builder)" rev-parse HEAD):$(grep -c 'could not fetch origin' "$FLEET_STATE_DIR/boot.err")" "0:$V426_OLD:1"
  git -C "$V426_C" remote remove origin
  rc="$(v42x_boot --no-issue build fn "$V426_C" task)"
  eq "v426 offline: no origin remote boots from the local branch and warns" \
    "$rc:$(git -C "$(v426_wt fn builder)" rev-parse HEAD):$(grep -c 'could not fetch origin' "$FLEET_STATE_DIR/boot.err")" "0:$V426_OLD:1"
}
v426_trunk() { # origin/HEAD points at trunk; a clone with no origin/<default> ref yet still works (fetch comes first)
  v426_fixture trunk trunk
  local rc; rc="$(v42x_boot --no-issue build tr "$V426_C" task)"
  eq "v426 trunk: branches from origin/trunk" "$rc:$(git -C "$(v426_wt tr builder)" rev-parse HEAD)" "0:$V426_NEW"
  git -C "$V426_C" update-ref -d refs/remotes/origin/trunk; git -C "$V426_C" update-ref -d refs/remotes/origin/HEAD
  rc="$(v42x_boot --no-issue build tr2 "$V426_C" task)"
  eq "v426 trunk: with no origin refs yet it fetches first and still finds origin/trunk" \
    "$rc:$(git -C "$(v426_wt tr2 builder)" rev-parse HEAD)" "0:$V426_NEW"
}
v426_next() { # next moves a clean worktree to the fresh base and leaves a dirty or unpushed one alone, with a warning
  v426_fixture next
  v42x_boot --no-issue build nx "$V426_C" task >/dev/null; v426_idle nx
  local b t; b="$(v426_wt nx builder)"; t="$(v426_wt nx tester)"
  echo wip >"$t/wip.txt"
  v426_g -C "$b" commit -q --allow-empty -m local-only
  FLEET_FORCE=1 "$SCRIPTS/next.sh" build-nx DEV-7 >/dev/null 2>"$FLEET_STATE_DIR/next.err"
  [ -z "${V42X_DEBUG:-}" ] || cat "$FLEET_STATE_DIR/next.err" >&2
  eq "v426 next: a worktree with a commit on no remote stays where it is" "$(git -C "$b" log -1 --format=%s)" local-only
  eq "v426 next: a dirty worktree keeps its file" "$(cat "$t/wip.txt")" wip
  eq "v426 next: and the warning names both" "$(grep -c 'builder (commits on no remote)' "$FLEET_STATE_DIR/next.err"):$(grep -c 'tester (uncommitted changes)' "$FLEET_STATE_DIR/next.err")" "1:1"
  rm "$t/wip.txt"; git -C "$b" reset -q --hard "$V426_OLD"; v426_idle nx
  FLEET_FORCE=1 "$SCRIPTS/next.sh" build-nx DEV-7 >/dev/null 2>"$FLEET_STATE_DIR/next2.err"
  eq "v426 next: clean worktrees move to origin/main" "$(git -C "$b" rev-parse HEAD):$(git -C "$t" rev-parse HEAD):$(git -C "$b" branch --show-current)" "$V426_NEW:$V426_NEW:fleet/build-nx/builder"
}
v426_respawn() { # respawn keeps an existing worktree as it is; a missing one is recreated
  v426_fixture respawn
  v42x_boot --no-issue build rs "$V426_C" task >/dev/null
  local b h; b="$(v426_wt rs builder)"; v426_g -C "$b" commit -q --allow-empty -m mine; h="$(git -C "$b" rev-parse HEAD)"
  echo idle >"$AS/build-rs-builder"
  "$SCRIPTS/respawn.sh" build-rs/builder --restart >/dev/null 2>&1
  eq "v426 respawn: the worktree HEAD is unchanged" "$(git -C "$b" rev-parse HEAD)" "$h"
  git -C "$V426_C" worktree remove --force "$b"; echo idle >"$AS/build-rs-builder"
  "$SCRIPTS/respawn.sh" build-rs/builder --restart >/dev/null 2>&1
  eq "v426 respawn: a missing worktree is recreated on its branch" "$(git -C "$b" rev-parse HEAD 2>/dev/null)" "$h"
}

v426_smoke() { v426_freshbase; v426_offline; v426_trunk; v426_next; v426_respawn; }
v426_full() { v426_smoke; }
