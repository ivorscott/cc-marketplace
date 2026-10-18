#!/usr/bin/env bash
# This machine's identity for tracker claims. Never fails for lack of an OS id.
#
#   machine-id.sh id                    the full machine id
#   machine-id.sh key                   first 8 hex characters of the id (FLEET_MACHINE replaces it)
#   machine-id.sh label                 <label_prefix><key>, e.g. fleet:3f9a2c1e
#   machine-id.sh description [--date YYYY-MM-DD]
#                                       text for the machine's tracker label description
#   machine-id.sh show                  everything above as JSON, plus where the id came from
#
# Id sources, first valid one wins (>= 8 hex characters, not all zeros or all F):
# a stored random id, then macOS ioreg, Linux /etc/machine-id and the dbus copy, Windows
# powershell then wmic, and last a random id stored under $FLEET_STATE_DIR (or the config dir).
set -uo pipefail
. "$(dirname "$0")/common.sh"

norm() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '{} \r\n-'; }
valid() { # valid <id>: at least 8 hex characters, not a placeholder
  local n; n="$(norm "$1")"
  case "$n" in "" | *[!0-9a-f]*) return 1 ;; esac
  [ "${#n}" -ge 8 ] || return 1
  case "$n" in *[1-9a-e]*) return 0 ;; esac # all zeros / all f
  return 1
}

ID=""; SOURCE=""
take() { # take <source> <candidate>
  local c; c="$(printf '%s' "$2" | tr -d '\r' | head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  valid "$c" || return 1
  ID="$c"; SOURCE="$1"
}

uname_s() { command -v uname >/dev/null 2>&1 && uname -s 2>/dev/null || true; }
host_os() {
  case "$(uname_s)" in
    Darwin) echo macOS; return ;;
    Linux) echo Linux; return ;;
    MINGW* | MSYS* | CYGWIN*) echo Windows; return ;;
  esac
  [ "${OS:-}" = "Windows_NT" ] && echo Windows || echo "unknown OS"
}
host_name() {
  local h=""
  command -v hostname >/dev/null 2>&1 && h="$(hostname 2>/dev/null || true)"
  printf '%s\n' "${h:-${COMPUTERNAME:-unknown-host}}"
}

stored_file() { # stored_file <dir>
  printf '%s\n' "$1/machine-id"
}

random_id() {
  local r=""
  if command -v uuidgen >/dev/null 2>&1; then r="$(uuidgen 2>/dev/null || true)"; fi
  if ! valid "$r"; then r="$(head -1 "${FLEET_PROC_UUID_FILE:-/proc/sys/kernel/random/uuid}" 2>/dev/null || true)"; fi
  if ! valid "$r" && command -v od >/dev/null 2>&1; then
    r="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/')"
  fi
  printf '%s\n' "$r"
}

resolve() {
  [ -n "$ID" ] && return 0
  local d f c os
  for d in "$FLEET_STATE_DIR" "$FLEET_CONFIG_DIR"; do
    f="$(stored_file "$d")"
    [ -f "$f" ] && take stored "$(cat "$f" 2>/dev/null)" && return 0
  done
  os="$(uname_s)"
  case "$os" in
    Darwin)
      command -v ioreg >/dev/null 2>&1 &&
        take ioreg "$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | sed -n 's/.*"IOPlatformUUID"[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)" && return 0 ;;
    Linux)
      take /etc/machine-id "$(cat "${FLEET_MACHINE_ID_FILE:-/etc/machine-id}" 2>/dev/null)" && return 0
      take dbus "$(cat "${FLEET_DBUS_ID_FILE:-/var/lib/dbus/machine-id}" 2>/dev/null)" && return 0 ;;
  esac
  case "$os" in MINGW* | MSYS* | CYGWIN*) os=windows ;; *) [ "${OS:-}" = "Windows_NT" ] && os=windows ;; esac
  if [ "$os" = windows ]; then
    command -v powershell >/dev/null 2>&1 &&
      take powershell "$(powershell -NoProfile -Command '(Get-CimInstance Win32_ComputerSystemProduct).UUID' 2>/dev/null)" && return 0
    command -v wmic >/dev/null 2>&1 &&
      take wmic "$(wmic csproduct get uuid 2>/dev/null | tr -d '\r' | sed -n '2p')" && return 0
  fi
  c="$(random_id)"
  take random "$c" || { c="00000000-0000-4000-8000-$(date +%s)"; take random "$c" || true; }
  for d in "$FLEET_STATE_DIR" "$FLEET_CONFIG_DIR"; do
    if mkdir -p "$d" 2>/dev/null && printf '%s\n' "$ID" >"$(stored_file "$d")" 2>/dev/null; then return 0; fi
  done
  warn "cannot store a machine id in $FLEET_STATE_DIR or $FLEET_CONFIG_DIR; using one that will not persist"
}

key() {
  if [ -n "${FLEET_MACHINE:-}" ]; then printf '%s\n' "$FLEET_MACHINE"; return; fi
  resolve; norm "$ID" | cut -c1-8
}

machine_name() { cfg_str machine_name ""; }

case "${1:-}" in
  id) resolve; printf '%s\n' "$ID" ;;
  key) key ;;
  label) KEY="$(key)"; printf '%s%s\n' "$(label_prefix)" "$KEY" ;;
  description)
    date_s="$(date +%Y-%m-%d)"
    [ "${2:-}" = "--date" ] && date_s="${3:?usage: description [--date YYYY-MM-DD]}"
    resolve
    name="$(machine_name)"; [ -n "$name" ] || name="$(host_name)"
    printf '%s · %s · machine id %s · first claim %s\n' "$name" "$(host_os)" "$ID" "$date_s" ;;
  show)
    resolve; KEY="$(key)"
    jq -cn --arg id "$ID" --arg key "$KEY" --arg label "$(label_prefix)$KEY" \
      --arg name "$(machine_name)" --arg host "$(host_name)" --arg os "$(host_os)" \
      --arg legacy "$(cfg_str machine_legacy_label "")" --arg source "$SOURCE" \
      '{id: $id, key: $key, label: $label, name: $name, host: $host, os: $os, legacy_label: $legacy, source: $source}' ;;
  *) echo "usage: machine-id.sh id|key|label|description [--date D]|show" >&2; exit 2 ;;
esac
exit 0
