#!/usr/bin/env bash
# 4.3.3 cases (DEV-1243): fleet config prints the effective config, and prime and run show print the caps line.
# Sourced by run.sh (ok/eq, $SCRIPTS, $T). Every case uses its own config dir under $T, never the live one.

v433_with() { # v433_with <config text|-> <command...>: run with a fresh sandboxed config dir holding that text ("-" = no file)
  local txt="$1" d="$T/cfg433" old="$FLEET_CONFIG_DIR" out; shift
  rm -rf "$d"; mkdir -p "$d"; [ "$txt" = - ] || printf '%s\n' "$txt" >"$d/config.toml"
  out="$(FLEET_CONFIG_DIR="$d" "$@" 2>&1)" || true
  FLEET_CONFIG_DIR="$old"; printf '%s\n' "$out"
}
v433_cell() { awk -F'|' -v k="$1" -v c="$2" '$2 ~ "^ *"k" *$" { v = $c; gsub(/^ +| +$/, "", v); print v; exit }'; } # a table row's cell: key, column (3 value, 4 source)

v433_partial() { # only max_teams set: every key shows, max_teams set, teams_per_repo default
  local o; o="$(v433_with 'max_teams = 4' "$SCRIPTS/config.sh")"
  eq "v433 config: max_teams is shown as 4, set" "$(v433_cell max_teams 3 <<<"$o")|$(v433_cell max_teams 4 <<<"$o")" "4|set"
  eq "v433 config: teams_per_repo is shown as 1, default" "$(v433_cell teams_per_repo 3 <<<"$o")|$(v433_cell teams_per_repo 4 <<<"$o")" "1|default"
  eq "v433 config: an unset key with no default shows a dash" "$(v433_cell tracker_teams 3 <<<"$o")|$(v433_cell tracker_teams 4 <<<"$o")" "-|default"
  eq "v433 config: the first line names the config file" "$(head -n 1 <<<"$o" | sed "s#$T#T#")" "Config: T/cfg433/config.toml"
  eq "v433 config: every row is marked set or default" "$(grep -c '^| ' <<<"$o"):$(grep '^| ' <<<"$o" | grep -vc '| \(set\|default\|Source\) |$' )" "$(grep -c '^| ' <<<"$o"):0"
  eq "v433 config: the tables get one footer line" "$(tail -n 1 <<<"$o")" "Tables: context_window (0 set), machine_names (0 set)"
}

v433_nofile() { # no config file: all defaults, and it says so
  local o; o="$(v433_with - "$SCRIPTS/config.sh")"
  eq "v433 config: no file says all defaults" "$(head -n 1 <<<"$o" | awk '{print $1, $2, $3, $4, $5}')" "Config: (no file: all defaults)"
  eq "v433 config: no file shows no set key" "$(grep -c '| set |$' <<<"$o")" "0"
  eq "v433 config: no file shows max_teams 3" "$(v433_cell max_teams 3 <<<"$o")" "3"
}

v433_run() { # [run] keys show, set versus default; the table footer counts the two tables
  local o; o="$(v433_with "$(printf '[run]\nteams = 5\n[context_window]\n"claude-opus-5-5" = 100000\n')" "$SCRIPTS/config.sh")"
  eq "v433 config: a [run] key in the file is set" "$(v433_cell teams 3 <<<"$o")|$(v433_cell teams 4 <<<"$o")" "5|set"
  eq "v433 config: a [run] key not in the file is default" "$(v433_cell stop 3 <<<"$o")|$(v433_cell stop 4 <<<"$o")" "never|default"
  eq "v433 config: all 11 [run] keys show" "$(sed -n '/^\[run\]/,$p' <<<"$o" | grep -c '^| [a-z_]* | .* | \(set\|default\) |$')" "11"
  eq "v433 config: context_window is counted in the footer" "$(tail -n 1 <<<"$o")" "Tables: context_window (1 set), machine_names (0 set)"
  eq "v433 config: an argument is refused" "$(v433_with - "$SCRIPTS/config.sh" --x | grep -c "^fleet: unknown option: --x")" "1"
}

v433_drift() { # the defaults in config.sh equal the values in config.example.toml
  local ex="$SCRIPTS/../config.example.toml" o k v want bad=""
  o="$(v433_with - "$SCRIPTS/config.sh")"
  clean() { sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/'; }
  while IFS=$'\t' read -r k v; do
    case "$k" in max_teams | teams_per_repo | max_envs | min_free_gb | warn_free_gb | prune_cap_gb | label_prefix | lease_hours | linear_writes | permission_mode | overnight | archive_after_days | tick_secs | brief_idle_secs | role_label_prefix | candidates_allow_unlabelled | candidates_allow_backlog | schedule_label) ;; *) continue ;; esac
    want="$(printf '%s' "$v" | clean)"
    [ "$(v433_cell "$k" 3 <<<"$o")" = "$want" ] || bad="$bad $k"
  done < <(bash -c '. "$1/common.sh"; config_pairs "$2" 1' _ "$SCRIPTS" "$ex")
  while IFS=$'\t' read -r k v; do
    want="$(printf '%s' "$v" | clean)"
    [ "$(v433_cell "$k" 3 <<<"$(sed -n '/^\[run\]/,$p' <<<"$o")")" = "$want" ] || bad="$bad run.$k"
  done < <(bash -c '. "$1/common.sh"; table_pairs "$2" "[run]"' _ "$SCRIPTS" "$ex")
  eq "v433 config: the defaults match config.example.toml" "${bad:-none}" "none"
}

v433_caps() { # the 26 Nov case: teams_per_repo 4 shows in prime and run show
  local cfg=$'max_teams = 4\nteams_per_repo = 4' want="Caps: max_teams 4, teams_per_repo 4, min_free_gb 40."
  eq "v433 prime: the caps line shows the set values" "$(v433_with "$cfg" "$SCRIPTS/prime.sh" | grep -c "^$want\$")" "1"
  eq "v433 run show: the caps line comes first" "$(v433_with "$cfg" "$SCRIPTS/run.sh" show | head -n 1)" "$want"
  eq "v433 run show: the defaults show with no file" "$(v433_with - "$SCRIPTS/run.sh" show | head -n 1)" "Caps: max_teams 3, teams_per_repo 1, min_free_gb 40."
}

v433_smoke() { v433_partial; v433_nofile; v433_run; v433_drift; v433_caps; }
v433_full() { v433_smoke; }
