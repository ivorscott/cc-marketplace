#!/usr/bin/env bash
# Run the fleet loop from launchd, so the heartbeat keeps going when no Orchestrator session is open.
#
#   schedule.sh install      write the launcher and the LaunchAgent plist, load it, wait for its first tick
#   schedule.sh uninstall    unload it and remove the plist
#   schedule.sh status       one line: "Fleet loop: <loaded|not loaded|not installed>. Last good tick <time>
#                            (<n> min ago). <healthy|problem: why>." (references/output.md)
#
# The plist (label `fleet.tick`, or schedule_label in config.toml) runs a 5-line launcher,
# $FLEET_STATE_DIR/bin/fleet-tick. The launcher reads the plugin's installPath from
# ~/.claude/plugins/installed_plugins.json and runs that version's loop-tick.sh, so an update takes effect on the
# next tick and a swept old version directory cannot break the job. The job runs every tick_secs (config.toml,
# default 300), once at load, and whenever the escalation inbox changes (WatchPaths), so a P0 starts a tick within
# seconds. Output goes to $FLEET_STATE_DIR/loop.log. The plist carries PATH and HOME (plus FLEET_STATE_DIR and
# FLEET_CONFIG_DIR when they are not the defaults), never a key value.
# install is idempotent. It waits for the RunAtLoad tick (up to FLEET_INSTALL_WAIT seconds, default 90); if that
# tick fails or never happens it unloads the job and prints the last log line. The loop is healthy when it had a
# good tick within 2x tick_secs. The user runs install; boot and next never do.
# Overrides for tests: FLEET_LAUNCH_AGENTS (default ~/Library/LaunchAgents), FLEET_LAUNCHCTL,
# FLEET_INSTALLED_PLUGINS (default ~/.claude/plugins/installed_plugins.json), FLEET_UID.
# Linux: no code here; see the README (systemd user timer).
# UNVERIFIED until the user runs install: real launchd behaviour (DEV-368).
# Command: Install, remove or check the launchd loop · e.g. fleet schedule status
set -euo pipefail
. "$(dirname "$0")/common.sh"

label="$(cfg_str schedule_label fleet.tick)"
secs="$(cfg_int tick_secs 300)"
dir="${FLEET_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
lctl="${FLEET_LAUNCHCTL:-launchctl}"
plist="$dir/$label.plist"
launcher="$FLEET_STATE_DIR/bin/fleet-tick"
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

# The launcher: finds the installed plugin version at run time, so the plist never names a versioned path.
write_launcher() {
  mkdir -p "$(dirname "$launcher")"
  cat >"$launcher" <<LAUNCH
#!/bin/bash
f="\${FLEET_INSTALLED_PLUGINS:-\$HOME/.claude/plugins/installed_plugins.json}"
p="\$(jq -r '[.plugins | to_entries[] | select(.key | startswith("developer@")) | .value[0].installPath][0] // empty' "\$f" 2>/dev/null)"
[ -d "\$p/skills/fleet/scripts" ] || p="$(dirname "$(dirname "$FLEET_SKILL_DIR")")"
exec /bin/bash "\$p/skills/fleet/scripts/loop-tick.sh"
LAUNCH
  chmod +x "$launcher"
}

# A state or config root that is not the default goes into the job's environment, so the job runs on the
# same roots install wrote the launcher, WatchPaths and the wait file into.
env_extra() {
  [ "$FLEET_STATE_DIR" = "$HOME/.local/state/fleet" ] ||
    printf '\n    <key>FLEET_STATE_DIR</key>\n    <string>%s</string>' "$(xml "$FLEET_STATE_DIR")"
  [ "$FLEET_CONFIG_DIR" = "$HOME/.config/fleet" ] ||
    printf '\n    <key>FLEET_CONFIG_DIR</key>\n    <string>%s</string>' "$(xml "$FLEET_CONFIG_DIR")"
}

# One line when the loop has no Orchestrator to wake (registry.sh orchestrator here registers one).
orch_hint() {
  [ -n "$("$FLEET_SCRIPTS/registry.sh" get orchestrator 2>/dev/null | jq -r '.herdr_ref // ""' 2>/dev/null)" ] && return 0
  render_line loop_unregistered
}

LSF="$FLEET_STATE_DIR/loop.state.json"
ls_get() { jq -r "$1" "$LSF" 2>/dev/null || true; }
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
    <string>$(xml "$launcher")</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>$(xml "$FLEET_INBOX")</string>
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
    <string>$(xml "$HOME")</string>$(env_extra)
  </dict>
</dict>
</plist>
PLIST
}

case "${1:-}" in
  render) render ;;
  launcher) write_launcher; echo "$launcher" ;;
  install)
    mkdir -p "$dir" "$FLEET_STATE_DIR" "$(dirname "$FLEET_INBOX")"; touch "$FLEET_INBOX"
    write_launcher
    new="$(render)"
    if [ -f "$plist" ] && [ "$(cat "$plist")" = "$new" ] && "$lctl" print "$domain/$label" >/dev/null 2>&1; then
      echo "already installed: $label"; exit 0
    fi
    printf '%s\n' "$new" >"$plist"
    "$lctl" bootout "$domain/$label" >/dev/null 2>&1 || true
    start="$(date +%s)"; fails0="$(ls_get '.fails // 0')"
    "$lctl" bootstrap "$domain" "$plist" || die "launchctl bootstrap failed for $plist"
    waited=0; ok=false
    while [ "$waited" -lt "${FLEET_INSTALL_WAIT:-90}" ]; do
      if [ "$(ls_get '.last_good // 0')" -ge "$start" ] 2>/dev/null; then ok=true; break; fi
      [ "$(ls_get '.fails // 0')" -le "${fails0:-0}" ] 2>/dev/null || break
      sleep 1; waited=$((waited + 1))
    done
    if ! $ok; then
      "$lctl" bootout "$domain/$label" >/dev/null 2>&1 || true
      echo "the first tick did not succeed; unloaded $label. Last log line: $(tail -n 1 "$FLEET_STATE_DIR/loop.log" 2>/dev/null)" >&2
      exit 1
    fi
    echo "installed: $label every ${secs}s"
    echo "The Orchestrator registers once per session, then follows the wakes.log it names: $FLEET_SCRIPTS/registry.sh orchestrator here"
    ;;
  uninstall)
    "$lctl" bootout "$domain/$label" >/dev/null 2>&1 || true
    if [ -f "$plist" ]; then rm -f "$plist"; echo "uninstalled: $label"; else echo "not installed: $label"; fi
    ;;
  status)
    # One line (references/output.md), then the loop footer when no Orchestrator is registered.
    if [ ! -f "$plist" ]; then loaded="not installed"
    elif "$lctl" print "$domain/$label" >/dev/null 2>&1; then loaded=loaded
    else loaded="not loaded"; fi
    lg="$(ls_get '.last_good // 0')"; nowe="$(jq -rn --arg t "${FLEET_NOW:-$(now)}" '$t | fromdateiso8601')"; when=never; health="problem: no good tick yet"
    if [ "${lg:-0}" -gt 0 ] 2>/dev/null; then
      when="$(date -u -r "$lg" +%Y-%m-%dT%H:%M:%SZ) ($(((nowe - lg) / 60)) min ago)"
      if [ $((nowe - lg)) -le $((2 * secs)) ]; then health=healthy; else health="problem: no good tick within $((2 * secs / 60)) min"; fi
    fi
    [ "$loaded" = loaded ] || health="problem: the job is $loaded"
    reply "$(render_line loop loaded="$loaded" when="$when" health="$health")" "$(orch_hint)"
    ;;
  *) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
