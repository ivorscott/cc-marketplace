#!/usr/bin/env bash
# PreToolUse hook for /fleet agents. Inert unless FLEET_ROLE is set (only in panes /fleet booted):
# the Orchestrator and the user's own sessions are not fleet agents and are never restricted.
#
#   Every fleet agent, leads included: denied any Read, Edit, Write, Grep or Glob of the Linear key file. The
#   target is resolved first (`..` collapsed, directories made physical, symlinks followed), so a
#   path with another name that leads to the key is denied too. The key file is recognised by its
#   name (linear_api_key) and by the resolved path of $FLEET_CONFIG_DIR/linear_api_key; only the
#   directory of that path is looked at, never the key file itself.
#   Workers with a worktree (FLEET_WORKTREE): also denied file writes outside that worktree.
#
# Shell commands are covered by fleet-bash-guard.sh. Both are guardrails, not a boundary: the key
# file is mode 600 for the user the agents run as, so any same-uid process can read it.
set -u
input="$(cat 2>/dev/null || true)"
[ -n "${FLEET_ROLE:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // .tool_input.path // empty')"
# Grep and Glob also name files in their pattern and glob arguments; Glob's pattern and Grep's glob are paths.
pats=""; globs=""
case "$tool" in
  Grep | Glob)
    pats="$(printf '%s' "$input" | jq -r '[.tool_input.pattern, .tool_input.glob] | map(strings) | .[]')"
    globs="$(printf '%s' "$input" | jq -r --arg t "$tool" '[if $t == "Glob" then .tool_input.pattern else empty end, .tool_input.glob] | map(strings) | .[]')" ;;
esac
[ -n "$path" ] || [ -n "$pats" ] || exit 0
# A Grep or Glob with no path searches the cwd.
case "$tool" in Grep | Glob) [ -n "$path" ] || path="$PWD" ;; esac
case "$path" in /*) ;; *) path="$PWD/$path" ;; esac

deny() { jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'; exit 0; }

# lexnorm <absolute path>: collapse ".", ".." and repeated slashes without touching the filesystem.
lexnorm() {
  local acc="" seg IFS=/
  set -f
  for seg in $1; do
    case "$seg" in
      "" | .) ;;
      ..) acc="${acc%/*}" ;;
      *) acc="$acc/$seg" ;;
    esac
  done
  set +f
  printf '%s\n' "${acc:-/}"
}
# resolve <absolute path>: the nearest existing parent made physical, the rest appended, and the final
# component followed through symlinks (up to 10 hops). New files and new directories resolve too.
resolve() {
  local p d rest base t hops=0
  p="$(lexnorm "$1")"
  while :; do
    d="$(dirname "$p")"; base="$(basename "$p")"; rest=""
    while [ ! -d "$d" ] && [ "$d" != "/" ]; do rest="/$(basename "$d")$rest"; d="$(dirname "$d")"; done
    p="$(lexnorm "$(cd "$d" && pwd -P)$rest/$base")"
    if [ -L "$p" ] && [ "$hops" -lt 10 ]; then
      t="$(readlink "$p")"
      case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
      p="$(lexnorm "$p")"; hops=$((hops + 1))
    else
      break
    fi
  done
  printf '%s\n' "$p"
}

rp="$(resolve "$path")"
kdir="${FLEET_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/fleet}"
case "$kdir" in /*) ;; *) kdir="$PWD/$kdir" ;; esac
keypath="$(resolve "$kdir")/linear_api_key"
for cand in "$path" "$rp"; do
  case "${cand##*/}" in
    linear_api_key | linear_api_key.*) deny "fleet scope guard: $path is the Linear key; only the Orchestrator reads it." ;;
  esac
done
[ "$rp" != "$keypath" ] || deny "fleet scope guard: $path leads to the Linear key; only the Orchestrator reads it."
case "$tool" in
  Grep | Glob)
    # A pattern or glob that names the key file, by name or as a path that resolves to it.
    while IFS= read -r pt; do
      [ -n "$pt" ] || continue
      case "$pt" in *linear_api_key*) deny "fleet scope guard: the $tool argument names the Linear key; only the Orchestrator reads it." ;; esac
      case "$pt" in /*) [ "$(resolve "$pt")" != "$keypath" ] || deny "fleet scope guard: the $tool argument leads to the Linear key; only the Orchestrator reads it." ;; esac
    done <<<"$pats"
    # A search rooted at the key's directory, or above it (the cwd when no path is given: HOME, say), would read
    # the file as part of the tree.
    case "$keypath" in "$rp"/*) deny "fleet scope guard: searching $path would read the Linear key; search a narrower directory." ;; esac
    # A path glob that can reach the key's directory: its fixed part (up to the first wildcard), taken from the
    # search root when relative, is that directory or above it; or it spells .config/fleet.
    while IFS= read -r g; do
      [ -n "$g" ] || continue
      case "$g" in *.config/fleet | *.config/fleet/* | *.config/fleet[*?[{]*) deny "fleet scope guard: the $tool pattern $g reaches the Linear key's directory." ;; esac
      fixed="$g"; case "$g" in *[*?[{]*) fixed="${g%%[*?[{]*}"; case "$fixed" in */*) fixed="${fixed%/*}" ;; *) fixed="" ;; esac ;; esac
      case "$fixed" in /*) ;; "") fixed="$rp" ;; *) fixed="$rp/$fixed" ;; esac
      fr="$(resolve "$fixed")"
      case "$keypath" in "$fr"/*) deny "fleet scope guard: the $tool pattern $g can reach the Linear key; search a narrower directory." ;; esac
    done <<<"$globs"
    ;;
esac

# The worktree fence is for workers with a worktree, and not for reads (Read, Grep, Glob).
[ "${FLEET_ROLE:-}" = "worker" ] && [ -n "${FLEET_WORKTREE:-}" ] || exit 0
case "$tool" in Read | Grep | Glob) exit 0 ;; esac
root="$(cd "$FLEET_WORKTREE" 2>/dev/null && pwd -P)" || exit 0
case "$rp/" in
  "$root"/*) exit 0 ;;
esac
deny "fleet scope guard: $path is outside your worktree $root. Escalate with registry.sh if the task really needs it."
