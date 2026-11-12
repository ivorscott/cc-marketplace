#!/usr/bin/env bash
# fleet run: set the self-driving loop up once, then start it with no questions. The rules live in the [run] profile in
# config.toml, so both machines and a fresh session read the same ones, never the Orchestrator's memory.
#
#   run.sh init     ask the profile questions, one at a time, each with a recommended answer; save the answers
#   run.sh show     print the saved profile, with the defaults for what is not saved
#   run.sh start    read the profile and start the loop, asking nothing: register this pane as the Orchestrator, set
#                   target_teams to the profile's teams, install the launchd loop when it is not installed (not in a
#                   sandbox or a test), and print the loop's rules, made from the profile, for the Orchestrator to follow
#   run.sh stop     stop keeping teams running (target_teams 0); running teams, their PRs and the loop's ticks carry on
#   run.sh status   one line: whether the loop runs, the target, the teams live now
#
# init also asks whether the fleet may delete stale remote branches (branch_delete). Only on the owner's explicit yes (a typed
# yes or y, or Enter at a real terminal when the shown default is yes) does it back up ~/.claude/settings.json and merge
# Bash(git push origin --delete:*) into permissions.allow (common.sh settings_add_rule); an answers file's default, EOF or no
# never edits it, and invalid JSON is left untouched with a warning. start only checks for the rule and prints one line with
# the fix when it is missing; no other command edits the file.
# init is the only interactive command. Enter keeps the recommended answer (the saved one on a re-run). Without a
# terminal on stdin it refuses and prints the questions rather than guess; FLEET_RUN_ANSWERS=<file> reads one answer
# per line from a file instead (an empty line keeps the default), for scripts and tests. It writes only the [run] table
# and two top-level keys, max_teams (to match the team count) and installs; everything else in config.toml, comments
# included, stays as it is. The rules live in the profile, never in the Orchestrator's memory: after a context compaction
# or in a fresh session, `fleet run show` (or `run.sh start` again) gives them back. References: references/output.md,
# config.example.toml.
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
  "branch_delete|yes|Let the fleet delete stale remote branches? A yes adds Bash(git push origin --delete:*) to ~/.claude/settings.json after a backup (yes/no, recommended yes)"
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
    branch_delete) case "$2" in yes | no) return 0 ;; *) return 1 ;; esac ;;
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
  local row k d q cur a raw v answers="${FLEET_RUN_ANSWERS:-}" src="" explicit_yes=false
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
      raw="$a"; a="${a:-$cur}"
      if [ "$k" = branch_delete ]; then case "$a" in y | Y | yes | YES | Yes) a=yes ;; n | N | no | NO | No) a=no ;; esac; fi
      if valid "$k" "$a"; then
        # Only an explicit yes lets init touch settings.json: a typed yes or y, or Enter at a real terminal when the
        # shown default is yes. EOF, an empty line in an answers file, or a default from a file never does.
        if [ "$k" = branch_delete ] && [ "$a" = yes ] && { [ -n "$raw" ] || [ "$src" = tty ]; }; then explicit_yes=true; fi
        break
      fi
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
  # The one place the plugin edits permission settings: only after the owner's explicit yes. On a no the file is not read.
  # shellcheck disable=SC2154
  if [ "$ans_branch_delete" = yes ]; then
    if $explicit_yes; then settings_add_rule || true
    else printf 'Branch deletes stay off: no explicit yes, so %s was not edited. Run fleet run init in a terminal and answer yes, or add %s to permissions.allow yourself.\n' "$(claude_settings)" "$DELETE_RULE"; fi
  fi
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

# have_profile: init has been run (the [run] table holds teams)
have_profile() { [ -n "$(run_val teams)" ]; }

cmd_start() {
  have_profile || die "no run profile saved" "Run fleet run init once"
  local teams work order fill pol margin mpush spush rep stop reg sched bdel bdline
  teams="$(run_int teams 3)"; work="$(shown work "$(run_str work anything)")"; order="$(run_str order critical-path)"; fill="$(run_str fill whole-first)"
  pol="$(run_str install_policy allow)"; margin="$(run_int usage_margin 10)"; mpush="$(run_int merge_push_mins 15)"; spush="$(run_int status_mins 10)"
  rep="$(run_str report_at 08:00)"; stop="$(run_str stop never)"; bdel="$(run_str branch_delete yes)"
  reg="$FLEET_SCRIPTS/registry.sh"
  if [ -n "${HERDR_PANE_ID:-}" ]; then "$reg" orchestrator here >/dev/null || die "could not register this pane as the Orchestrator"
  elif [ -z "$("$reg" get orchestrator 2>/dev/null | jq -r '.herdr_ref // ""')" ]; then
    die "no Orchestrator is registered and this is not a herdr pane" "Run fleet run start in the Orchestrator's herdr pane"
  fi
  "$reg" set orchestrator target_teams="$teams" run_active=true run_started="${FLEET_NOW:-$(now)}" >/dev/null
  # The launchd loop runs tick with no model; install it when it is not there (never in a sandbox or a test).
  sched="$("$FLEET_SCRIPTS/schedule.sh" status 2>/dev/null | head -n 1)"
  case "$sched" in
    *"not installed"*) if [ -n "${FLEET_SANDBOX:-}" ] || [ "${FLEET_TEST:-}" = 1 ]; then sched="not installed (not touched here)"
      else "$FLEET_SCRIPTS/schedule.sh" install >/dev/null 2>&1 && sched="installed" || sched="not installed: run fleet schedule install"; fi ;;
  esac
  render_line run_started teams="$teams" work="$work" order="$order" loop="${sched:-unknown}"
  # Branch deletes: only a check. If the owner wants them and the rule is missing, one line says how to add it; start never edits.
  bdline="Branch deletes: ${bdel}."
  if [ "$bdel" = yes ] && ! branch_delete_allowed; then
    bdline="Branch deletes are off until $DELETE_RULE is in permissions.allow."
    printf 'Branch deletes are off: run fleet run init and answer yes, or add %s to permissions.allow in %s.\n' "$DELETE_RULE" "$(claude_settings)"
  fi
  cat <<EOF
Follow this until fleet run stop. After a context compaction, or in a fresh session, run fleet run show and follow it again.
- Keep $teams teams running. On a slot_free wake, pick the next issue (work: $work; order: $order; fill: $fill) and boot it. Never ask which one.
- Retire a team at once when its PR merges (pr_merged). Bump a client after an API merge where the repo's rules say so, without asking.
- Installs: $pol. The human keeps $HUMAN_ONLY: never approve them; park that part, push once, list it in the morning report.
- A lead's escalation is decided by you: take the recommended option, tell the lead, resolve it with a note, comment the decision on the issue, record it.
- Open no question box. The only wait is a PR waiting to merge. Keep one wake monitor armed and re-arm it silently: on an expiry run `fleet watch`, start Monitor with its first line, end the turn with no text.
- Say only what the owner can act on: a status table when it changes (every $spush minutes at most), the ready-to-merge push (every $mpush minutes at most), a failure, a usage limit, the morning report at $rep. Never your own housekeeping.
- Usage guard: leave $margin% of the plan's limit unused where it can be read; on a usage_limit wake boot nothing until the backoff ends.
- $bdline The fleet never edits permission settings itself; only fleet run init does, after the owner's yes.
- Stop: $stop.
EOF
}
cmd_stop() {
  "$FLEET_SCRIPTS/registry.sh" get orchestrator >/dev/null 2>&1 || die "no Orchestrator is registered"
  "$FLEET_SCRIPTS/registry.sh" set orchestrator target_teams=0 run_active= >/dev/null
  render_line run_stopped
}
cmd_status() {
  local o act tgt live
  o="$("$FLEET_SCRIPTS/registry.sh" get orchestrator 2>/dev/null || echo '{}')"
  act="$(jq -r 'if (.run_active // "") == "true" then "running" else "not running" end' <<<"$o")"
  tgt="$(jq -r '.target_teams // 0' <<<"$o")"; live="$(live_team_count)"
  render_line run_status state="$act" target="$tgt" live="$live" profile="$(have_profile && echo saved || echo none)"
}

case "${1:-}" in
  init) cmd_init ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  show) cmd_show ;;
  "" | -h | --help | help) usage; [ -n "${1:-}" ] ;;
  *) die "unknown run command: $1" "Run fleet help run" ;;
esac
