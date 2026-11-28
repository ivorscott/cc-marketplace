#!/usr/bin/env bash
# 4.3.3 cases (DEV-1243): run show prints the caps line. In 5.0 it replaces fleet config, and status replaces prime.
# Sourced by run.sh (ok/eq, $SCRIPTS, $T). Every case uses its own config dir under $T, never the live one.

v433_with() { # v433_with <config text|-> <command...>: run with a fresh sandboxed config dir holding that text ("-" = no file)
  local txt="$1" d="$T/cfg433" old="$FLEET_CONFIG_DIR" out; shift
  rm -rf "$d"; mkdir -p "$d"; [ "$txt" = - ] || printf '%s\n' "$txt" >"$d/config.toml"
  out="$(FLEET_CONFIG_DIR="$d" "$@" 2>&1)" || true
  FLEET_CONFIG_DIR="$old"; printf '%s\n' "$out"
}
v433_caps() { # the 26 Nov case: teams_per_repo 4 shows in run show (fleet config and prime are gone in 5.0)
  local cfg=$'max_teams = 4\nteams_per_repo = 4' want="Caps: max_teams 4, teams_per_repo 4, min_free_gb 40."
  eq "v433 run show: the caps line comes first" "$(v433_with "$cfg" "$SCRIPTS/run.sh" show | head -n 1)" "$want"
  eq "v433 run show: the defaults show with no file" "$(v433_with - "$SCRIPTS/run.sh" show | head -n 1)" "Caps: max_teams 3, teams_per_repo 1, min_free_gb 40."
}

v433_smoke() { v433_caps; }
v433_full() { v433_smoke; }
