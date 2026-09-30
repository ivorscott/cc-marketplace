#!/usr/bin/env bash
# Offline tests for the team environment (env.sh, registry env-*, boot/retire/status wiring).
# Uses stub up/down commands and a shim herdr; never creates a kind cluster.
#   bash scripts/test/run.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
pass=0; failn=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { failn=$((failn + 1)); printf 'FAIL %s\n' "$1"; }
check() { # check <desc> <cmd...>
  local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export FLEET_STATE_DIR="$T/state" FLEET_CONFIG_DIR="$T/config" FLEET_REGISTRY="$T/state/fleet.json" FLEET_WORKTREES="$T/state/worktrees"
export FLEET_SESSION=test HOME="$T/home"; mkdir -p "$HOME" "$FLEET_CONFIG_DIR" "$T/bin"
unset FLEET_WORKTREE KUBECONFIG
REG="$SCRIPTS/registry.sh"; ENV="$SCRIPTS/env.sh"

# Stub up/down: log arguments, write a fake one-context kubeconfig.
cat >"$T/up.sh" <<'S'
#!/usr/bin/env bash
echo "up $*" >>"$STUB_LOG"; [ -z "${STUB_FAIL:-}" ] || exit 1
printf 'contexts:\n- context:\n    cluster: c\n  name: %s\n' "$1" >"$2"
S
cat >"$T/down.sh" <<'S'
#!/usr/bin/env bash
echo "down $*" >>"$STUB_LOG"
S
# Shim nc so the port probe never depends on what listens on this machine.
cat >"$T/bin/nc" <<'S'
#!/usr/bin/env bash
case " ${NC_BUSY:-} " in *" $3 "*) exit 0 ;; esac; exit 1
S
chmod +x "$T/up.sh" "$T/down.sh" "$T/bin/nc"; export PATH="$T/bin:$PATH"
 export STUB_LOG="$T/stub.log"; : >"$STUB_LOG"

# Repo with an env declaration, plus one without.
mkrepo() { # mkrepo <dir> <with-env>
  git init -q -b main "$1"; git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  if [ "$2" = yes ]; then
    mkdir -p "$1/.claude"
    jq -n --arg u "$T/up.sh" --arg d "$T/down.sh" '{
      up: "\($u) {{cluster}} {{kubeconfig}} {{http_port}} {{https_port}} {{branch}}",
      down: "\($d) {{cluster}} {{http_port}}", kubeconfig: "true"}' >"$1/.claude/fleet-env.json"
  fi
}
mkrepo "$T/repo" yes; mkrepo "$T/plain" no
addteam() { "$REG" add "$(jq -cn --arg n "$1/builder" --arg t "$1" --arg r "$2" '{name: $n, team: $t, repo: $r, tier: "Worker", status: "Working", herdr_ref: "x", pane: "p"}')"; }
for t in a b c; do addteam "build-$t" "$T/repo"; done
addteam build-plain "$T/plain"; addteam build-plain2 "$T/plain"
slot() { "$REG" env-get "$1" | jq -r '"\(.slot) \(.http_port) \(.https_port)"'; }
calls() { grep -c "^$1" "$STUB_LOG" || true; }

echo 'max_envs = 2' >"$FLEET_CONFIG_DIR/config.toml"
eq "max_envs reads config" "$(bash -c ". $SCRIPTS/common.sh; max_envs")" 2

# Ports
"$ENV" up build-a >/dev/null 2>&1; eq "first team gets slot 0 (8080/8443)" "$(slot build-a)" "0 8080 8443"
"$ENV" up build-b >/dev/null 2>&1; eq "second team gets slot 1 (8090/8453)" "$(slot build-b)" "1 8090 8453"
eq "up state is Up" "$("$REG" env-get build-a | jq -r .state)" Up
eq "cluster is fleet-<team>" "$("$REG" env-get build-a | jq -r .cluster)" fleet-build-a
KC="$FLEET_STATE_DIR/env/build-a/kubeconfig"
check "kubeconfig recorded at expected path" test "$("$REG" env-get build-a | jq -r .kubeconfig)" = "$KC"
eq "kubeconfig mode 600" "$(stat -f %Lp "$KC" 2>/dev/null || stat -c %a "$KC")" 600
eq "kubeconfig has one context" "$(awk '/^contexts:/ {on=1; next} on && /^- / {n++} END {print n}' "$KC")" 1
check "stub up got ports and cluster" grep -q "^up fleet-build-a $KC 8080 8443 " "$STUB_LOG"

# Busy host ports: slot 0 is skipped when 8080 is in use
NC_BUSY=8080 "$ENV" up build-c >/dev/null 2>&1; eq "busy host port skips its slot" "$("$REG" env-get build-c | jq -r .state)" Queued
"$REG" env-release build-c

# Cap
before="$(calls up)"
"$ENV" up build-c >/dev/null 2>"$T/err"; rc=$?
eq "over cap exits 75" "$rc" 75
check "queued message is clear" grep -q "queued: max_envs=2" "$T/err"
eq "no third up call" "$(calls up)" "$before"
eq "third env recorded Queued" "$("$REG" env-get build-c | jq -r .state)" Queued
eq "queued env has no ports" "$("$REG" env-get build-c | jq -r '.http_port')" null

# Idempotency
"$ENV" up build-a >/dev/null 2>&1; eq "repeated up is a no-op" "$(calls up)" "$before"

# Registry guard and slot reuse on down
: >"$STUB_LOG"
"$ENV" down build-plain >/dev/null 2>&1; eq "down with no registry env runs no stub down" "$(calls down)" 0
"$REG" env-set build-plain cluster=app-studio state=Up >/dev/null
"$ENV" down build-plain >/dev/null 2>&1; rc=$?
eq "down with a foreign cluster name runs no stub down" "$(calls down)" 0
check "down with a foreign cluster name refuses" test "$rc" -ne 0
"$REG" env-release build-plain
"$ENV" down build-a >/dev/null 2>&1
eq "down runs the stub down once" "$(calls down)" 1
check "down removes the env directory" test ! -e "$FLEET_STATE_DIR/env/build-a"
eq "down marks env Down" "$("$REG" env-get build-a | jq -r .state)" Down
"$ENV" up build-c >/dev/null 2>&1; eq "freed slot is reused by the next team" "$(slot build-c)" "0 8080 8443"
"$ENV" down build-c >/dev/null 2>&1; "$ENV" down build-b >/dev/null 2>&1

# Failure
export STUB_FAIL=1
"$ENV" up build-a >/dev/null 2>&1; rc=$?
eq "failing up gives state Failed" "$("$REG" env-get build-a | jq -r .state)" Failed
check "failing up exits non-zero" test "$rc" -ne 0
unset STUB_FAIL
"$ENV" down build-a >/dev/null 2>&1

# Branch source
: >"$STUB_LOG"; git -C "$T/repo" worktree add -q -b feature/x "$T/wt" >/dev/null 2>&1
FLEET_WORKTREE="$T/wt" "$ENV" up build-a >/dev/null 2>"$T/err"; eq "branch from FLEET_WORKTREE" "$("$REG" env-get build-a | jq -r .branch)" feature/x
check "warns when branch is not on origin" grep -q "not on origin" "$T/err"
"$ENV" down build-a >/dev/null 2>&1
(cd "$T/wt" && "$ENV" up build-a >/dev/null 2>&1); eq "branch from \$PWD without FLEET_WORKTREE" "$("$REG" env-get build-a | jq -r .branch)" feature/x
"$ENV" down build-a >/dev/null 2>&1
FLEET_WORKTREE="$T/wt" "$ENV" up --branch other/y build-a >/dev/null 2>&1; eq "--branch overrides" "$("$REG" env-get build-a | jq -r .branch)" other/y
"$ENV" down build-a >/dev/null 2>&1

# No fleet-env.json
: >"$STUB_LOG"; "$ENV" up build-plain2 >/dev/null 2>&1; rc=$?
eq "no fleet-env.json: exit 0" "$rc" 0
eq "no fleet-env.json: no stub calls" "$(wc -l <"$STUB_LOG" | tr -d ' ')" 0
eq "no fleet-env.json: no env recorded" "$("$REG" list --envs | jq 'has("build-plain2")')" false

# boot.sh and retire.sh with a shim herdr
cat >"$T/bin/herdr" <<'S'
#!/usr/bin/env bash
shift 2 # --session <name>
echo "$*" >>"$HERDR_LOG"
case "$1 $2" in
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"p0"}}}' ;;
  "pane split") n=$(( $(grep -c '^pane split' "$HERDR_LOG") )); echo "{\"result\":{\"pane\":{\"pane_id\":\"p$n\"}}}" ;;
  "pane process-info") echo '{"result":{"process_info":{"foreground_process_group_id":2,"shell_pid":1}}}' ;;
  "agent get") echo '{"result":{"agent":{"agent_status":"idle"}}}' ;;
  *) echo '{}' ;;
esac
S
chmod +x "$T/bin/herdr"; export HERDR_LOG="$T/herdr.log"
export PATH="$T/bin:$PATH"; export FLEET_FORCE=1

: >"$HERDR_LOG"; "$SCRIPTS/boot.sh" build envt "$T/repo" task >/dev/null 2>&1
K="KUBECONFIG=$FLEET_STATE_DIR/env/build-envt/kubeconfig"
eq "boot: workspace create (lead) gets KUBECONFIG" "$(grep '^workspace create' "$HERDR_LOG" | grep -c -- "--env $K")" 1
eq "boot: every pane split gets KUBECONFIG" "$(grep '^pane split' "$HERDR_LOG" | grep -c -- "--env $K")" "$(grep -c '^pane split' "$HERDR_LOG")"
check "boot: env dir exists but no kubeconfig file yet" test -d "$FLEET_STATE_DIR/env/build-envt" -a ! -e "$FLEET_STATE_DIR/env/build-envt/kubeconfig"
eq "boot: no cluster created" "$(calls up)" 0
check "boot: tester allow has env.sh up with the scripts path" grep -q "env.sh up" <(grep '^agent start build-envt-tester' "$HERDR_LOG")
eq "boot: no unsubstituted {{scripts}}" "$(grep -c '{{scripts}}' "$HERDR_LOG")" 0

: >"$HERDR_LOG"; "$SCRIPTS/boot.sh" build plainbt "$T/plain" task >/dev/null 2>&1
eq "boot without file: no KUBECONFIG arg (3.0.1 behaviour)" "$(grep -c -- '--env KUBECONFIG' "$HERDR_LOG")" 0
check "boot without file: no env dir" test ! -e "$FLEET_STATE_DIR/env/build-plainbt"

# No env anywhere: status header and retire JSON are the 3.0.1 ones
: >"$HERDR_LOG"; "$SCRIPTS/boot.sh" build plainst "$T/plain" task >/dev/null 2>&1
saved="$(cat "$FLEET_REGISTRY")"; jq 'del(.envs)' <<<"$saved" >"$FLEET_REGISTRY"
eq "no envs: status header is the 3.0.1 one" "$("$SCRIPTS/status.sh" --team build-plainst 2>/dev/null | head -1 | tr -s ' ')" "AGENT TIER STATUS ESC HERDR ASSIGNMENT"
"$SCRIPTS/retire.sh" build-plainst >"$T/r0.json" 2>/dev/null
eq "no envs: retire JSON keys are the 3.0.1 ones" "$(jq -c 'keys' "$T/r0.json")" '["kept_worktrees","retired"]'
printf '%s' "$saved" >"$FLEET_REGISTRY"

# status column, then retire cleans the env up
"$ENV" up build-envt >/dev/null 2>&1
eq "status shows slot and state" "$("$SCRIPTS/status.sh" --team build-envt 2>/dev/null | awk 'NR==2 {print $5}')" slot-0-Up
: >"$STUB_LOG"; "$SCRIPTS/retire.sh" build-envt >"$T/retire.json" 2>/dev/null
eq "retire runs the stub down" "$(calls down)" 1
eq "retire frees the slot" "$("$REG" env-get build-envt | jq -r .state)" Down
check "retire removes the env directory" test ! -e "$FLEET_STATE_DIR/env/build-envt"
eq "retire omits kept_envs when none were kept" "$(jq -c 'has("kept_envs")' "$T/retire.json")" false
: >"$STUB_LOG"; "$SCRIPTS/retire.sh" build-plainbt >/dev/null 2>&1; eq "retire without env runs no down" "$(calls down)" 0

# Isolation
if command -v kubectl >/dev/null 2>&1; then
  eq "absent team kubeconfig shows no contexts" "$(KUBECONFIG="$FLEET_STATE_DIR/env/none/kubeconfig" kubectl config get-contexts -o name 2>/dev/null)" ""
else echo "skip kubectl not installed"; fi

printf '\n%d passed, %d failed\n' "$pass" "$failn"
[ "$failn" = 0 ]
