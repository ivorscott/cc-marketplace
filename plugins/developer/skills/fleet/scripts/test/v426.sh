#!/usr/bin/env bash
# 4.2.6 cases (DEV-691). Sourced by run.sh after v42x.sh, which gives it v42x_boot_state, v42x_boot and the helpers.
# A new file so the shared test files see as few edits as possible.
v426_freshbase() { # DEV-691: worktrees branch from the fresh origin default branch; offline falls back with a warning
  v42x_boot_state fresh L2 'machines = 1'
  local o="$FLEET_STATE_DIR/origin.git" c="$FLEET_STATE_DIR/clone" up="$FLEET_STATE_DIR/upstream" rc g="git -c user.email=t@t -c user.name=t"
  git init -q --bare -b main "$o"; git clone -q "$o" "$c" 2>/dev/null; $g -C "$c" commit -q --allow-empty -m base; git -C "$c" push -q origin main 2>/dev/null
  git clone -q "$o" "$up" 2>/dev/null; $g -C "$up" commit -q --allow-empty -m newer; git -C "$up" push -q origin main 2>/dev/null
  local old new; old="$(git -C "$c" rev-parse HEAD)"; new="$(git -C "$up" rev-parse HEAD)"
  rc="$(v42x_boot --no-issue build fb "$c" task)"
  eq "v426 fresh: the worktree starts from the fetched origin/main, not the stale local HEAD" \
    "$rc:$(git -C "$("$REG" get build-fb/builder | jq -r .worktree)" rev-parse HEAD)" "0:$new"
  eq "v426 fresh: the user's checkout is not moved" "$(git -C "$c" rev-parse HEAD):$(git -C "$c" branch --show-current)" "$old:main"
  git -C "$c" remote set-url origin "$FLEET_STATE_DIR/gone.git"
  rc="$(v42x_boot --no-issue build fo "$c" task)"
  eq "v426 fresh: offline boots from the local HEAD and warns" \
    "$rc:$(git -C "$("$REG" get build-fo/builder | jq -r .worktree)" rev-parse HEAD):$(grep -c 'could not fetch origin/main' "$FLEET_STATE_DIR/boot.err")" "0:$old:1"
}

v426_smoke() { v426_freshbase; }
v426_full() { v426_smoke; }
