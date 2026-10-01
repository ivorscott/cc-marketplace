#!/usr/bin/env bash
# Shared helpers for the /fleet scripts. Source it; don't run it.

FLEET_STATE_DIR="${FLEET_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/fleet}"
FLEET_CONFIG_DIR="${FLEET_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/fleet}"
FLEET_REGISTRY="${FLEET_REGISTRY:-$FLEET_STATE_DIR/fleet.json}"
FLEET_WORKTREES="${FLEET_WORKTREES:-$FLEET_STATE_DIR/worktrees}"
FLEET_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET_SKILL_DIR="$(dirname "$FLEET_SCRIPTS")"

die() { printf 'fleet: %s\n' "$*" >&2; exit 1; }
warn() { printf 'fleet: warning: %s\n' "$*" >&2; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

need() { command -v "$1" >/dev/null 2>&1 || die "requires '$1' on PATH"; }
need jq

# herdr, pinned to the fleet's session. FLEET_SESSION selects a named herdr session
# (used for isolated tests); otherwise the caller's inherited session is used.
hd() {
  if [ -n "${FLEET_SESSION:-}" ]; then herdr --session "$FLEET_SESSION" "$@"; else herdr "$@"; fi
}

require_herdr() {
  need herdr
  if [ -z "${FLEET_SESSION:-}" ] && [ "${HERDR_ENV:-}" != "1" ]; then
    die "run the Orchestrator inside a herdr pane (HERDR_ENV=1), or set FLEET_SESSION=<name>"
  fi
}

# max_agents from config.toml (key = value), default 4.
max_agents() {
  local v=""
  [ -f "$FLEET_CONFIG_DIR/config.toml" ] &&
    v="$(sed -n 's/^[[:space:]]*max_agents[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$FLEET_CONFIG_DIR/config.toml" | head -1)"
  printf '%s\n' "${v:-4}"
}

# config_list <key>: a TOML array of strings from config.toml as a JSON array, default [].
# The array may span lines (key = [ "a", "b" ]). Used for tracker_allow and forge_allow,
# which keep tool-specific permissions (Linear/Jira, GitHub/GitLab, ...) out of templates.
config_list() {
  local f="$FLEET_CONFIG_DIR/config.toml" v
  [ -f "$f" ] || { printf '[]\n'; return 0; }
  v="$(awk -v k="$1" '
    !on && $0 ~ "^[[:space:]]*" k "[[:space:]]*=" { on = 1; sub(/^[^=]*=/, "") }
    on { sub(/#[^"]*$/, ""); buf = buf $0 " "; if ($0 ~ /\]/) exit }
    END { printf "%s", buf }' "$f")"
  [ -n "${v// /}" ] || { printf '[]\n'; return 0; }
  # A TOML array of double-quoted strings is JSON once a trailing comma is dropped.
  v="$(printf '%s' "$v" | sed -E 's/,[[:space:]]*\][[:space:]]*$/]/')"
  printf '%s' "$v" | jq -ce 'if type == "array" and all(type == "string") then . else error end' 2>/dev/null ||
    { warn "ignoring $1 in $f: not a one-level array of strings"; printf '[]\n'; }
}

# Agent names must match herdr's rule: [a-z][a-z0-9_-]{0,31}.
agent_name() {
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
  case "$n" in [a-z]*) ;; *) n="f-$n" ;; esac
  printf '%s\n' "${n:0:32}"
}

# max_envs from config.toml (key = value), default 3.
max_envs() {
  local v=""
  [ -f "$FLEET_CONFIG_DIR/config.toml" ] &&
    v="$(sed -n 's/^[[:space:]]*max_envs[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$FLEET_CONFIG_DIR/config.toml" | head -1)"
  printf '%s\n' "${v:-3}"
}

# Team environment: a repo opts in with <repo>/.claude/fleet-env.json.
env_config() { [ -f "$1/.claude/fleet-env.json" ] && printf '%s\n' "$1/.claude/fleet-env.json" || true; }
env_dir() { printf '%s\n' "$FLEET_STATE_DIR/env/$1"; }

# render_env <template> <team> <cluster> <http> <https> <branch> <kubeconfig>
# Values are shell-quoted: templates run through `bash -c`, and branch names are free text.
render_env() {
  local s="$1" v
  v="$(printf '%q' "$2")"; s="${s//\{\{team\}\}/$v}"
  v="$(printf '%q' "$3")"; s="${s//\{\{cluster\}\}/$v}"
  v="$(printf '%q' "$4")"; s="${s//\{\{http_port\}\}/$v}"
  v="$(printf '%q' "$5")"; s="${s//\{\{https_port\}\}/$v}"
  v="$(printf '%q' "$6")"; s="${s//\{\{branch\}\}/$v}"
  v="$(printf '%q' "$7")"; s="${s//\{\{kubeconfig\}\}/$v}"
  printf '%s' "$s"
}
