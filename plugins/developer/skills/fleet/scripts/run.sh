#!/usr/bin/env bash
# fleet run: set the self-driving loop up once, then start it with no questions. The rules live in the [run] profile in
# config.toml, so both machines and a fresh session read the same ones, never the Orchestrator's memory.
#
#   run.sh init     ask the profile questions, one at a time, each with a recommended answer; save the answers
#   run.sh show     print the saved profile, with the defaults for what is not saved
#
# init is the only interactive command. Enter keeps the recommended answer (the saved one on a re-run). Without a
# terminal on stdin it refuses and prints the questions rather than guess; FLEET_RUN_ANSWERS=<file> reads one answer
# per line from a file instead (an empty line keeps the default), for scripts and tests. It writes only the [run] table
# and two top-level keys, max_teams (to match the team count) and installs; everything else in config.toml, comments
# included, stays as it is. References: references/output.md, config.example.toml.
# Command: Set up the self-driving loop once, then run it with no questions · e.g. fleet run init
set -euo pipefail
. "$(dirname "$0")/common.sh"

# The profile keys, in the order init asks: key|default|question. The recommended answer is the default.
RUN_KEYS=(
  "teams|3|Teams to keep running"
  "work|anything|Which work: anything (unblocked), parent <issue>, or label <name>"
  "order|critical-path|Order: critical-path (Blocked-by, then priority, then oldest), priority, or oldest"
  "fill|whole-first|Filling slots: whole-first (whole issues, then the unblocked part of one) or whole-only"
  "install_policy|allow|Installs: allow (announced and done, no approval) or ask (an install waits for the owner)"
  "usage_margin|10|Usage limit: percent of the plan's limit to leave unused before the loop stops booting"
  "merge_push_mins|15|Merge push: at most one batched push every N minutes when what is ready to merge changes"
  "status_mins|10|Status: at most one status table every N minutes when something changed"
  "report_at|08:00|Morning report time (local, HH:MM)"
  "stop|never|When to stop: never, an HH:MM time, or no-work (when no work is left)"
)
HUMAN_ONLY="merging, production, infrastructure applies, secrets and branch protection"

usage() { sed -n '2,/^# Command:/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

rkey() { printf '%s' "${1%%|*}"; }
rdef() { local r="${1#*|}"; printf '%s' "${r%%|*}"; }
rask() { printf '%s' "${1#*|*|}"; }
rsaved() { # rsaved <key> <default>: the saved value, else the default
  case "$2" in
    [0-9]*:[0-9]*) run_str "$1" "$2" ;;
    [0-9]*) run_int "$1" "$2" ;;
    *) run_str "$1" "$2" ;;
  esac
}
valid() { # valid <key> <value>: is it an acceptable answer
  case "$1" in
    teams | usage_margin | merge_push_mins | status_mins) case "$2" in "" | *[!0-9]*) return 1 ;; esac
      [ "$1" != teams ] || [ "$2" -ge 1 ]; return ;;
    work) case "$2" in anything | "parent "?* | "label "?*) return 0 ;; *) return 1 ;; esac ;;
    order) case "$2" in critical-path | priority | oldest) return 0 ;; *) return 1 ;; esac ;;
    fill) case "$2" in whole-first | whole-only) return 0 ;; *) return 1 ;; esac ;;
    install_policy) case "$2" in allow | ask) return 0 ;; *) return 1 ;; esac ;;
    report_at) [[ "$2" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] ;;
    stop) [[ "$2" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || [ "$2" = never ] || [ "$2" = no-work ] ;;
    *) return 1 ;;
  esac
}
# toml <key> <value>: the TOML text of an answer; work is stored as parent:<issue> or label:<name>
stored() { case "$1:$2" in work:"parent "* | work:"label "*) printf '%s:%s' "${2%% *}" "${2#* }" ;; *) printf '%s' "$2" ;; esac; }
shown() { case "$1:$2" in work:parent:* | work:label:*) printf '%s %s' "${2%%:*}" "${2#*:}" ;; *) printf '%s' "$2" ;; esac; }

# can_run <teams>: how many of them can really run: one team per repo per machine (teams_per_repo), so with `repos` set
# at most that many; without it the repos with work decide, which init cannot know.
can_run() {
  local n; n="$(config_list repos | jq 'length')"
  if [ "$n" -gt 0 ]; then
    local cap=$((n * $(teams_per_repo))); [ "$1" -le "$cap" ] && printf '%s' "$1" || printf '%s' "$cap"
  else printf '%s' "$1"; fi
}

cmd_init() {
  local row k d q cur a v answers="${FLEET_RUN_ANSWERS:-}" src=""
  if [ -n "$answers" ]; then [ -f "$answers" ] || die "no answers file at $answers"; exec 3<"$answers"; src="file"
  elif [ -t 0 ]; then exec 3<&0; src="tty"
  else
    printf 'run init asks %d questions and needs a terminal; it will not guess. The questions, with the recommended answer:\n' "${#RUN_KEYS[@]}" >&2
    for row in "${RUN_KEYS[@]}"; do printf '  %s [%s]\n' "$(rask "$row")" "$(rdef "$row")" >&2; done
    die "run init needs a terminal" "Run it in a terminal, or set FLEET_RUN_ANSWERS=<file>"
  fi
  printf 'The human keeps: %s. Those are never approved by the loop.\n' "$HUMAN_ONLY"
  for row in "${RUN_KEYS[@]}"; do
    k="$(rkey "$row")"; d="$(rdef "$row")"; q="$(rask "$row")"; cur="$(shown "$k" "$(rsaved "$k" "$d")")"
    while :; do
      printf '%s [%s]: ' "$q" "$cur"
      a=""; IFS= read -r a <&3 || { [ "$src" = file ] || die "input closed before the questions were answered"; a=""; }
      [ "$src" = tty ] || printf '%s\n' "$a"
      a="${a:-$cur}"
      if valid "$k" "$a"; then break; fi
      [ "$src" = tty ] || die "'$a' is not an answer to: $q"
      printf 'Not an answer; try again.\n'
    done
    printf -v "ans_$k" '%s' "$a"
  done
  # the [run] table, then the two top-level keys the profile drives
  for row in "${RUN_KEYS[@]}"; do
    k="$(rkey "$row")"; v="ans_$k"; a="$(stored "$k" "${!v}")"
    case "$k" in
      teams | usage_margin | merge_push_mins | status_mins) cfg_write run "$k" "$a" ;;
      *) cfg_write run "$k" "\"$a\"" ;;
    esac
  done
  # shellcheck disable=SC2154 # the ans_* variables are set by printf -v above
  cfg_write - max_teams "$ans_teams"
  # shellcheck disable=SC2154
  if [ "$ans_install_policy" = allow ]; then cfg_write - installs '"allow"'; else cfg_write - installs -; fi
  render_line run_saved teams="$ans_teams" can_run="$(can_run "$ans_teams")" installs="$ans_install_policy" path="$FLEET_CONFIG_DIR/config.toml"
}

cmd_show() {
  local row k d
  for row in "${RUN_KEYS[@]}"; do
    k="$(rkey "$row")"; d="$(rdef "$row")"
    printf '%s: %s\n' "$k" "$(shown "$k" "$(rsaved "$k" "$d")")"
  done
  printf 'human-only: %s\n' "$HUMAN_ONLY"
}

case "${1:-}" in
  init) cmd_init ;;
  show) cmd_show ;;
  "" | -h | --help | help) usage; [ -n "${1:-}" ] ;;
  *) die "unknown run command: $1" "Run fleet help run" ;;
esac
