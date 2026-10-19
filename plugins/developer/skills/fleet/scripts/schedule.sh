#!/usr/bin/env bash
# Run the fleet loop from launchd, so the heartbeat keeps going when no Orchestrator session is open.
#
#   schedule.sh install      write the LaunchAgent plist and load it
#   schedule.sh uninstall    unload it and remove the plist
#   schedule.sh status       loaded or not, the last run and the last exit
#
# The job runs `/bin/bash <this skill's scripts>/loop-tick.sh` every tick_secs (config.toml,
# default 300) and once at load. Its output goes to $FLEET_STATE_DIR/loop.log. The plist carries
# PATH and HOME only, never a key value. Label: schedule_label in config.toml, default
# io.devpie.fleet.tick. install is idempotent: unchanged content changes nothing. The user runs
# install; boot and next never do. Overrides for tests: FLEET_LAUNCH_AGENTS (the directory,
# default ~/Library/LaunchAgents) and FLEET_LAUNCHCTL (the launchctl binary).
# Linux: no code here; see the README (systemd user timer).
# UNVERIFIED until the user runs install: real launchd behaviour (DEV-368).
set -euo pipefail
. "$(dirname "$0")/common.sh"

label="$(cfg_str schedule_label io.devpie.fleet.tick)"
secs="$(cfg_int tick_secs 300)"
dir="${FLEET_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
lctl="${FLEET_LAUNCHCTL:-launchctl}"
plist="$dir/$label.plist"
domain="gui/${FLEET_UID:-$(id -u)}"

# PATH for the job: launchd's own is bare, so keep the caller's plus the usual tool directories.
job_path() {
  local p="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" out="" d
  local IFS=:
  for d in $p; do
    [ -n "$d" ] || continue
    case ":$out:" in *":$d:"*) ;; *) out="${out:+$out:}$d" ;; esac
  done
  printf '%s' "$out"
}

xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

render() {
  cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(xml "$label")</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml "$FLEET_SCRIPTS/loop-tick.sh")</string>
  </array>
  <key>StartInterval</key>
  <integer>$secs</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml "$FLEET_STATE_DIR/loop.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml "$FLEET_STATE_DIR/loop.log")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(xml "$(job_path)")</string>
    <key>HOME</key>
    <string>$(xml "$HOME")</string>
  </dict>
</dict>
</plist>
PLIST
}

case "${1:-}" in
  render) render ;;
  install)
    mkdir -p "$dir" "$FLEET_STATE_DIR"
    new="$(render)"
    if [ -f "$plist" ] && [ "$(cat "$plist")" = "$new" ] && "$lctl" print "$domain/$label" >/dev/null 2>&1; then
      echo "already installed: $label"; exit 0
    fi
    printf '%s\n' "$new" >"$plist"
    "$lctl" bootout "$domain/$label" >/dev/null 2>&1 || true
    "$lctl" bootstrap "$domain" "$plist" || die "launchctl bootstrap failed for $plist"
    echo "installed: $label every ${secs}s"
    ;;
  uninstall)
    "$lctl" bootout "$domain/$label" >/dev/null 2>&1 || true
    if [ -f "$plist" ]; then rm -f "$plist"; echo "uninstalled: $label"; else echo "not installed: $label"; fi
    ;;
  status)
    if [ ! -f "$plist" ]; then echo "not installed"; exit 0; fi
    if out="$("$lctl" print "$domain/$label" 2>/dev/null)"; then
      echo "loaded: $label"
      printf '%s\n' "$out" | sed -n 's/^[[:space:]]*last exit code = \(.*\)$/last exit: \1/p' | head -1
    else echo "installed but not loaded: $label"; fi
    if [ -f "$FLEET_STATE_DIR/loop.log" ]; then
      echo "last run: $(date -u -r "$(stat -f %m "$FLEET_STATE_DIR/loop.log" 2>/dev/null || stat -c %Y "$FLEET_STATE_DIR/loop.log")" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    fi
    ;;
  *) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
