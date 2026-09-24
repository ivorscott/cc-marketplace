#!/usr/bin/env bash
# PreToolUse hook for /fleet workers. Inert unless FLEET_ROLE=worker and FLEET_WORKTREE
# are set (only in panes /fleet booted with a worktree). Denies file writes outside
# the worker's own worktree. Shell redirection is not covered; the brief and the
# template's permission mode carry that part.
set -u
input="$(cat 2>/dev/null || true)"
[ "${FLEET_ROLE:-}" = "worker" ] && [ -n "${FLEET_WORKTREE:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
[ -n "$path" ] || exit 0
case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
root="$(cd "$FLEET_WORKTREE" 2>/dev/null && pwd -P)" || exit 0
# Resolve the nearest existing parent, so new directories and symlinked roots compare correctly.
d="$(dirname "$path")"; rest=""
while [ ! -d "$d" ] && [ "$d" != "/" ]; do rest="/$(basename "$d")$rest"; d="$(dirname "$d")"; done
dir="$(cd "$d" && pwd -P)$rest"
case "$dir/" in
  "$root"/*) exit 0 ;;
esac
jq -n --arg p "$path" --arg w "$root" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny",
  permissionDecisionReason: "fleet scope guard: \($p) is outside your worktree \($w). Escalate with registry.sh if the task really needs it."}}'
