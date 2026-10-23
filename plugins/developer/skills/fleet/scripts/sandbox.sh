#!/usr/bin/env bash
# Run a reproduction or an experiment away from the live fleet.
#
#   sandbox.sh [--state-dir DIR] [--config-dir DIR] [--keep] [--] [cmd args...]
#
# It does what the test suite's setup does: a temporary FLEET_STATE_DIR and FLEET_CONFIG_DIR (or the ones
# given, which must not be the live roots), shims first on PATH for herdr (logs every call to herdr.log in the
# sandbox and answers "{}" or an idle agent), gh and curl (both log and fail, so nothing reaches GitHub or
# Linear), and HERDR_ENV, FLEET_SESSION, LINEAR_API_KEY, FLEET_ROLE, FLEET_NAME, FLEET_TEAM and FLEET_WORKTREE
# unset (FLEET_SESSION is then set to the fake session "fleet-sandbox", which only the herdr shim answers, and HOME
# to an empty directory, so no tracker key, Claude transcript or plugin cache is found). FLEET_REGISTRY and
# FLEET_INBOX, FLEET_GH, KUBECONFIG and every AWS_* variable are unset too, so nothing can point back at live
# state or real cloud credentials. Then it runs
# cmd (default: an interactive shell) with the fleet scripts at $F. On exit the temporary root is removed
# unless --keep (it prints where it is).
#
# It refuses, before running anything, when a resolved root is the live one: the state root
# ${XDG_STATE_HOME:-~/.local/state}/fleet, the config root ${XDG_CONFIG_HOME:-~/.config}/fleet, or anything
# under them. House rule: reproductions run only here.
# Command: Run a reproduction away from the live fleet · e.g. fleet sandbox --keep
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

state_dir=""; config_dir=""; keep=false
while [ $# -gt 0 ]; do
  case "$1" in
    --state-dir) state_dir="${2:?--state-dir needs a directory}"; shift 2 ;;
    --config-dir) config_dir="${2:?--config-dir needs a directory}"; shift 2 ;;
    --keep) keep=true; shift ;;
    --) shift; break ;;
    -*) printf 'sandbox: unknown option: %s\n' "$1" >&2; exit 2 ;;
    *) break ;;
  esac
done

# phys <path>: the physical path, symlinks resolved; for a path that does not exist yet, its deepest existing
# parent resolved with the rest appended (so a new directory under a symlinked live root is still caught).
phys() {
  local d="$1" rest=""
  while [ ! -d "$d" ] && [ "$d" != / ] && [ "$d" != . ]; do rest="/$(basename "$d")$rest"; d="$(dirname "$d")"; done
  printf '%s%s\n' "$(cd "$d" && pwd -P)" "$rest"
}
live_state="$(phys "${XDG_STATE_HOME:-$HOME/.local/state}/fleet")"
live_config="$(phys "${XDG_CONFIG_HOME:-$HOME/.config}/fleet")"
refuse_live() { # refuse_live <path>
  local p; p="$(phys "$1")"
  case "$p/" in
    "$live_state"/* | "$live_config"/*) printf 'sandbox: refusing: %s is the live fleet state or config (%s, %s)\n' "$1" "$live_state" "$live_config" >&2; exit 1 ;;
  esac
}

root="$(mktemp -d "${TMPDIR:-/tmp}/fleet-sandbox.XXXXXX")"
cleanup() { if $keep; then printf 'sandbox: kept %s\n' "$root" >&2; else rm -rf "$root"; fi; }
trap cleanup EXIT
[ -n "$state_dir" ] || state_dir="$root/state"
[ -n "$config_dir" ] || config_dir="$root/config"
refuse_live "$state_dir"; refuse_live "$config_dir"
mkdir -p "$state_dir" "$config_dir" "$root/bin" "$root/home"

# Shims: herdr answers without a server; gh and curl never reach the network.
cat >"$root/bin/herdr" <<'S'
#!/usr/bin/env bash
[ "${1:-}" != --session ] || shift 2
echo "$*" >>"$FLEET_SANDBOX/herdr.log"
case "${1:-} ${2:-}" in
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"sw1"},"root_pane":{"pane_id":"sp0"}}}' ;;
  "pane split") echo "{\"result\":{\"pane\":{\"pane_id\":\"sp$RANDOM\"}}}" ;;
  "pane process-info") echo '{"result":{"process_info":{"foreground_process_group_id":2,"shell_pid":1}}}' ;;
  "agent get") echo '{"result":{"agent":{"agent_status":"idle","state_change_seq":0}}}' ;;
  *) echo '{}' ;;
esac
S
for t in gh curl; do printf '#!/usr/bin/env bash\necho "%s $*" >>"$FLEET_SANDBOX/network.log"; echo "sandbox: %s is disabled here" >&2; exit 1\n' "$t" "$t" >"$root/bin/$t"; done
chmod +x "$root/bin/herdr" "$root/bin/gh" "$root/bin/curl"
: >"$root/herdr.log"; : >"$root/network.log"

[ $# -gt 0 ] || set -- "${SHELL:-/bin/bash}"
rc=0
unsets=(); for v in $(env | sed -n 's/^\(AWS_[A-Za-z0-9_]*\)=.*/\1/p'); do unsets+=(-u "$v"); done
env -u HERDR_ENV -u FLEET_SESSION -u LINEAR_API_KEY -u FLEET_ROLE -u FLEET_NAME -u FLEET_TEAM -u FLEET_WORKTREE \
  -u FLEET_REGISTRY -u FLEET_INBOX -u FLEET_WORKTREES -u FLEET_GH -u KUBECONFIG ${unsets[@]+"${unsets[@]}"} \
  FLEET_SANDBOX="$root" FLEET_STATE_DIR="$state_dir" FLEET_CONFIG_DIR="$config_dir" FLEET_SESSION=fleet-sandbox HOME="$root/home" \
  F="$here" PATH="$root/bin:$PATH" "$@" || rc=$?
exit "$rc"
