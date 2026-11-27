#!/usr/bin/env bash
# fleet config: print the effective config, so nobody has to `cat` config.toml or guess a default.
#
#   config.sh
#
# First line: the path of config.toml (or "(no file: all defaults)"). Then a table of every top-level key and every key
# of the [run] profile: its value, and whether it is "set" (the key is in the file) or "default" (it is not, and the
# value is what the scripts use). A key with no default and no value shows "-". The values come from the same readers
# the scripts use (cfg_int, cfg_str, cfg_bool, config_list, run_val), not a second parse. It prints only the keys listed
# here, never the raw file. [context_window] and [machine_names] get one footer line, not a table. Read-only.
# The defaults below match config.example.toml; a test keeps them in step. The [run] defaults are RUN_KEYS in run.sh.
# Command: Print the effective config: every key, set or default, and the file path · e.g. fleet config
set -euo pipefail
. "$(dirname "$0")/common.sh"

[ $# = 0 ] || die "unknown option: $1" "Run fleet help config"

# key|kind|default; kinds int, str, bool, list. An empty default means unset has no value.
CONFIG_KEYS=(
  "max_teams|int|3"
  "teams_per_repo|int|1"
  "max_envs|int|3"
  "min_free_gb|int|40"
  "warn_free_gb|int|75"
  "prune_cap_gb|int|20"
  "machines|int|"
  "machine_name|str|"
  "label_prefix|str|fleet:"
  "lease_hours|int|2"
  "linear_writes|str|off"
  "permission_mode|str|auto"
  "role_label_prefix|str|role:"
  "candidates_allow_unlabelled|bool|false"
  "candidates_allow_backlog|bool|false"
  "overnight|bool|false"
  "archive_after_days|int|0"
  "brief_idle_secs|int|60"
  "tick_secs|int|300"
  "schedule_label|str|fleet.tick"
  "repo_owners|list|"
  "repos|list|"
  "tracker_teams|list|"
  "tracker_allow|list|"
  "forge_allow|list|"
  "no_pr_ci|list|"
  "installs|str|"
  "public_repos|list|"
  "private_repos|list|"
  "scrub_env|list|"
  "alert_cmd|str|"
  "chat_channel|str|"
  "chat_allow|list|"
)

cfg="$FLEET_CONFIG_DIR/config.toml"
top_set="" run_set=""
if [ -f "$cfg" ]; then
  top_set="$(config_pairs "$cfg" | cut -f1)"
  run_set="$(table_pairs "$cfg" '[run]' | cut -f1)"
fi
is_set() { printf '%s\n' "$1" | grep -qxF -- "$2"; }

value() { # value <kind> <key> <default>
  local v
  case "$1" in
    int) v="$(cfg_int "$2" "$3")" ;;
    str) v="$(cfg_str "$2" "$3")" ;;
    bool) v="$(cfg_bool "$2" "$3")" ;;
    list) v="$(config_list "$2" 2>/dev/null | jq -r 'join(", ")')" ;;
  esac
  printf '%s' "${v:--}"
}

rows() { printf '| Key | Value | Source |\n|---|---|---|\n'; }
if [ -f "$cfg" ]; then printf 'Config: %s\n\n' "$cfg"; else printf 'Config: (no file: all defaults) %s\n\n' "$cfg"; fi
rows
for row in "${CONFIG_KEYS[@]}"; do
  IFS='|' read -r k kind d <<<"$row"
  src=default; if is_set "$top_set" "$k"; then src="set"; fi
  printf '| %s | %s | %s |\n' "$k" "$(value "$kind" "$k" "$d")" "$src"
done

printf '\n[run]\n\n'
rows
while IFS='|' read -r k d; do
  src=default; if is_set "$run_set" "$k"; then src="set"; fi
  case "$d" in [0-9]*:[0-9]*) kind=str ;; [0-9]*) kind=int ;; *) kind=str ;; esac
  if [ "$kind" = int ]; then v="$(run_int "$k" "$d")"; else v="$(run_str "$k" "$d")"; fi
  printf '| %s | %s | %s |\n' "$k" "$v" "$src"
done < <(sed -n 's/^  "\([a-z_]*\)|\([^|]*\)|.*"$/\1|\2/p' "$(dirname "$0")/run.sh")

tbl_count() { # tbl_count <table name>: the key = value lines inside that table of config.toml
  [ -f "$cfg" ] || { printf 0; return; }
  awk -v t="$1" '/^[ \t]*\[/ { h = $0; gsub(/[][ \t]/, "", h); on = (h == t); next } on && /^[ \t]*[^# \t][^=]*=/ { n++ } END { print n + 0 }' "$cfg"
}
ctx="$(tbl_count context_window)" names="$(tbl_count machine_names)"
printf '\nTables: context_window (%s set), machine_names (%s set)\n' "$ctx" "$names"
