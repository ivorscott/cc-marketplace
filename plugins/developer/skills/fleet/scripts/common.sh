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

# Agent names must match herdr's rule: [a-z][a-z0-9_-]{0,31}.
agent_name() {
  local n
  n="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
  case "$n" in [a-z]*) ;; *) n="f-$n" ;; esac
  printf '%s\n' "${n:0:32}"
}
