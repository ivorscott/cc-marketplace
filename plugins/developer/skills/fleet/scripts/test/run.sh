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
export FLEET_SESSION=test FLEET_MACHINE=test HOME="$T/home"; mkdir -p "$HOME" "$FLEET_CONFIG_DIR" "$T/bin"
unset FLEET_WORKTREE KUBECONFIG
REG="$SCRIPTS/registry.sh"; ENV="$SCRIPTS/env.sh"

# Docker is always a stub: FLEET_DOCKER points at it, and a docker shim first on PATH records
# any call that would reach a real binary and fails it. kind is never called at all.
export DOCKER_LOG="$T/docker.log" REAL_DOCKER_LOG="$T/realdocker.log" DKDIR="$T/dk"; mkdir -p "$DKDIR"
: >"$DOCKER_LOG"; : >"$REAL_DOCKER_LOG"
cat >"$T/bin/docker" <<'S'
#!/usr/bin/env bash
echo "$*" >>"$REAL_DOCKER_LOG"; exit 1
S
cat >"$T/docker-stub" <<'S'
#!/usr/bin/env bash
# images.tsv: ID <tab> repo:tag <tab> labels <tab> pinned (rmi fails: also tagged elsewhere / in use)
echo "$*" >>"$DOCKER_LOG"
case "$1 $2" in
  "info "*) [ -z "${DOCKER_DOWN:-}" ]; exit ;;
  "image ls")
    case "$4" in
      reference=*) awk -F'\t' -v p="${4#reference=*:}" '{n = length(p) + 1; if (substr($2, length($2) - n + 1) == ":" p) print $2}' "$DKDIR/images.tsv" ;;
      label=*) awk -F'\t' -v l="${4#label=}" '$3 == l {print $1}' "$DKDIR/images.tsv" ;;
    esac
    exit 0 ;;
  "buildx ls") cat "$DKDIR/builders"; exit 0 ;;
  "buildx rm") grep -vx "${4:-}\*\?" "$DKDIR/builders" >"$DKDIR/b.tmp"; mv "$DKDIR/b.tmp" "$DKDIR/builders"; exit 0 ;;
esac
if [ "$1" = rmi ]; then
  x="$2"; awk -F'\t' -v x="$x" '($1 == x || $2 == x) && $4 == 1 {f = 1} END {exit !f}' "$DKDIR/images.tsv" && exit 1
  awk -F'\t' -v x="$x" '!($1 == x || $2 == x)' "$DKDIR/images.tsv" >"$DKDIR/i.tmp"; mv "$DKDIR/i.tmp" "$DKDIR/images.tsv"; exit 0
fi
exit 0
S
# df shim: DF_GB GiB free (DF_FAIL=1: df fails)
cat >"$T/bin/df" <<'S'
#!/usr/bin/env bash
[ -z "${DF_FAIL:-}" ] || exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\nfake 1 1 %s 1%% /\n' $((${DF_GB:-500} * 1048576))
S
chmod +x "$T/bin/docker" "$T/docker-stub" "$T/bin/df"; export FLEET_DOCKER="$T/docker-stub" DF_GB=500
dkreset() { # a team's tag/label images, foreign images, foreign builder
  printf 'ID1\tapp:fleet-build-a\t\t0\nID2\timg2:latest\tfleet.team=build-a\t0\nID3\tother:latest\t\t0\nID4\tsvc:latest\tfleet.team=other\t0\nID5\tshared:v1\tfleet.team=build-a\t1\nID6\tapp:fleet-build-b\t\t0\n' >"$DKDIR/images.tsv"
  printf 'default\nfleet-build-a*\nfleet-build-b\n' >"$DKDIR/builders"; : >"$DOCKER_LOG"
}

# Stub kubectl (env.sh's FLEET_KUBECTL): lists and renames the one context of the fake kubeconfig.
cat >"$T/kubectl" <<'S'
#!/usr/bin/env bash
kc="${!#}"; [ "$1 $2" = "config get-contexts" ] && { sed -n 's/^  name: //p' "$kc"; exit 0; }
if [ "$1 $2" = "config rename-context" ]; then sed "s/^  name: $3\$/  name: $4/" "$kc" >"$kc.tmp" && mv "$kc.tmp" "$kc"; exit 0; fi
exit 1
S
chmod +x "$T/kubectl"; export FLEET_KUBECTL="$T/kubectl"

# Stub up/down: log arguments, write a fake one-context kubeconfig.
cat >"$T/up.sh" <<'S'
#!/usr/bin/env bash
echo "up $*" >>"$STUB_LOG"; echo "env $FLEET_IMAGE_TAG|$FLEET_IMAGE_LABEL|$FLEET_BUILDER" >>"$STUB_LOG"; [ -z "${STUB_FAIL:-}" ] || exit 1
[ ! -f BRANCH_MARKER ] || echo "src $(cat BRANCH_MARKER)" >>"$STUB_LOG"
printf 'contexts:\n- context:\n    cluster: c\n  name: %s\n' "$1" >"$2"
S
cat >"$T/down.sh" <<'S'
#!/usr/bin/env bash
echo "down $*" >>"$STUB_LOG"; [ -z "${STUB_DOWN_FAIL:-}" ] || exit 1
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
# A pushed main: commits already on origin are not "unpushed" when a worktree is retired.
echo tracked >"$T/repo/tracked.txt"; git -C "$T/repo" add tracked.txt; git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q -m tracked
git init -q --bare "$T/origin.git"; git -C "$T/repo" remote add origin "$T/origin.git"; git -C "$T/repo" push -q origin main 2>/dev/null
cd "$T/repo" # env.sh up falls back to $PWD for {{branch}}; never depend on the caller's cwd
addteam() { "$REG" add "$(jq -cn --arg n "$1/builder" --arg t "$1" --arg r "$2" '{name: $n, team: $t, repo: $r, tier: "Worker", status: "Working", herdr_ref: "x", pane: "p"}')"; }
for t in a b c; do addteam "build-$t" "$T/repo"; done
addteam build-plain "$T/plain"; addteam build-plain2 "$T/plain"
slot() { "$REG" env-get "$1" | jq -r '"\(.slot) \(.http_port) \(.https_port)"'; }
calls() { grep -c "^$1" "$STUB_LOG" || true; }

echo 'max_envs = 2' >"$FLEET_CONFIG_DIR/config.toml"
eq "max_envs reads config" "$(bash -c ". $SCRIPTS/common.sh; max_envs")" 2

# config_list: tool permissions live in config, never in templates
cl() { bash -c ". $SCRIPTS/common.sh; config_list $1" 2>/dev/null; }
eq "config_list: missing key is []" "$(cl tracker_allow)" '[]'
cat >>"$FLEET_CONFIG_DIR/config.toml" <<'C'
tracker_allow = ["mcp__jira__get_issue", "Bash(jira issue view:*)"]  # Jira
forge_allow = [
  "Bash(glab mr view:*)",
  "Bash(glab mr create:*)",
]
bad_allow = [1, 2]
C
eq "config_list: one-line array" "$(cl tracker_allow)" '["mcp__jira__get_issue","Bash(jira issue view:*)"]'
eq "config_list: multi-line array, trailing comma" "$(cl forge_allow)" '["Bash(glab mr view:*)","Bash(glab mr create:*)"]'
eq "config_list: non-strings ignored" "$(cl bad_allow)" '[]'

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
"$REG" env-set build-plain cluster=foreign-cluster state=Up >/dev/null
dkreset; "$ENV" down build-plain >/dev/null 2>&1; rc=$?
eq "down with a foreign cluster name makes no docker call" "$(wc -l <"$DOCKER_LOG" | tr -d ' ')" 0
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

# up runs in a checkout of the branch under test, not the repo's own checkout
echo feature-x >"$T/wt/BRANCH_MARKER"
git -C "$T/wt" add BRANCH_MARKER; git -C "$T/wt" -c user.email=t@t -c user.name=t commit -q -m marker
: >"$STUB_LOG"
"$ENV" up --branch feature/x build-a >/dev/null 2>&1
check "up sees the branch's files" grep -q "^src feature-x$" "$STUB_LOG"
check "repo checkout untouched (still on main, no marker)" test "$(git -C "$T/repo" rev-parse --abbrev-ref HEAD)" = main -a ! -e "$T/repo/BRANCH_MARKER"
check "temporary checkout removed after up" test ! -e "$FLEET_STATE_DIR/env/build-a/src"
eq "no leftover worktree" "$(git -C "$T/repo" worktree list | grep -c "/env/build-a/src" || true)" 0
"$ENV" down build-a >/dev/null 2>&1
export STUB_FAIL=1
"$ENV" up --branch feature/x build-a >/dev/null 2>&1
check "temporary checkout removed after a failed up" test ! -e "$FLEET_STATE_DIR/env/build-a/src"
unset STUB_FAIL
"$ENV" down build-a >/dev/null 2>&1

# No fleet-env.json
: >"$STUB_LOG"; "$ENV" up build-plain2 >/dev/null 2>&1; rc=$?
eq "no fleet-env.json: exit 0" "$rc" 0
eq "no fleet-env.json: no stub calls" "$(wc -l <"$STUB_LOG" | tr -d ' ')" 0
eq "no fleet-env.json: no env recorded" "$("$REG" list --envs | jq 'has("build-plain2")')" false

# env.sh down removes only the team's own images and builder
: >"$STUB_LOG"; "$ENV" up build-a >/dev/null 2>&1
check "up exports the image tag, label and builder to the repo's up" grep -qx 'env fleet-build-a|fleet.team=build-a|fleet-build-a' "$STUB_LOG"
eq "up records the image marks in the registry" "$("$REG" env-get build-a | jq -r '[.image_tag, .image_label, .builder] | join("|")')" 'fleet-build-a|fleet.team=build-a|fleet-build-a'
dkreset; "$ENV" down build-a >"$T/dn.out" 2>"$T/dn.err"; rc=$?
eq "down with images: exit 0" "$rc" 0
eq "down removes the tag match and the label match, tries the pinned one" "$(grep '^rmi' "$DOCKER_LOG" | LC_ALL=C sort | tr '\n' ',')" 'rmi ID2,rmi ID5,rmi app:fleet-build-a,'
eq "down never forces an rmi and never prunes" "$(grep -cE '^rmi -|prune' "$DOCKER_LOG")" 0
eq "down: the only --force is the team's own builder" "$(grep -c -- '--force' "$DOCKER_LOG")" 1
eq "down leaves foreign and pinned images" "$(cut -f1 "$DKDIR/images.tsv" | tr '\n' ',')" 'ID3,ID4,ID5,ID6,'
eq "down removes only the team's builder" "$(tr '\n' ',' <"$DKDIR/builders")" 'default,fleet-build-b,'
eq "down removes exactly one builder" "$(grep -c '^buildx rm' "$DOCKER_LOG")" 1
check "down reports what it removed" grep -q 'removed 2 images, builder fleet-build-a' "$T/dn.err"
check "down warns about an image it could not remove" grep -q 'could not remove image ID5' "$T/dn.err"
eq "down: slot freed even with a pinned image" "$("$REG" env-get build-a | jq -r .state)" Down
eq "no docker call reached the real binary" "$(wc -l <"$REAL_DOCKER_LOG" | tr -d ' ')" 0
# a failed repo down leaves images alone
"$ENV" up build-a >/dev/null 2>&1; dkreset
STUB_DOWN_FAIL=1 "$ENV" down build-a >/dev/null 2>&1; rc=$?
check "failed repo down exits non-zero" test "$rc" -ne 0
eq "failed repo down: no docker call" "$(wc -l <"$DOCKER_LOG" | tr -d ' ')" 0
# docker unusable: down still succeeds and frees the slot
DOCKER_DOWN=1 "$ENV" down build-a >/dev/null 2>"$T/dn.err"; rc=$?
eq "docker daemon down: env down exit 0" "$rc" 0
check "docker daemon down: warns" grep -q 'docker unavailable' "$T/dn.err"
eq "docker daemon down: slot freed" "$("$REG" env-get build-a | jq -r .state)" Down
"$ENV" up build-a >/dev/null 2>&1; FLEET_DOCKER=/nonexistent/docker "$ENV" down build-a >/dev/null 2>&1; rc=$?
eq "docker missing: env down exit 0" "$rc" 0
# an env recorded without marks (an older fleet) gets no image cleanup
"$ENV" up build-a >/dev/null 2>&1; "$REG" env-set build-a image_tag= image_label= builder= >/dev/null; dkreset
"$ENV" down build-a >/dev/null 2>&1
eq "down without recorded marks makes no docker call" "$(grep -c '^rmi\|^buildx' "$DOCKER_LOG")" 0
: >"$STUB_LOG"

# boot.sh and retire.sh with a shim herdr
cat >"$T/bin/herdr" <<'S'
#!/usr/bin/env bash
shift 2 # --session <name>
echo "$*" >>"$HERDR_LOG"
case "$1 $2" in
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"p0"}}}' ;;
  "pane split") n=$(( $(grep -c '^pane split' "$HERDR_LOG") )); echo "{\"result\":{\"pane\":{\"pane_id\":\"p$n\"}}}" ;;
  "pane process-info")
    if [ -n "${DEAD_ONCE:-}" ] && [ -e "$DEAD_ONCE" ]; then rm -f "$DEAD_ONCE"; echo '{"result":{"process_info":{"foreground_process_group_id":1,"shell_pid":1}}}'
    else echo '{"result":{"process_info":{"foreground_process_group_id":2,"shell_pid":1}}}'; fi ;;
  "agent get") echo '{"result":{"agent":{"agent_status":"idle"}}}' ;;
  "notification show") if [ -n "${NOTIFY_FAIL:-}" ]; then echo "herdr: no server" >&2; exit 1; fi; echo '{}' ;;
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
check "boot: tester allow has the team-scoped kubectl context" grep -q -- "kubectl --context fleet-build-envt get" <(grep '^agent start build-envt-tester' "$HERDR_LOG")
eq "boot: no unsubstituted {{team}} or {{worktree}} in an allow list" "$(grep '^agent start' "$HERDR_LOG" | grep -c '{{team}}\|{{worktree}}')" 0
eq "boot: every agent gets tracker_allow" "$(grep '^agent start' "$HERDR_LOG" | grep -c 'jira issue view')" "$(grep -c '^agent start' "$HERDR_LOG")"
eq "boot: every agent gets forge_allow" "$(grep '^agent start' "$HERDR_LOG" | grep -c 'glab mr create')" "$(grep -c '^agent start' "$HERDR_LOG")"
# Permission mode: every agent starts in auto unless FLEET_PERMISSION_MODE or config.toml say otherwise
eq "boot: every agent starts in --permission-mode auto" "$(grep '^agent start' "$HERDR_LOG" | grep -c -- '--permission-mode auto')" "$(grep -c '^agent start' "$HERDR_LOG")"
eq "boot: nobody starts in acceptEdits by default" "$(grep -c -- '--permission-mode acceptEdits' "$HERDR_LOG")" 0
: >"$HERDR_LOG"; FLEET_PERMISSION_MODE=acceptEdits "$SCRIPTS/boot.sh" build envm "$T/repo" task >/dev/null 2>&1
agents_per_boot="$(grep -c '^agent start' "$HERDR_LOG")"
eq "boot: FLEET_PERMISSION_MODE overrides the default" "$(grep '^agent start' "$HERDR_LOG" | grep -c -- '--permission-mode acceptEdits')" "$(grep -c '^agent start' "$HERDR_LOG")"
cp "$FLEET_CONFIG_DIR/config.toml" "$T/config.perm.bak"; printf 'permission_mode = "manual"\n' >>"$FLEET_CONFIG_DIR/config.toml"
: >"$HERDR_LOG"; "$SCRIPTS/boot.sh" build envc "$T/repo" task >/dev/null 2>&1
eq "boot: config.toml permission_mode is used" "$(grep '^agent start' "$HERDR_LOG" | grep -c -- '--permission-mode manual')" "$(grep -c '^agent start' "$HERDR_LOG")"
cp "$T/config.perm.bak" "$FLEET_CONFIG_DIR/config.toml"
# A start eaten by a still-starting shell is retried once, not left a Zombie
: >"$HERDR_LOG"; export DEAD_ONCE="$T/dead_once"; : >"$DEAD_ONCE"
"$SCRIPTS/boot.sh" build envr "$T/repo" task >"$T/envr.out" 2>&1
unset DEAD_ONCE
eq "boot: a dead pane after start is started again once" "$(grep -c '^agent start' "$HERDR_LOG")" "$((agents_per_boot + 1))"
eq "boot: the retried agent is not a Zombie" "$(grep -c Zombie "$T/envr.out")" 0
eq "templates name no tracker or forge tool" "$(cat "$SCRIPTS"/../templates/*.json | grep -ciE 'linear|jira|gh pr|glab')" 0

: >"$HERDR_LOG"; "$SCRIPTS/boot.sh" build plainbt "$T/plain" task >/dev/null 2>&1
eq "boot without file: no KUBECONFIG arg (3.0.1 behaviour)" "$(grep -c -- '--env KUBECONFIG' "$HERDR_LOG")" 0
check "boot without file: no env dir" test ! -e "$FLEET_STATE_DIR/env/build-plainbt"

# No env anywhere: status header and retire JSON are the 3.0.1 ones
: >"$HERDR_LOG"; "$SCRIPTS/boot.sh" build plainst "$T/plain" task >/dev/null 2>&1
saved="$(cat "$FLEET_REGISTRY")"; jq 'del(.envs)' <<<"$saved" >"$FLEET_REGISTRY"
eq "no envs: status header is the 3.0.1 one" "$("$SCRIPTS/status.sh" --team build-plainst 2>/dev/null | sed -n 2p | tr -s ' ')" "AGENT TIER STATUS ESC HERDR ASSIGNMENT"
"$SCRIPTS/retire.sh" build-plainst >"$T/r0.json" 2>"$T/r0.err"
eq "no envs: retire prints no env line" "$(cat "$T/r0.err" "$T/r0.json" | grep -ci 'environment\|env\.sh\|nothing to do')" 0
eq "no envs: retire JSON keys are the 3.0.1 ones" "$(jq -c 'keys' "$T/r0.json")" '["kept_worktrees","retired"]'
printf '%s' "$saved" >"$FLEET_REGISTRY"

# status column, then retire cleans the env up
"$ENV" up build-envt >/dev/null 2>&1
eq "status shows slot and state" "$("$SCRIPTS/status.sh" --team build-envt 2>/dev/null | awk 'NR==3 {print $5}')" slot-0-Up
: >"$STUB_LOG"; "$SCRIPTS/retire.sh" build-envt >"$T/retire.json" 2>/dev/null
eq "retire runs the stub down" "$(calls down)" 1
eq "retire frees the slot" "$("$REG" env-get build-envt | jq -r .state)" Down
check "retire removes the env directory" test ! -e "$FLEET_STATE_DIR/env/build-envt"
eq "retire omits kept_envs when none were kept" "$(jq -c 'has("kept_envs")' "$T/retire.json")" false
: >"$STUB_LOG"; "$SCRIPTS/retire.sh" build-plainbt >/dev/null 2>&1; eq "retire without env runs no down" "$(calls down)" 0

# env.sh refuses a foreign cluster before anything runs
mkrepo "$T/bad" yes
jq --arg u "$T/up.sh" '.up = "CLUSTER=foreign-cluster \($u) {{cluster}} {{kubeconfig}}"' "$T/bad/.claude/fleet-env.json" >"$T/bad.json" && mv "$T/bad.json" "$T/bad/.claude/fleet-env.json"
addteam build-bad "$T/bad"
: >"$STUB_LOG"; "$ENV" up build-bad >/dev/null 2>&1; rc=$?
check "template CLUSTER=foreign-cluster: refused (non-zero)" test "$rc" != 0
eq "template CLUSTER=foreign-cluster: stub up never ran" "$(calls up)" 0
eq "template CLUSTER=foreign-cluster: no env claimed" "$("$REG" list --envs | jq 'has("build-bad")')" false
: >"$STUB_LOG"; CLUSTER=foreign-cluster "$ENV" up build-a >/dev/null 2>&1; rc=$?
check "ambient CLUSTER=foreign-cluster: refused (non-zero)" test "$rc" != 0
eq "ambient CLUSTER=foreign-cluster: stub up never ran" "$(calls up)" 0
: >"$STUB_LOG"; CLUSTER=kind-fleet-build-a "$ENV" up build-a >/dev/null 2>&1; rc=$?
check "ambient CLUSTER=kind-fleet-<team>: up refused" test "$rc" != 0
eq "ambient CLUSTER=kind-fleet-<team>: stub up never ran" "$(calls up)" 0
: >"$STUB_LOG"; CLUSTER=kind-fleet-build-a "$ENV" down build-a >/dev/null 2>&1; rc=$?
check "ambient CLUSTER=kind-fleet-<team>: down refused" test "$rc" != 0
: >"$STUB_LOG"; CLUSTER=other "$ENV" up build-a >/dev/null 2>&1; rc=$?
check "ambient CLUSTER=other (not fleet-<team>): refused" test "$rc" != 0
eq "ambient CLUSTER=other: stub up never ran" "$(calls up)" 0
jq --arg u "$T/up.sh" '.up = "CLUSTER={{cluster}} \($u) {{cluster}} {{kubeconfig}}"' "$T/repo/.claude/fleet-env.json" >"$T/ok.json" && mv "$T/ok.json" "$T/repo/.claude/fleet-env.json"
: >"$STUB_LOG"; CLUSTER=fleet-build-a "$ENV" up build-a >/dev/null 2>&1; rc=$?
eq "CLUSTER=fleet-<team> (ambient and template {{cluster}}) is accepted" "$rc" 0
eq "stub up ran once for the accepted cluster" "$(calls up)" 1
check "context is renamed to fleet-<team>" grep -q '^  name: fleet-build-a$' "$FLEET_STATE_DIR/env/build-a/kubeconfig"
eq "exactly one context after the rename" "$(grep -c '^  name: ' "$FLEET_STATE_DIR/env/build-a/kubeconfig")" 1
"$ENV" down build-a >/dev/null 2>&1

# a missing tool is named, and no slot is claimed
mkrepo "$T/notool" yes
jq '.up = "FOO=1 no-such-tool-xyz {{cluster}}"' "$T/notool/.claude/fleet-env.json" >"$T/nt.json" && mv "$T/nt.json" "$T/notool/.claude/fleet-env.json"
addteam build-notool "$T/notool"
"$ENV" up build-notool >"$T/nt.out" 2>&1; rc=$?
check "missing tool: up fails" test "$rc" != 0
check "missing tool: message names the tool and the key" grep -q 'missing tool: no-such-tool-xyz (needed by fleet-env.json up)' "$T/nt.out"
eq "missing tool: no slot claimed" "$("$REG" list --envs | jq 'has("build-notool")')" false
FLEET_KUBECTL=no-such-kubectl-xyz "$ENV" up build-a >"$T/nk.out" 2>&1; rc=$?
check "missing kubectl: up fails naming it" grep -q 'missing tool: no-such-kubectl-xyz' "$T/nk.out"

# retire names untracked files in a kept worktree
git -C "$T/repo" worktree add -q -b keep-br "$T/wt-keep" >/dev/null 2>&1
mkdir -p "$T/wt-keep/src"; echo 'package x' >"$T/wt-keep/src/new.go"
"$REG" add "$(jq -cn --arg t build-keep --arg r "$T/repo" --arg w "$T/wt-keep" '{name: "build-keep/tester", team: $t, repo: $r, tier: "Worker", status: "Working", herdr_ref: "x", pane: "p", worktree: $w}')"
"$SCRIPTS/retire.sh" build-keep >"$T/keep.json" 2>"$T/keep.err"
eq "retire keeps a worktree with untracked files" "$(jq -c '.kept_worktrees' "$T/keep.json")" "[\"$T/wt-keep\"]"
eq "retire lists untracked files in kept_untracked" "$(jq -c --arg w "$T/wt-keep" '.kept_untracked[$w] | sort' "$T/keep.json")" '["src/new.go"]'
check "retire warns with the untracked file name" grep -q '?? src/new.go' "$T/keep.err"

# retire --summary: read-only, needs no herdr, gathers PRs, UNVERIFIED, escalations, worktrees
git -C "$T/repo" remote set-url origin git@github.com:acme/widgets.git
git -C "$T/repo" worktree add -q -b sum-br "$T/wt-sum" >/dev/null 2>&1
echo r >"$T/wt-sum/report.md"
"$REG" add "$(jq -cn --arg r "$T/repo" --arg w "$T/wt-sum" '{name: "build-sum/tester", team: "build-sum", repo: $r, tier: "Worker", status: "Done", herdr_ref: "x", pane: "p", worktree: $w, outcome: "Shipped", summary: "PASS on abc (PR #12); live curl UNVERIFIED"}')"
"$REG" add "$(jq -cn --arg r "$T/repo" '{name: "build-sum/lead", team: "build-sum", repo: $r, tier: "Lead", status: "Done", herdr_ref: "y", pane: "q", outcome: "Shipped", summary: "PR #12 and PR #13 open"}')"
"$REG" escalate build-sum/lead P1 "decide archived_at" >/dev/null 2>&1
before="$(cat "$FLEET_REGISTRY")"
: >"$HERDR_LOG"; HERDR_ENV= FLEET_SESSION= "$SCRIPTS/retire.sh" --summary build-sum >"$T/sum.json" 2>"$T/sum.err"; rc=$?
eq "summary: runs without herdr" "$rc" 0
eq "summary: registry unchanged" "$(cat "$FLEET_REGISTRY")" "$before"
eq "summary: no herdr calls" "$(wc -l <"$HERDR_LOG" | tr -d ' ')" 0
eq "summary: PRs deduped with the GitHub repo" "$(jq -c '[.prs[] | [.host, .repo, .number]]' "$T/sum.json")" '[["github.com","acme/widgets",12],["github.com","acme/widgets",13]]'
git -C "$T/plain" remote add origin https://gitlab.example.com/grp/sub/app.git
"$REG" add "$(jq -cn --arg r "$T/plain" '{name: "build-sum/builder", team: "build-sum", repo: $r, tier: "Worker", status: "Done", herdr_ref: "z", pane: "r", outcome: "Shipped", summary: "opened MR !7"}')"
"$SCRIPTS/retire.sh" --summary build-sum >"$T/sum2.json" 2>/dev/null
eq "summary: GitLab MR with its host and subgroup project" "$(jq -c '[.prs[] | select(.number == 7) | [.host, .repo]]' "$T/sum2.json")" '[["gitlab.example.com","grp/sub/app"]]'
eq "summary: UNVERIFIED rows" "$(jq -c '[.unverified[].name]' "$T/sum.json")" '["build-sum/tester"]'
eq "summary: open escalation" "$(jq -c '[.escalations[] | [.name, .severity, .open]]' "$T/sum.json")" '[["build-sum/lead","P1",true]]'
eq "summary: a report-only worktree is not kept, its report would be archived" "$(jq -c '[.worktrees[] | [.kept, .untracked, .archive]]' "$T/sum.json")" '[[false,[],["report.md"]]]'
"$SCRIPTS/retire.sh" --summary build-nope >/dev/null 2>&1; rc=$?
check "summary: unknown target fails" test "$rc" != 0

# retire: archive reports, ignore build outputs, keep only real work
export FLEET_ARCHIVE_DIR="$T/archive"
mkwt() { # mkwt <team> <role>: a worktree of $T/repo registered as <team>/<role>
  git -C "$T/repo" worktree add -q -b "br-$1-$2" "$T/wt-$1-$2" >/dev/null 2>&1
  "$REG" add "$(jq -cn --arg n "$1/$2" --arg t "$1" --arg r "$T/repo" --arg w "$T/wt-$1-$2" '{name: $n, team: $t, repo: $r, tier: "Worker", status: "Working", herdr_ref: "x", pane: "p", worktree: $w}')"
}
mkwt build-arc builder; W="$T/wt-build-arc-builder"
mkdir -p "$W/reports" "$W/node_modules/pkg" "$W/packages/a/node_modules" "$W/dist" "$W/.next" "$W/coverage"
echo n >"$W/notes.md"; echo r >"$W/reports/r.md"; echo m >"$W/node_modules/pkg/i.js"; echo m >"$W/packages/a/node_modules/y"
echo b >"$W/tsconfig.tsbuildinfo"; echo b >"$W/dist/o.js"; echo b >"$W/.next/c"; echo b >"$W/coverage/lcov"
"$SCRIPTS/retire.sh" --summary build-arc >"$T/arc.sum" 2>/dev/null
eq "summary: build outputs ignored, reports listed for archive" "$(jq -c '[.worktrees[] | [.kept, .untracked, (.archive | sort)]]' "$T/arc.sum")" '[[false,[],["notes.md","reports/r.md"]]]'
check "summary changes nothing on disk" test -d "$W/node_modules" -a ! -e "$T/archive"
"$SCRIPTS/retire.sh" build-arc >"$T/arc.json" 2>"$T/arc.err"
check "retire removes a worktree holding only reports and build outputs" test ! -e "$W"
eq "retire: no leftover git worktree" "$(git -C "$T/repo" worktree list | grep -c "$W" || true)" 0
check "retire archives the root report" cmp -s "$T/archive/build-arc-builder/notes.md" <(echo n)
check "retire archives reports/ files" cmp -s "$T/archive/build-arc-builder/reports/r.md" <(echo r)
eq "retire: archived reports only (no build output copied)" "$(cd "$T/archive/build-arc-builder" && find . -type f | sort | tr '\n' ' ')" './notes.md ./reports/r.md '
eq "retire JSON: nothing kept, archive dir named" "$(jq -c --arg w "$W" '[.kept_worktrees, .archived[$w]]' "$T/arc.json")" "[[],\"$T/archive/build-arc-builder\"]"

mkwt build-unp builder; W="$T/wt-build-unp-builder"
echo c >"$W/c.txt"; git -C "$W" add c.txt; git -C "$W" -c user.email=t@t -c user.name=t commit -q -m wip; sha="$(git -C "$W" rev-parse --short HEAD)"
echo r >"$W/report.md"
"$SCRIPTS/retire.sh" --summary build-unp >"$T/unp.sum" 2>/dev/null
eq "summary: unpushed commit means kept, SHA named" "$(jq -c '[.worktrees[] | [.kept, .unpushed]]' "$T/unp.sum")" "[[true,[\"$sha\"]]]"
"$SCRIPTS/retire.sh" build-unp >"$T/unp.json" 2>"$T/unp.err"
check "retire keeps a worktree with an unpushed commit" test -d "$W"
eq "retire names the unpushed commit in JSON" "$(jq -c --arg w "$W" '.kept_unpushed[$w]' "$T/unp.json")" "[\"$sha\"]"
check "retire warns with the unpushed SHA" grep -q "unpushed commits in $W: $sha" "$T/unp.err"
check "a kept worktree archives nothing" test ! -e "$T/archive/build-unp-builder"

mkwt build-src builder; W="$T/wt-build-src-builder"
mkdir -p "$W/src"; echo 'package x' >"$W/src/new.go"; echo r >"$W/report.md"; mkdir -p "$W/node_modules"; echo m >"$W/node_modules/i"
"$SCRIPTS/retire.sh" build-src >"$T/src.json" 2>"$T/src.err"
check "retire keeps a worktree with untracked source" test -d "$W"
eq "retire names untracked source, not reports or build output" "$(jq -c --arg w "$W" '.kept_untracked[$w]' "$T/src.json")" '["src/new.go"]'
check "retire warns naming the source file" grep -q '?? src/new.go' "$T/src.err"

mkwt build-mod builder; W="$T/wt-build-mod-builder"
echo changed >"$W/tracked.txt"
"$SCRIPTS/retire.sh" build-mod >"$T/mod.json" 2>"$T/mod.err"
check "retire keeps a worktree with uncommitted tracked edits" test -d "$W"
check "retire names the edited file" grep -q 'uncommitted in .*tracked.txt' "$T/mod.err"
eq "retire JSON lists kept_modified" "$(jq -c --arg w "$W" '.kept_modified[$w] | length' "$T/mod.json")" 1

mkwt build-bad builder2; W="$T/wt-build-bad-builder2"; echo r >"$W/r.md"; echo f >"$T/afile"
FLEET_ARCHIVE_DIR="$T/afile/sub" "$SCRIPTS/retire.sh" build-bad >"$T/ba.json" 2>"$T/ba.err"
check "a failed archive copy keeps the worktree" test -d "$W"
check "a failed archive copy says why" grep -q 'could not archive' "$T/ba.err"

mkwt build-one builder; mkwt build-one tester
echo r >"$T/wt-build-one-builder/report.md"
"$SCRIPTS/retire.sh" build-one/builder >"$T/one.json" 2>/dev/null
check "single-agent retire removes its worktree" test ! -e "$T/wt-build-one-builder"
check "single-agent retire archives under <team>-<role>" test -f "$T/archive/build-one-builder/report.md"
check "single-agent retire leaves the other worktree" test -d "$T/wt-build-one-tester"

# boot refuses below min_free_gb
cp "$FLEET_CONFIG_DIR/config.toml" "$T/config.bak"; echo 'max_agents = 100' >>"$FLEET_CONFIG_DIR/config.toml"
eq "min_free_gb defaults to 40" "$(bash -c ". $SCRIPTS/common.sh; min_free_gb")" 40
eq "warn_free_gb defaults to 75" "$(bash -c ". $SCRIPTS/common.sh; warn_free_gb")" 75
: >"$HERDR_LOG"; FLEET_FORCE= DF_GB=10 "$SCRIPTS/boot.sh" build disk1 "$T/plain" task >"$T/b.out" 2>"$T/b.err"; rc=$?
check "boot refuses below min_free_gb" test "$rc" -ne 0
check "boot refusal names the free disk and the setting" grep -q '10 GiB free, min_free_gb=40 (set FLEET_FORCE=1 or lower min_free_gb in' "$T/b.err"
eq "boot refusal makes no herdr call" "$(wc -l <"$HERDR_LOG" | tr -d ' ')" 0
: >"$HERDR_LOG"; FLEET_FORCE=1 DF_GB=10 "$SCRIPTS/boot.sh" build disk2 "$T/plain" task >/dev/null 2>&1; rc=$?
eq "FLEET_FORCE=1 boots below min_free_gb" "$rc" 0
check "forced boot reached herdr" grep -q '^workspace create' "$HERDR_LOG"
FLEET_FORCE= DF_GB=50 "$SCRIPTS/boot.sh" build disk3 "$T/plain" task >/dev/null 2>&1; eq "boot above min_free_gb" "$?" 0
echo 'min_free_gb = 5' >>"$FLEET_CONFIG_DIR/config.toml"
FLEET_FORCE= DF_GB=10 "$SCRIPTS/boot.sh" build disk4 "$T/plain" task >/dev/null 2>&1; eq "boot honours min_free_gb from config" "$?" 0
FLEET_FORCE= DF_GB=3 "$SCRIPTS/boot.sh" build disk5 "$T/plain" task >/dev/null 2>"$T/b.err"; check "boot refuses below the configured min_free_gb" grep -q 'min_free_gb=5' "$T/b.err"
FLEET_FORCE= DF_FAIL=1 "$SCRIPTS/boot.sh" build disk6 "$T/plain" task >/dev/null 2>"$T/b.err"; rc=$?
eq "boot with an unreadable df warns and boots" "$rc" 0
check "unreadable df is warned about" grep -q 'cannot read free disk' "$T/b.err"
cp "$T/config.bak" "$FLEET_CONFIG_DIR/config.toml"

# status shows free disk; watch notifies below warn_free_gb
eq "status: first line shows free disk" "$(DF_GB=100 "$SCRIPTS/status.sh" --team build-nope 2>/dev/null | head -1)" 'disk: 100 GiB free (warn below 75, boot refuses below 40)'
eq "status: LOW below warn_free_gb" "$(DF_GB=60 "$SCRIPTS/status.sh" --team build-nope 2>/dev/null | head -1 | grep -c ' LOW$')" 1
eq "status --json stays a bare array" "$(DF_GB=60 "$SCRIPTS/status.sh" --team build-nope --json 2>/dev/null | jq -r type)" array
: >"$HERDR_LOG"; DF_GB=60 "$SCRIPTS/watch.sh" --once >"$T/w.out" 2>/dev/null
eq "watch: one disk notification below warn_free_gb" "$(grep -c '^notification show fleet: disk 60 GiB free (warn_free_gb=75)' "$HERDR_LOG")" 1
check "watch prints free disk below warn_free_gb" grep -q 'disk 60 GiB free' "$T/w.out"
: >"$HERDR_LOG"; DF_GB=100 "$SCRIPTS/watch.sh" --once >"$T/w.out" 2>/dev/null
eq "watch prints no disk line above warn_free_gb" "$(grep -c "  disk [0-9]* GiB free" "$T/w.out")" 0
eq "watch: no disk notification above warn_free_gb" "$(grep -c 'fleet: disk' "$HERDR_LOG")" 0
: >"$HERDR_LOG"; DF_GB=30 "$SCRIPTS/watch.sh" --once >/dev/null 2>&1
eq "watch: below min_free_gb the notification says boot refuses" "$(grep -c 'fleet: disk 30 GiB free, boot refuses below min_free_gb=40' "$HERDR_LOG")" 1

# Machine identity (machine-id.sh): run with a PATH of symlinks plus per-case shims, so a
# missing ioreg/powershell/uuidgen is really missing.
mkcase() { # mkcase <name> → a case dir with the base tools only
  local d="$T/mid-$1" t; mkdir -p "$d/bin" "$d/cfg"
  for t in jq sed head tr cut cat date dirname mkdir od; do ln -s "$(command -v "$t")" "$d/bin/$t"; done
  printf '%s\n' "$d"
}
shim() { printf '#!/bin/sh\n%s\n' "$3" >"$1/bin/$2"; chmod +x "$1/bin/$2"; } # shim <dir> <name> <sh body>
mid() { # mid <casedir> args... (MID_FM replaces the key like FLEET_MACHINE)
  local d="$1"; shift
  env -u FLEET_MACHINE -u OS ${MID_FM:+"FLEET_MACHINE=$MID_FM"} ${MID_OS:+"OS=$MID_OS"} PATH="$d/bin" FLEET_STATE_DIR="$d/state" FLEET_CONFIG_DIR="$d/cfg" \
    FLEET_MACHINE_ID_FILE="$d/etc-id" FLEET_DBUS_ID_FILE="$d/dbus-id" FLEET_PROC_UUID_FILE="$d/proc-uuid" "$BASH" "$SCRIPTS/machine-id.sh" "$@"
}
jf() { printf '%s' "$1" | jq -r ".$2"; }

d="$(mkcase mac)"; shim "$d" uname 'echo Darwin'; shim "$d" hostname 'echo myhost'
shim "$d" ioreg 'echo "    | \"IOPlatformUUID\" = \"ABCDEF01-2345-6789-ABCD-EF0123456789\""'
j="$(mid "$d" show)"; rc=$?
eq "machine-id: macOS reads IOPlatformUUID" "$(jf "$j" id)|$(jf "$j" source)" "ABCDEF01-2345-6789-ABCD-EF0123456789|ioreg"
eq "machine-id: key is the first 8 hex, lowercased" "$(jf "$j" key)" abcdef01
eq "machine-id: label is prefix + key" "$(mid "$d" label)" fleet:abcdef01
eq "machine-id: exits 0" "$rc" 0
eq "machine-id: FLEET_MACHINE replaces the key" "$(MID_FM=zz mid "$d" key)" zz
echo 'label_prefix = "ops/"' >"$d/cfg/config.toml"
eq "machine-id: label_prefix from config" "$(mid "$d" label)" ops/abcdef01
eq "machine-id: FLEET_LABEL_PREFIX beats config" "$(FLEET_LABEL_PREFIX=x- mid "$d" label)" x-abcdef01
eq "machine-id: description names host, OS, full id and date" "$(mid "$d" description --date 2026-01-02)" \
  "myhost · macOS · machine id ABCDEF01-2345-6789-ABCD-EF0123456789 · first claim 2026-01-02"
eq "machine-id: description defaults the date to today" "$(mid "$d" description | grep -c 'first claim [0-9]\{4\}-[0-9][0-9]-[0-9][0-9]$')" 1
echo 'machine_name = "Mac 1"' >"$d/cfg/config.toml"
eq "machine-id: machine_name replaces the hostname in the description" "$(mid "$d" description --date 2026-01-02 | sed 's/ · machine id.*//')" "Mac 1 · macOS"
eq "machine-id: show carries machine_name" "$(jf "$(mid "$d" show)" name)" "Mac 1"
echo 'machine_legacy_label = "fleet:mac1"' >"$d/cfg/config.toml"
eq "machine-id: show carries machine_legacy_label" "$(jf "$(mid "$d" show)" legacy_label)" fleet:mac1

d="$(mkcase linux)"; shim "$d" uname 'echo Linux'
printf '0123456789ABCDEF0123456789abcdef\n' >"$d/etc-id"
j="$(mid "$d" show)"; eq "machine-id: Linux /etc/machine-id" "$(jf "$j" key)|$(jf "$j" source)|$(jf "$j" os)" "01234567|/etc/machine-id|Linux"
rm "$d/etc-id"; printf 'fedcba9876543210fedcba9876543210\n' >"$d/dbus-id"
j="$(mid "$d" show)"; eq "machine-id: Linux falls back to the dbus id" "$(jf "$j" key)|$(jf "$j" source)" "fedcba98|dbus"
printf '00000000000000000000000000000000\n' >"$d/etc-id"
eq "machine-id: a placeholder id falls through to the next source" "$(jf "$(mid "$d" show)" source)" dbus
printf 'abc\n' >"$d/etc-id"
eq "machine-id: a too-short id falls through" "$(jf "$(mid "$d" show)" source)" dbus
: >"$d/etc-id"
eq "machine-id: an empty id falls through" "$(jf "$(mid "$d" show)" source)" dbus
printf 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF\n' >"$d/etc-id"
eq "machine-id: an all-F id falls through" "$(jf "$(mid "$d" show)" source)" dbus

d="$(mkcase win)"; shim "$d" uname 'echo MINGW64_NT-10.0'
shim "$d" powershell 'printf "1B4E28BA-2FA1-11D2-883F-B9A761BDE3FB\r\n"'
shim "$d" wmic 'printf "UUID  \r\n2B4E28BA-2FA1-11D2-883F-B9A761BDE3FB  \r\n"'
j="$(mid "$d" show)"; eq "machine-id: Windows via powershell" "$(jf "$j" key)|$(jf "$j" source)|$(jf "$j" os)" "1b4e28ba|powershell|Windows"
rm "$d/bin/powershell"
j="$(mid "$d" show)"; eq "machine-id: Windows falls back to wmic" "$(jf "$j" key)|$(jf "$j" source)" "2b4e28ba|wmic"
d="$(mkcase winenv)"; shim "$d" uname 'echo SomethingElse'; shim "$d" powershell 'echo 3B4E28BA-2FA1-11D2-883F-B9A761BDE3FB'
eq "machine-id: OS=Windows_NT selects the Windows sources" "$(MID_OS=Windows_NT mid "$d" show | jq -r '.source + "|" + .os')" "powershell|Windows"

# random fallback: every generator, stored once and reused
d="$(mkcase rnd)"; shim "$d" uname 'echo FreeBSD'
shim "$d" uuidgen 'echo DEADBEEF-1111-4222-8333-444455556666'
j="$(mid "$d" show)"; eq "machine-id: random id from uuidgen" "$(jf "$j" key)|$(jf "$j" source)|$(jf "$j" os)" "deadbeef|random|unknown OS"
check "machine-id: the random id is stored" test -f "$d/state/machine-id"
rm "$d/bin/uuidgen"; j="$(mid "$d" show)"
eq "machine-id: the stored id is reused" "$(jf "$j" key)|$(jf "$j" source)" "deadbeef|stored"
d="$(mkcase rnd2)"; shim "$d" uname 'echo Linux'; echo 'cafef00d-1111-4222-8333-444455556666' >"$d/proc-uuid"
eq "machine-id: random id from /proc when there is no uuidgen" "$(jf "$(mid "$d" show)" key)" cafef00d
d="$(mkcase rnd3)"; shim "$d" uname 'echo Linux'
j="$(mid "$d" show)"
eq "machine-id: random id from od when nothing else exists" "$(jf "$j" id | grep -c '^[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}$')" 1
eq "machine-id: that id is stored and reused" "$(mid "$d" id)" "$(jf "$j" id)"
d="$(mkcase rnd4)"; shim "$d" uname 'echo Linux'; shim "$d" uuidgen 'echo 11111111-2222-4333-8444-555555555555'; touch "$d/state"
j="$(mid "$d" show 2>"$T/mid.err")"; rc=$?
check "machine-id: an unwritable state dir falls back to the config dir" test -f "$d/cfg/machine-id"
eq "machine-id: that fallback still exits 0" "$rc" 0
d="$(mkcase rnd5)"; shim "$d" uname 'echo Linux'; shim "$d" uuidgen 'echo 11111111-2222-4333-8444-555555555555'; touch "$d/state"; rm -rf "$d/cfg"; touch "$d/cfg"
j="$(mid "$d" show 2>"$T/mid.err")"; rc=$?
eq "machine-id: nowhere to store only warns" "$rc|$(grep -c 'cannot store a machine id' "$T/mid.err")|$(jf "$j" key)" "0|1|11111111"

# the description is never empty: hostname, COMPUTERNAME, unknown-host; each OS mapping
d="$(mkcase desc)"; shim "$d" uname 'echo Linux'; printf '0123456789abcdef0123456789abcdef\n' >"$d/etc-id"
eq "machine-id: no hostname uses COMPUTERNAME" "$(COMPUTERNAME=WIN1 mid "$d" description | cut -d' ' -f1)" WIN1
eq "machine-id: no hostname and no COMPUTERNAME is unknown-host" "$(mid "$d" description | cut -d' ' -f1)" unknown-host
eq "machine-id: Linux maps to Linux" "$(mid "$d" description | cut -d' ' -f3)" Linux
shim "$d" uname 'echo CYGWIN_NT'; eq "machine-id: CYGWIN maps to Windows" "$(jf "$(mid "$d" show)" os)" Windows
shim "$d" uname 'echo Plan9'; eq "machine-id: anything else maps to unknown OS" "$(jf "$(mid "$d" show)" os)" "unknown OS"

# status: the machine footer, the conditional ISSUE column
cp "$FLEET_CONFIG_DIR/config.toml" "$T/config.bak2"
eq "status: last line is the machine footer" "$(DF_GB=100 "$SCRIPTS/status.sh" --team build-nope 2>/dev/null | tail -1)" "machine: fleet:test"
echo 'machine_name = "Mac 1"' >>"$FLEET_CONFIG_DIR/config.toml"
eq "status: the footer shows machine_name" "$(DF_GB=100 "$SCRIPTS/status.sh" --team build-nope 2>/dev/null | tail -1)" "machine: fleet:test (Mac 1)"
eq "status: the disk line is still first" "$(DF_GB=100 "$SCRIPTS/status.sh" --team build-nope 2>/dev/null | head -1)" 'disk: 100 GiB free (warn below 75, boot refuses below 40)'
eq "status --json has no machine footer" "$(DF_GB=100 "$SCRIPTS/status.sh" --team build-nope --json 2>/dev/null | grep -c machine:)" 0
eq "status: no ISSUE column without an issue" "$(DF_GB=100 "$SCRIPTS/status.sh" --team build-plain 2>/dev/null | grep -c ISSUE)" 0
cp "$T/config.bak2" "$FLEET_CONFIG_DIR/config.toml"

# boot: refusal of an issue another machine holds
bt() { : >"$HERDR_LOG"; "$SCRIPTS/boot.sh" "$@" >"$T/bt.out" 2>"$T/bt.err"; BTRC=$?; }
rows_of() { "$REG" list --team "$1" | jq length; }
bt --issue DEV-1 --labels kind:ops,fleet:9b1d4e07 build ref1 "$T/plain" t
check "boot: another machine's label refuses" test "$BTRC" -ne 0
check "boot: the refusal names the issue, the holder and this machine" grep -q 'DEV-1 is claimed by fleet:9b1d4e07; this machine is fleet:test. Not booting' "$T/bt.err"
eq "boot: a refusal makes no herdr call" "$(wc -l <"$HERDR_LOG" | tr -d ' ')" 0
eq "boot: a refusal adds no rows" "$(rows_of build-ref1)" 0
bt --issue DEV-1 --claimed-by 9b1d4e07 build ref2 "$T/plain" t
check "boot: --claimed-by another machine refuses" grep -q 'DEV-1 is claimed by fleet:9b1d4e07' "$T/bt.err"
eq "boot: FLEET_FORCE=1 does not bypass the refusal" "$(FLEET_FORCE=1 "$SCRIPTS/boot.sh" --issue DEV-1 --claimed-by 9b1d4e07 build ref3 "$T/plain" t >/dev/null 2>&1; echo $?)" 1
bt --issue DEV-2 --claimed-by test --labels fleet:test,kind:ops build own1 "$T/plain" t
eq "boot: this machine's own label boots" "$BTRC" 0
eq "boot: the row records issue, claimed_by and machine" "$("$REG" get build-own1/builder | jq -r '[.issue, .claimed_by, .machine] | join(",")')" "DEV-2,test,test"
bt --issue DEV-2 --claimed-by fleet:test build own2 "$T/plain" t; eq "boot: --claimed-by accepts the full label" "$BTRC" 0
echo 'machine_legacy_label = "fleet:mac1"' >>"$FLEET_CONFIG_DIR/config.toml"
bt --issue DEV-3 --labels fleet:mac1 build leg1 "$T/plain" t; eq "boot: this machine's legacy label boots" "$BTRC" 0
bt --issue DEV-3 --claimed-by fleet:mac1 build leg2 "$T/plain" t; eq "boot: --claimed-by the legacy label boots" "$BTRC" 0
bt --issue DEV-3 --labels fleet:mac2 build leg3 "$T/plain" t
check "boot: another machine's legacy label refuses" grep -q 'DEV-3 is claimed by fleet:mac2' "$T/bt.err"
cp "$T/config.bak2" "$FLEET_CONFIG_DIR/config.toml"
FLEET_LABEL_PREFIX='ops/' bt --issue DEV-4 --labels ops/9b1d4e07 build pre1 "$T/plain" t
check "boot: a custom label_prefix is honoured" grep -q 'DEV-4 is claimed by ops/9b1d4e07; this machine is ops/test' "$T/bt.err"
FLEET_LABEL_PREFIX='ops/' bt --issue DEV-4 --labels fleet:9b1d4e07 build pre2 "$T/plain" t
eq "boot: labels outside the custom prefix are not claims" "$BTRC" 0
bt build plainboot "$T/plain" t; eq "boot: no --issue boots as before" "$BTRC" 0
eq "boot: an unknown option is refused" "$("$SCRIPTS/boot.sh" --nope build x "$T/plain" t >/dev/null 2>&1; echo $?)" 1

# boot: declared scope and the overlap warning
bt --issue DEV-10 --claimed-by test --scope 'platform: deploy/local, scripts/local.sh' build ova "$T/plain" t
eq "boot: a scoped claim boots" "$BTRC" 0
eq "boot: the row records the scope" "$("$REG" get build-ova/builder | jq -c .scope)" '{"repo":"platform","paths":["deploy/local","scripts/local.sh"]}'
bt --issue DEV-11 --claimed-by test --scope 'platform: deploy/local/x' build ovb "$T/plain" t
eq "boot: an overlap exits 0" "$BTRC" 0
check "boot: the overlap warning names both teams" grep -q 'warning: build-ovb (fleet:test) overlaps build-ova (fleet:test) in platform: deploy/local/x' "$T/bt.err"
bt --scope 'PLATFORM: scripts' build ovc "$T/plain" t
check "boot: repo names compare case-insensitively" grep -q 'build-ovc .* overlaps build-ova' "$T/bt.err"
bt --scope 'platform: docs' build ove "$T/plain" t; eq "boot: disjoint paths give no warning" "$(grep -c overlaps "$T/bt.err")" 0
bt --scope 'platform: deploy/localstack' build ovf "$T/plain" t; eq "boot: deploy/local vs deploy/localstack give no warning" "$(grep -c overlaps "$T/bt.err")" 0
bt --scope 'other: deploy/local' build ovg "$T/plain" t; eq "boot: another repo gives no warning" "$(grep -c overlaps "$T/bt.err")" 0
bt --scope 'platform' build ovd "$T/plain" t
check "boot: no paths means the whole repo" grep -q 'build-ovd .* overlaps build-ova .* in platform: whole repo' "$T/bt.err"
bt --scope 'zeta: deploy/local' --peer-claim '9b1d4e07/build-dev315=zeta:deploy/local,scripts/x' build ovh "$T/plain" t
check "boot: a peer claim overlap names the other machine" grep -q 'build-ovh (fleet:test) overlaps build-dev315 (fleet:9b1d4e07) in zeta: deploy/local' "$T/bt.err"
bt --scope 'zeta: docs' --peer-claim '9b1d4e07/build-dev315=zeta:deploy/local' build ovi "$T/plain" t
eq "boot: a disjoint peer claim gives no warning" "$(grep -c overlaps "$T/bt.err")" 0
bt build ovj "$T/plain" t; eq "boot: no --scope never warns" "$(grep -c overlaps "$T/bt.err")" 0
bt --scope ': src' build ovk "$T/plain" t
eq "boot: the scope repo defaults to the repo-dir name" "$("$REG" get build-ovk/builder | jq -r .scope.repo)" plain
bt --issue DEV-12 build iss1 "$T/plain" t
eq "status: the ISSUE column appears once a row has an issue" "$(DF_GB=100 "$SCRIPTS/status.sh" --team build-iss1 2>/dev/null | sed -n 2p | grep -c ISSUE)" 1

# claim.sh: the claim comment, parse, renew, lease, expired
CL="$SCRIPTS/claim.sh"
eq "claim line: exact output" "$("$CL" line --machine 3f9a2c1e --team build-d --at 2026-10-18T09:00:00Z --scope 'platform: deploy/local, scripts/local.sh')" \
  "$(printf 'fleet-claim: machine=3f9a2c1e team=build-d at=2026-10-18T09:00:00Z lease=2026-10-18T11:00:00Z\nscope: platform: deploy/local, scripts/local.sh')"
eq "claim line: name and lease-hours" "$("$CL" line --machine 3f9a2c1e --name 'Mac 1' --team build-d --at 2026-10-18T09:00:00Z --lease-hours 3 --scope platform | head -1)" \
  'fleet-claim: machine=3f9a2c1e name="Mac 1" team=build-d at=2026-10-18T09:00:00Z lease=2026-10-18T12:00:00Z'
eq "claim line: takeover names the voided comment" "$("$CL" line --machine 3f9a2c1e --team build-d --at 2026-10-18T09:00:00Z --scope platform --takeover-from 9b1d4e07 --takeover-team build-o --takeover-of-comment cmt-1 --previous-lease 2026-10-18T08:00:00Z | tail -1)" \
  'takeover: from=9b1d4e07 team=build-o comment=cmt-1 at=2026-10-18T09:00:00Z previous-lease=2026-10-18T08:00:00Z reason=expired'
eq "claim line: a takeover without the comment id dies" "$("$CL" line --machine a --team t --scope p --takeover-from b >/dev/null 2>&1; echo $?)" 1
BODY1="$("$CL" line --machine 3f9a2c1e --name 'Mac 1' --team build-d --at 2026-10-18T09:00:00Z --scope 'platform: a/b, c')"
BODY2="$("$CL" line --machine 9b1d4e07 --team build-o --at 2026-10-18T07:00:00Z --scope zeta --takeover-from 11111111 --takeover-team build-p --takeover-of-comment c0 --previous-lease 2026-10-18T06:00:00Z)"
P="$(jq -cn --arg a "$BODY1" --arg b "$BODY2" '[{id:"c1",issue:"DEV-9",createdAt:"2026-10-18T09:00:01Z",updatedAt:"2026-10-18T09:00:01Z",body:$a},{id:"c2",body:"just a comment"},{id:"c3",body:$b}]' | "$CL" parse)"
eq "claim parse: skips comments that are not claims" "$(printf '%s' "$P" | jq length)" 2
eq "claim parse: fields" "$(printf '%s' "$P" | jq -r '.[0] | [.id, .issue, .machine, .name, .team, .at, .lease, .scope.repo, (.scope.paths | join("|")), .created_at] | join(",")')" \
  "c1,DEV-9,3f9a2c1e,Mac 1,build-d,2026-10-18T09:00:00Z,2026-10-18T11:00:00Z,platform,a/b|c,2026-10-18T09:00:01Z"
eq "claim parse: takeover_of_comment" "$(printf '%s' "$P" | jq -r '.[1] | [.takeover_from, .takeover_of_comment, .takeover_previous_lease, .scope.repo, (.scope.paths | length)] | join(",")')" "11111111,c0,2026-10-18T06:00:00Z,zeta,0"
eq "claim parse: no takeover is null" "$(printf '%s' "$P" | jq -r '.[0].takeover_of_comment')" null
R="$("$CL" renew --now 2026-10-18T10:30:00Z "$BODY2")"
eq "claim renew: only lease= changes" "$(diff <(printf '%s\n' "$BODY2") <(printf '%s\n' "$R") | grep -c '^[<>]')" 2
eq "claim renew: new lease is now + lease_hours" "$(printf '%s' "$R" | head -1 | sed 's/.*lease=//')" 2026-10-18T12:30:00Z
eq "claim renew: keeps the takeover line" "$(printf '%s' "$R" | grep -c '^takeover:')" 1
eq "claim renew: a non-claim body dies" "$("$CL" renew --now 2026-10-18T10:30:00Z 'hello' >/dev/null 2>&1; echo $?)" 1
eq "claim lease: now + 2h by default" "$("$CL" lease --now 2026-10-18T10:00:00Z)" 2026-10-18T12:00:00Z
L=2026-10-18T11:00:00Z
"$CL" expired --lease $L --now 2026-10-18T10:59:59Z 2>"$T/ex.err"; eq "claim expired: a live lease is not takeable" "$?" 1
check "claim expired: the reason names the lease" grep -q 'lease is live until 2026-10-18T11:00:00Z' "$T/ex.err"
"$CL" expired --lease $L --now 2026-10-18T11:00:00Z 2>/dev/null; eq "claim expired: the expiry second itself is still live" "$?" 1
"$CL" expired --lease $L --now 2026-10-18T11:00:01Z; eq "claim expired: lapsed, no activity given" "$?" 0
"$CL" expired --lease $L --now 2026-10-18T13:30:00Z --last-activity 2026-10-18T12:00:00Z 2>"$T/ex.err"; eq "claim expired: lapsed but recent PR activity" "$?" 1
check "claim expired: the reason names the activity" grep -q 'PR activity at 2026-10-18T12:00:00Z' "$T/ex.err"
"$CL" expired --lease $L --now 2026-10-18T13:30:00Z --last-activity 2026-10-18T10:00:00Z; eq "claim expired: lapsed with old activity" "$?" 0
echo 'lease_hours = 4' >>"$FLEET_CONFIG_DIR/config.toml"
"$CL" expired --lease $L --now 2026-10-18T13:30:00Z --last-activity 2026-10-18T10:00:00Z 2>/dev/null; eq "claim expired: lease_hours from config widens the activity window" "$?" 1
eq "claim lease: lease_hours from config" "$("$CL" lease --now 2026-10-18T10:00:00Z)" 2026-10-18T14:00:00Z
cp "$T/config.bak2" "$FLEET_CONFIG_DIR/config.toml"
eq "claim expired: a bad time dies" "$("$CL" expired --lease nope >/dev/null 2>&1; echo $?)" 1

# boot: takeover of a lapsed claim
OLD=2026-10-18T08:00:00Z
bt --issue DEV-20 --claimed-by test --takeover-of 9b1d4e07 --labels fleet:9b1d4e07 build tk1 "$T/plain" t
check "boot takeover: a missing lease refuses" grep -q 'DEV-20 is claimed by fleet:9b1d4e07; no --lease-expires given. Not taking over' "$T/bt.err"
FLEET_NOW=2026-10-18T07:00:00Z bt --issue DEV-20 --claimed-by test --takeover-of 9b1d4e07 --lease-expires $OLD --labels fleet:9b1d4e07 build tk2 "$T/plain" t
check "boot takeover: a live lease refuses and names it" grep -q 'lease is live until 2026-10-18T08:00:00Z.*Not taking over' "$T/bt.err"
eq "boot takeover: a refusal adds no rows" "$(rows_of build-tk2)" 0
FLEET_FORCE=1 FLEET_NOW=2026-10-18T07:00:00Z bt --issue DEV-20 --claimed-by test --takeover-of 9b1d4e07 --lease-expires $OLD --labels fleet:9b1d4e07 build tk3 "$T/plain" t
eq "boot takeover: FLEET_FORCE=1 does not bypass a live lease" "$BTRC" 1
FLEET_NOW=2026-10-18T11:00:00Z bt --issue DEV-20 --claimed-by test --takeover-of 9b1d4e07 --lease-expires $OLD --last-activity 2026-10-18T10:30:00Z --labels fleet:9b1d4e07 build tk4 "$T/plain" t
check "boot takeover: recent PR activity refuses" grep -q 'PR activity at 2026-10-18T10:30:00Z.*Not taking over' "$T/bt.err"
FLEET_NOW=2026-10-18T11:00:00Z bt --issue DEV-20 --claimed-by test --takeover-of 9b1d4e07 --lease-expires $OLD --last-activity 2026-10-18T08:30:00Z --labels fleet:9b1d4e07,kind:ops build tk5 "$T/plain" t
eq "boot takeover: an expired lease boots" "$BTRC" 0
eq "boot takeover: the row records takeover_of and the new lease" "$("$REG" get build-tk5/builder | jq -r '[.issue, .claimed_by, .takeover_of, .lease_expires] | join(",")')" "DEV-20,test,9b1d4e07,2026-10-18T13:00:00Z"
FLEET_NOW=2026-10-18T11:00:00Z bt --issue DEV-20 --claimed-by test --takeover-of 9b1d4e07 --lease-expires $OLD --labels fleet:5555aaaa build tk6 "$T/plain" t
check "boot takeover: a label of a third machine refuses" grep -q 'DEV-20 is claimed by fleet:5555aaaa' "$T/bt.err"
FLEET_NOW=2026-10-18T11:00:00Z bt --issue DEV-20 --claimed-by 9b1d4e07 --takeover-of 5555aaaa --lease-expires $OLD build tk7 "$T/plain" t
check "boot takeover: --claimed-by must be this machine" grep -q 'DEV-20 is claimed by fleet:9b1d4e07; this machine is fleet:test' "$T/bt.err"
FLEET_NOW=2026-10-18T11:00:00Z bt --issue DEV-20 --claimed-by test --takeover-of test --lease-expires $OLD build tk8 "$T/plain" t
check "boot takeover: taking over from this machine refuses" grep -q 'names this machine' "$T/bt.err"
FLEET_FORCE=1 bt --issue DEV-20 --labels fleet:9b1d4e07 --claimed-by test build tk9 "$T/plain" t
eq "boot takeover: FLEET_FORCE=1 does not bypass a foreign label without --takeover-of" "$BTRC" 1
bt --lease-expires $OLD build tk10 "$T/plain" t; eq "boot takeover: --lease-expires without --takeover-of refuses" "$BTRC" 1
FLEET_LABEL_PREFIX='ops/' FLEET_NOW=2026-10-18T11:00:00Z bt --issue DEV-21 --claimed-by test --takeover-of 9b1d4e07 --lease-expires $OLD --labels ops/9b1d4e07 build tk11 "$T/plain" t
eq "boot takeover: a custom label_prefix works" "$BTRC" 0
echo 'machine_legacy_label = "fleet:mac1"' >>"$FLEET_CONFIG_DIR/config.toml"
FLEET_NOW=2026-10-18T11:00:00Z bt --issue DEV-22 --claimed-by test --takeover-of fleet:mac1 --lease-expires $OLD --labels fleet:test build tk12 "$T/plain" t
check "boot takeover: the legacy label is this machine, nothing to take over" grep -q 'names this machine' "$T/bt.err"
cp "$T/config.bak2" "$FLEET_CONFIG_DIR/config.toml"
eq "boot: a new claim's row carries lease_expires" "$("$REG" get build-own1/builder | jq -r '.lease_expires | type')" string

# status --all
CF="$T/claims.json"
jq -cn --arg a "$BODY1" --arg b "$("$CL" line --machine test --team build-ghost --at 2026-10-18T09:00:00Z --scope zeta)" --arg c "$("$CL" line --machine test --team build-own1 --at 2026-10-18T09:00:00Z --scope zeta)" \
  '[{id:"c1",issue:"DEV-9",body:$a},{id:"c4",body:$b},{id:"c5",body:$c}]' | "$CL" parse >"$CF"
FLEET_NOW=2026-10-18T10:00:00Z DF_GB=100 "$SCRIPTS/status.sh" --all --claims "$CF" --team build-own1 >"$T/all.out" 2>"$T/all.err"
check "status --all: MACHINE and LEASE columns" grep -q 'MACHINE *LEASE' "$T/all.out"
check "status --all: a tracker row shows the machine with its name and the lease" grep -Eq 'build-d .*Claimed .*DEV-9 .*3f9a2c1e \(Mac 1\) .*2026-10-18T11:00:00Z' "$T/all.out"
check "status --all: the local team is a registry row on this machine" grep -Eq '^build-own1/builder .*test' "$T/all.out"
check "status --all: a claim of this key with no local team is flagged" grep -Eq 'build-ghost .*SAME KEY\?' "$T/all.out"
check "status --all: the warning names the team and machine-id.sh" grep -q 'claim for build-ghost carries this machine.s key (test) but no local team: cloned machine id? (see machine-id.sh)' "$T/all.err"
eq "status --all: this machine's own claim for a local team is not duplicated" "$(grep -c 'c5\|build-own1 ' "$T/all.out")" 0
FLEET_NOW=2026-10-18T12:00:00Z DF_GB=100 "$SCRIPTS/status.sh" --all --claims "$CF" >"$T/all2.out" 2>/dev/null; check "status --all: a lapsed lease is shown" grep -q 'Claimed (lease lapsed)' "$T/all2.out"
eq "status --all: the footer stays last" "$(DF_GB=100 "$SCRIPTS/status.sh" --all --claims "$CF" --team build-nope 2>/dev/null | tail -1)" "machine: fleet:test"
DF_GB=100 "$SCRIPTS/status.sh" --all --team build-own1 >"$T/all3.out" 2>/dev/null; check "status --all without claims says so" grep -q '^peer claims: not provided' "$T/all3.out"
eq "status --all --json: bare array with machine and source" "$(DF_GB=100 "$SCRIPTS/status.sh" --all --json --claims "$CF" --team build-own1 2>/dev/null | jq -c '[.[] | [.source, .machine]] | unique')" '[["registry","test"],["tracker","3f9a2c1e"],["tracker","test"]]'
cat "$CF" | DF_GB=100 "$SCRIPTS/status.sh" --all --json --claims - --team build-own1 2>/dev/null | jq -e 'type == "array"' >/dev/null; eq "status --all: --claims - reads stdin" "$?" 0
eq "status --claims without --all dies" "$("$SCRIPTS/status.sh" --claims "$CF" >/dev/null 2>&1; echo $?)" 1
eq "status --all: an unreadable claims file dies" "$(DF_GB=100 "$SCRIPTS/status.sh" --all --claims "$T/none.json" >/dev/null 2>&1; echo $?)" 1
echo '{}' >"$T/bad.json"; eq "status --all: claims that are not an array die" "$(DF_GB=100 "$SCRIPTS/status.sh" --all --claims "$T/bad.json" >/dev/null 2>&1; echo $?)" 1
eq "status without --all has no MACHINE column" "$(DF_GB=100 "$SCRIPTS/status.sh" --team build-own1 2>/dev/null | grep -c MACHINE)" 0

# chat.sh: settings and format only, never the network
CH="$SCRIPTS/chat.sh"
eq "chat channel: empty when unset" "$("$CH" channel)" ""
eq "chat allow: [] when unset" "$("$CH" allow)" "[]"
printf 'chat_channel = "#fleet"\nchat_allow = ["chat__send", "chat__read"]\n' >>"$FLEET_CONFIG_DIR/config.toml"
eq "chat channel: from config" "$("$CH" channel)" "#fleet"
eq "chat allow: the list from config" "$("$CH" allow)" '["chat__send","chat__read"]'
eq "chat format: one stable line" "$("$CH" format claim DEV-317 build-d lease=2026-10-18T11:00:00Z)" "fleet[test] claim DEV-317 build-d lease=2026-10-18T11:00:00Z"
eq "chat format: every event" "$(for e in claim pr merge escalation takeover rebase; do "$CH" format $e x; done | wc -l | tr -d ' ')" 6
eq "chat format: an unknown event dies" "$("$CH" format nope >/dev/null 2>&1; echo $?)" 1
cp "$T/config.bak2" "$FLEET_CONFIG_DIR/config.toml"
cat >"$T/bin/curl" <<'S'
#!/usr/bin/env bash
echo "curl $*" >>"$NETLOG"; exit 1
S
chmod +x "$T/bin/curl"; export NETLOG="$T/net.log"; : >"$NETLOG"
"$CH" format claim DEV-1 >/dev/null; "$CH" channel >/dev/null; "$CL" lease >/dev/null
eq "chat.sh and claim.sh never touch the network" "$(wc -l <"$NETLOG" | tr -d ' ')" 0
check "no script calls a chat or tracker tool" test -z "$(grep -lE 'slack|curl|linear|gh ' "$CH" "$CL")"
eq "boot adds no chat_allow to agent settings" "$(grep -c chat_allow "$SCRIPTS/boot.sh")" 0

# docs
SKD="$SCRIPTS/.."
for k in label_prefix machine_name machine_legacy_label claimed-by; do
  check "SKILL.md mentions $k" grep -q -- "$k" "$SKD/SKILL.md"
done
for k in label_prefix machine_name machine_legacy_label; do check "fleet README mentions $k" grep -q "$k" "$SKD/README.md"; done
for k in lease_hours chat_channel chat_allow 'status --all' --takeover-of claim.sh chat.sh; do check "SKILL.md documents $k" grep -q -- "$k" "$SKD/SKILL.md"; done
check "SKILL.md no longer lists the follow-ups as not yet done" test -z "$(grep 'Not yet' "$SKD/SKILL.md")"
for k in lease_hours chat_channel chat_allow claim.sh chat.sh 'status --all'; do check "README documents $k" grep -q -- "$k" "$SKD/README.md"; done
check "README tracker_allow example omits save_issue_label" test -z "$(grep -E 'tracker_allow.*save_issue_label' "$SKD/README.md")"
check "README documents the cloned machine id risk" grep -qi 'cloned' "$SKD/README.md"
check "machine-id.sh documents the cloned machine id risk" grep -qi 'cloned' "$SCRIPTS/machine-id.sh"
check "registry.md documents the cloned machine id risk" grep -qi 'cloned' "$SKD/references/registry.md"
check "SKILL.md says the tracker has no compare-and-swap" grep -q 'compare-and-swap' "$SKD/SKILL.md"
check "SKILL.md: the heartbeat does not renew a voided claim" grep -qi 'must not renew' "$SKD/SKILL.md"
check "registry.md documents the claim fields" grep -q 'claimed_by' "$SKD/references/registry.md"

# Escalations reach the Orchestrator (DEV-364): inbox, resolve, open until resolved, notify failures, wait
INBOX="$FLEET_STATE_DIR/escalations.jsonl"; EW="$SCRIPTS/escalation-wait.sh"
rm -f "$INBOX" "$FLEET_STATE_DIR/escalations.cursor"
"$REG" add '{"name":"esc/builder","team":"esc","tier":"Worker","status":"Working"}'
"$REG" escalate esc/builder P1 "which db?" >/dev/null 2>&1
sleep 1  # (name, at) has one-second resolution
eq "escalate appends one inbox line" "$(wc -l <"$INBOX" | tr -d ' ')" 1
eq "inbox line has the six fields" "$(jq -c 'keys' "$INBOX")" '["at","id","message","name","severity","team"]'
eq "inbox line carries the team and message" "$(jq -r '[.team, .name, .severity, .message] | join("|")' "$INBOX")" "esc|esc/builder|P1|which db?"
"$REG" escalate esc/builder P2 "naming?" >/dev/null 2>&1
eq "two escalates make two inbox lines" "$(wc -l <"$INBOX" | tr -d ' ')" 2
eq "an unwritable inbox warns and still exits 0" "$(FLEET_INBOX=/nonexistent/dir/in.jsonl "$REG" escalate esc/builder P2 "x" 2>&1 >/dev/null | grep -c 'cannot write the escalation inbox')" 1
FLEET_INBOX=/nonexistent/dir/in.jsonl "$REG" escalate esc/builder P2 "x" >/dev/null 2>&1; eq "unwritable inbox exits 0" "$?" 0
AT_P1="$("$REG" escalations --team esc | jq -r '[.[] | select(.severity == "P1")][0].at')"
eq ".escalation is the highest open severity" "$("$REG" get esc/builder | jq -r .escalation)" P1
"$REG" resolve esc/builder "$AT_P1" --note "use pg" >/dev/null 2>&1
eq "resolve records resolved_at and the note" "$("$REG" escalations --team esc | jq -r '[.[] | select(.at == "'"$AT_P1"'" and .severity == "P1")][0] | (.resolved_at != null) and .resolution == "use pg"')" true
eq "resolve recomputes .escalation from what is still open" "$("$REG" get esc/builder | jq -r .escalation)" P2
eq "escalations --open excludes the resolved entry" "$("$REG" escalations --open --team esc | jq '[.[] | select(.severity == "P1")] | length')" 0
check "resolve rejects an unknown agent" bash -c "! '$REG' resolve nobody/x 2020-01-01T00:00:00Z"
check "resolve rejects an unknown at" bash -c "! '$REG' resolve esc/builder 2020-01-01T00:00:00Z"
"$REG" resolve esc/builder "$AT_P1" >/dev/null 2>&1; eq "resolving twice is idempotent" "$?" 0
"$REG" add '{"name":"esc/solo","team":"esc2","tier":"Worker","status":"Working"}'
"$REG" escalate esc/solo P1 "only one" >/dev/null 2>&1
"$REG" resolve esc/solo "$("$REG" escalations --team esc2 | jq -r '.[0].at')" >/dev/null 2>&1
eq "resolving the last one clears .escalation" "$("$REG" get esc/solo | jq -r .escalation)" ""
eq "resolving the last one moves status off Needs input" "$("$REG" get esc/solo | jq -r .status)" Working
# open until resolved: done, set and add keep it
"$REG" escalate esc/builder P1 "still open" >/dev/null 2>&1
"$REG" done esc/builder --outcome Shipped --summary "PR ready" >/dev/null 2>&1
eq "a Done agent's escalation is still open" "$("$REG" escalations --open --team esc | jq '[.[] | select(.name == "esc/builder" and .severity == "P1")] | length')" 1
eq "list --problems includes a Done row with an open escalation" "$("$REG" list --problems | jq '[.[] | select(.name == "esc/builder")] | length')" 1
eq "retire --summary shows it open" "$("$SCRIPTS/retire.sh" --summary esc 2>/dev/null | jq '[.escalations[] | select(.message == "still open" and .open)] | length')" 1
eq "retire --summary shows a resolved one closed" "$("$SCRIPTS/retire.sh" --summary esc 2>/dev/null | jq '[.escalations[] | select(.message == "which db?" and (.open | not))] | length')" 1
"$REG" set esc/builder status=Idle >/dev/null 2>&1
eq "set status keeps the open escalation" "$("$REG" escalations --open --team esc | jq '[.[] | select(.name == "esc/builder")] | length')" 4
check "set escalation= is refused" bash -c "! '$REG' set esc/builder escalation="
check "set escalations= is refused" bash -c "! '$REG' set esc/builder escalations=[]"
"$REG" add '{"name":"esc/builder","team":"esc","note":"re-add"}'
eq "add on an existing row keeps its escalations" "$("$REG" get esc/builder | jq '.escalations | length')" 5
eq "status.sh lists open escalations after the table" "$("$SCRIPTS/status.sh" 2>/dev/null | grep -c 'still open')" 1
# notify: a failing herdr call is logged, not hidden, and does not fail the command
err="$(NOTIFY_FAIL=1 "$REG" escalate esc/builder P2 "n1" 2>&1 >/dev/null)"; rc=$?
eq "escalate exits 0 when the notification fails" "$rc" 0
check "escalate logs 'notification failed'" grep -q 'notification failed' <<<"$err"
err="$(NOTIFY_FAIL=1 "$REG" done esc/solo --outcome Shipped --summary s 2>&1 >/dev/null)"
check "done logs 'notification failed'" grep -q 'notification failed' <<<"$err"
eq "a working notification logs nothing" "$("$REG" escalate esc/builder P2 "n2" 2>&1 >/dev/null)" ""
eq "watch.sh --once logs a failing notification" "$(NOTIFY_FAIL=1 "$SCRIPTS/watch.sh" --once 2>&1 >/dev/null | grep -c 'notification failed' | awk '{print ($1 > 0)}')" 1
# escalation-wait.sh
rm -f "$FLEET_STATE_DIR/escalations.cursor"
out="$("$EW" --timeout 2 --every 1)"; eq "wait: nothing new exits 0 with no output" "$out:$?" ":0"
"$EW" --timeout 30 --every 1 >"$T/ew.out" & ewpid=$!
sleep 1; "$REG" escalate esc/builder P1 "wake up" >/dev/null 2>&1
for _ in $(seq 1 20); do kill -0 "$ewpid" 2>/dev/null || break; sleep 0.5; done
if kill -0 "$ewpid" 2>/dev/null; then kill "$ewpid"; bad "wait: exits when an escalation arrives"; else wait "$ewpid"; ok "wait: exits when an escalation arrives"; fi
eq "wait: prints the new line" "$(jq -r .message "$T/ew.out")" "wake up"
eq "wait: a second run does not replay it" "$("$EW" --timeout 1 --every 1)" ""
"$REG" escalate esc/builder P2 "between arms" >/dev/null 2>&1
eq "wait: one filed between arms is delivered by the next" "$("$EW" --timeout 5 --every 1 | jq -r .message)" "between arms"
eq "wait: --from-start replays the inbox" "$("$EW" --from-start --timeout 1 --every 1 | wc -l | tr -d ' ')" "$(wc -l <"$INBOX" | tr -d ' ')"
check "wait: rejects an unknown option" bash -c "! '$EW' --bogus"
for f in registry.sh status.sh watch.sh retire.sh escalation-wait.sh common.sh boot.sh; do check "bash -n $f" bash -n "$SCRIPTS/$f"; done
SKD0="$SCRIPTS/.."
check "SKILL.md mentions escalation-wait.sh" grep -q 'escalation-wait.sh' "$SKD0/SKILL.md"
check "SKILL.md documents resolve" grep -q 'registry.sh resolve' "$SKD0/SKILL.md"
check "SKILL.md has the Orchestrator send a push" grep -q 'PushNotification' "$SKD0/SKILL.md"
check "build lead brief says P1 is only for a user decision" grep -q 'P1 is only for a decision the user must make' "$SKD0/templates/build.json"
check "build lead brief no longer files an escalation for UNVERIFIED" test -z "$(grep 'UNVERIFIED with an escalation filed' "$SKD0/templates/build.json")"
check "lead agent says P1 is only for a user decision" grep -q 'P1 is only for a decision the' "$SKD0/../../agents/lead.md"
check "agent fleet rules say P1 is only for a user decision" grep -q 'P1 is only for a decision the user must make' "$SCRIPTS/boot.sh"
check "registry.md documents the inbox and resolved_at" grep -q 'resolved_at' "$SKD0/references/registry.md"

# Retire closes escalations, resolve by id, defensive reads (DEV-367)
rm -f "$INBOX"
"$REG" add '{"name":"esc3/builder","team":"esc3","tier":"Worker","status":"Working"}'
"$REG" escalate esc3/builder P1 "first" >/dev/null 2>&1
"$REG" escalate esc3/builder P2 "second" >/dev/null 2>&1
ID1="$("$REG" escalations --team esc3 | jq -r '[.[] | select(.message == "first")][0].id')"
ID2="$("$REG" escalations --team esc3 | jq -r '[.[] | select(.message == "second")][0].id')"
eq "escalate stores an id <at compact>-<seq>" "$("$REG" get esc3/builder | jq -r '.escalations[0] | .id == ((.at | gsub("[-:]"; "")) + "-1")')" true
eq "the inbox line carries the stored id" "$(jq -r 'select(.message == "second") | .id' "$INBOX")" "$ID2"
check "two escalations get different ids" test "$ID1" != "$ID2"
saved="$(cat "$FLEET_REGISTRY")"
jq '.agents["esc3/builder"].escalations |= map(.at = "2026-10-19T10:00:00Z")' <<<"$saved" >"$FLEET_REGISTRY"
"$REG" resolve esc3/builder "$ID2" --note "p2 only" >/dev/null 2>&1
eq "same-second twins: resolving the second id closes only the second" "$("$REG" escalations --team esc3 | jq -c 'map(select(.resolved_at != null) | .message)')" '["second"]'
eq "same-second twins: .escalation stays P1" "$("$REG" get esc3/builder | jq -r .escalation)" P1
"$REG" resolve esc3/builder "$ID1" >/dev/null 2>&1
eq "then the first id closes the first" "$("$REG" escalations --open --team esc3 | jq length)" 0
check "resolve rejects an unknown id" bash -c "! '$REG' resolve esc3/builder nope-9"
# legacy entries: no id stored, junk element in the array; ids derive from the raw position
jq '.agents["esc3/builder"].escalations = [7, {severity: "P1", message: "old1", at: "2026-10-19T10:00:00Z"}, {severity: "P2", message: "old2", at: "2026-10-19T10:00:00Z"}]' <<<"$saved" >"$FLEET_REGISTRY"
eq "legacy ids use the raw array position" "$("$REG" escalations --team esc3 | jq -c 'map(.id)')" '["20261019T100000Z-2","20261019T100000Z-3"]'
"$REG" resolve esc3/builder 20261019T100000Z-3 >/dev/null 2>&1
eq "a legacy entry resolves by its derived id" "$("$REG" escalations --open --team esc3 | jq -c 'map(.message)')" '["old1"]'
"$REG" resolve esc3/builder 2026-10-19T10:00:00Z >/dev/null 2>&1
eq "a legacy entry still resolves by at" "$("$REG" escalations --open --team esc3 | jq length)" 0
eq "a junk element is left as it was" "$("$REG" get esc3/builder | jq -c '.escalations[0]')" 7
# retire closes what is open
printf '%s' "$saved" >"$FLEET_REGISTRY"
"$REG" add '{"name":"esc3/tester","team":"esc3","tier":"Worker","status":"Working"}'
"$REG" escalate esc3/tester P1 "t1" >/dev/null 2>&1
"$REG" escalate esc3/tester P2 "t2" >/dev/null 2>&1
"$REG" resolve esc3/tester "$("$REG" escalations --team esc3 | jq -r '[.[] | select(.message == "t2")][0].id')" --note "mine" >/dev/null 2>&1
eq "retire --summary lists the open one before the go" "$("$SCRIPTS/retire.sh" --summary esc3 2>/dev/null | jq '[.escalations[] | select(.open)] | length')" 3
"$SCRIPTS/retire.sh" esc3 >"$T/r3.json" 2>/dev/null
eq "retire leaves nothing open on the team" "$("$REG" escalations --open --team esc3 | jq length)" 0
eq "retire records 'closed at retire'" "$("$REG" escalations --team esc3 | jq -c 'map(select(.resolution == "closed at retire") | .message) | sort')" '["first","second","t1"]'
eq "retire keeps an earlier resolution note" "$("$REG" escalations --team esc3 | jq -r '[.[] | select(.message == "t2")][0].resolution')" mine
eq "retire clears .escalation" "$("$REG" get esc3/builder | jq -r .escalation)" ""
eq "retire output lists closed_escalations" "$(jq -r '.closed_escalations | map(.name) | sort | join(",")' "$T/r3.json")" "esc3/builder,esc3/builder,esc3/tester"
eq "retire --summary afterwards shows them closed" "$("$SCRIPTS/retire.sh" --summary esc3 2>/dev/null | jq '[.escalations[] | select(.open)] | length')" 0
# status ignores Retired agents' escalations, not Done agents'
"$REG" add '{"name":"esc4/a","team":"esc4","tier":"Worker","status":"Working"}'
"$REG" escalate esc4/a P2 "retired-open" >/dev/null 2>&1
jq '.agents["esc4/a"].status = "Retired"' "$FLEET_REGISTRY" >"$T/r.json" && mv "$T/r.json" "$FLEET_REGISTRY"
eq "status.sh hides a Retired agent's open escalation" "$("$SCRIPTS/status.sh" 2>/dev/null | grep -c 'retired-open')" 0
eq "escalations --not-retired drops Retired rows" "$("$REG" escalations --open --not-retired --team esc4 | jq length)" 0
eq "escalations without the flag keeps them" "$("$REG" escalations --open --team esc4 | jq length)" 1
# a malformed escalations value breaks nothing
for bad in '"[]"' '{}' '5'; do
  printf '%s' "$saved" >"$FLEET_REGISTRY"
  "$REG" add '{"name":"bad/row","team":"bad","tier":"Worker","status":"Working"}'
  jq --argjson b "$bad" '.agents["bad/row"].escalations = $b' "$FLEET_REGISTRY" >"$T/r.json" && mv "$T/r.json" "$FLEET_REGISTRY"
  "$REG" add '{"name":"zlast/row","team":"zlast","tier":"Worker","status":"Working"}'
  for c in "$SCRIPTS/status.sh" "$SCRIPTS/status.sh --problems" "$REG list --problems" "$REG escalations --open" "$SCRIPTS/retire.sh --summary bad" "$SCRIPTS/watch.sh --once"; do
    $c >"$T/bad.out" 2>/dev/null; eq "escalations=$bad: ${c##*/} exits 0" "$?" 0
  done
  check "escalations=$bad: a row after the bad one is still listed" grep -q 'zlast/row' <(  "$SCRIPTS/status.sh" 2>/dev/null)
  "$REG" escalate bad/row P2 "after" >/dev/null 2>&1
  eq "escalations=$bad: escalate normalises to an array" "$("$REG" get bad/row | jq -c '.escalations | map(.message)')" '["after"]'
  "$REG" retire bad >/dev/null 2>&1
  eq "escalations=$bad: retire closes it" "$("$REG" escalations --open --team bad | jq length)" 0
done
printf '%s' "$saved" >"$FLEET_REGISTRY"
check "SKILL.md documents 'closed at retire'" grep -q 'closed at retire' "$SKD0/SKILL.md"
check "registry.md documents 'closed at retire'" grep -q 'closed at retire' "$SKD0/references/registry.md"
check "README documents resolve <id|at>" grep -q '<id|at>' "$SKD0/README.md"

# ---- DEV-368 C: esc_close, registry schema check, archive ----------------------------------------
_cstate="$FLEET_STATE_DIR"; _creg="$FLEET_REGISTRY"; _cinbox="${FLEET_INBOX:-}"
export FLEET_STATE_DIR="$T/cstate" FLEET_REGISTRY="$T/cstate/fleet.json" FLEET_INBOX="$T/cstate/escalations.jsonl"; mkdir -p "$FLEET_STATE_DIR"
crow() { "$REG" add "$(jq -cn --arg n "$1" --arg st "${2:-Working}" '{name: $n, team: ($n | split("/")[0]), tier: "Worker", status: $st, herdr_ref: "x", pane: "p"}')"; }
inject() { jq --argjson r "$1" '.agents[$r.name] = $r' "$FLEET_REGISTRY" >"$T/inject.tmp" && mv "$T/inject.tmp" "$FLEET_REGISTRY"; }

# esc_close: the shared close helper
got="$(. "$SCRIPTS/common.sh"; jq -nc "$ESC_DEFS"'{escalations: [{severity: "P1", message: "m", at: "a"}, {severity: "P2", message: "n", at: "b", resolved_at: "x", resolution: "kept"}, 5]}
  | esc_close("closed at next"; "T") | [.escalations[0].resolution, .escalations[0].resolved_at, .escalations[1].resolution, .escalations[2]]')"
eq "esc_close closes the open entry, keeps the closed one and a non-object element" "$got" '["closed at next","T","kept",5]'

# schema check on every write
crow cs/a; crow cs/b
cp "$FLEET_REGISTRY" "$T/c.before"
err="$("$REG" set cs/a discovered=oops 2>&1)"; rc=$?
eq "schema: a write that breaks a valid row is refused" "$((rc != 0))" 1
check "schema: the refusal names the row" grep -q 'cs/a' <<<"$err"
check "schema: the registry file is byte-identical after a refusal" cmp -s "$T/c.before" "$FLEET_REGISTRY"
"$REG" add '{"name":"cs/bad2","team":"cs","discovered":"x"}' >/dev/null 2>&1; eq "schema: a new row with discovered that is not an array is refused" "$?" 1
"$REG" add '{"name":7}' >/dev/null 2>&1; eq "schema: a row whose name is not a string is refused" "$?" 1
got="$(. "$SCRIPTS/common.sh"; jq -nc "$ESC_DEFS"'[{name: "a", escalations: [{severity: "P9", message: "m", at: "t"}]},
  {name: "a", escalations: [{severity: "P1", message: "m"}]}, {name: "a", escalations: [5]}, {name: "a", escalations: "[]"},
  {name: "a", escalations: [{severity: "P1", message: "m", at: "t", id: 3}]}, {name: "a", escalations: [{severity: "P1", message: "m", at: "t"}]}] | map(row_ok)')"
eq "schema: row_ok rejects a bad severity, a missing at, a non-object entry, a non-array and a non-string id" "$got" '[false,false,false,false,false,true]'
"$REG" add '{"name":"cs/ok","team":"cs"}' >/dev/null 2>&1; eq "schema: a well-formed row is accepted" "$?" 0
"$REG" escalate cs/a P1 "q" >/dev/null 2>&1; eq "schema: escalate still works" "$("$REG" get cs/a | jq '.escalations | length')" 1
# a row that is already malformed on disk does not block unrelated writes, and is repaired by escalate
inject '{"name":"cs/legacy","team":"cs","tier":"Worker","status":"Working","herdr_ref":"x","pane":"p","escalations":"[]"}'
"$REG" set cs/b status=Idle >/dev/null 2>"$T/c.warn"; eq "schema: a legacy malformed row does not block an unrelated write" "$?" 0
check "schema: and the write warns about it" grep -q 'malformed row' "$T/c.warn"
eq "schema: the unrelated write took effect" "$("$REG" get cs/b | jq -r .status)" Idle
"$REG" escalate cs/legacy P2 "repair" >/dev/null 2>&1
eq "schema: escalate repairs the legacy row" "$("$REG" get cs/legacy | jq -c '[(.escalations | type), (.escalations | length)]')" '["array",1]'

# archive
: >"$T/c.warn"
for n in ca/lead ca/w cb/x cd/z; do crow "$n"; done
inject '{"name":"ca/lead","team":"ca","tier":"Lead","status":"Retired","outcome":"Shipped","lessons":"l","ended":"2020-01-01T00:00:00Z","escalations":[],"discovered":[]}'
inject '{"name":"ca/w","team":"ca","tier":"Worker","status":"Retired","outcome":"Shipped","lessons":"l","ended":"2020-01-01T00:00:00Z","escalations":[],"discovered":[]}'
inject '{"name":"cb/x","team":"cb","tier":"Worker","status":"Retired","outcome":"Shipped","ended":"2020-01-01T00:00:00Z","escalations":[],"discovered":[]}'
inject '{"name":"cc/y","team":"cc","tier":"Worker","status":"Retired","outcome":"Shipped","lessons":"l","ended":"2020-01-01T00:00:00Z","escalations":[{"severity":"P1","message":"open","at":"2020-01-01T00:00:00Z"}],"discovered":[]}'
inject '{"name":"ce/new","team":"ce","tier":"Worker","status":"Retired","outcome":"Shipped","lessons":"l","ended":"2099-01-01T00:00:00Z","escalations":[],"discovered":[]}'
printf 'archive_after_days = 100000\n' >>"$FLEET_CONFIG_DIR/config.toml"
eq "archive: under a long archive_after_days nothing moves" "$("$REG" archive)" "[]"
sed -i.bak '/archive_after_days/d' "$FLEET_CONFIG_DIR/config.toml"; rm -f "$FLEET_CONFIG_DIR/config.toml.bak"
moved="$("$REG" archive)"
eq "archive: moves Retired rows with lessons and no open escalation" "$(printf '%s' "$moved" | jq -c 'sort')" '["ca/lead","ca/w"]'
eq "archive: the live registry no longer lists them" "$("$REG" list | jq -c '[.[].name] | map(select(startswith("ca/")))')" '[]'
eq "archive: the archive file holds them whole" "$(jq -c '[.agents | to_entries[] | [.key, .value.lessons, .value.status]] | sort' "$FLEET_STATE_DIR/fleet-archive.json")" '[["ca/lead","l","Retired"],["ca/w","l","Retired"]]'
eq "archive: a Retired row without lessons stays (debrief queue)" "$("$REG" get cb/x | jq -r .status)" Retired
eq "archive: a Retired row with an open escalation stays" "$("$REG" get cc/y | jq -r .status)" Retired
eq "archive: a live row stays" "$("$REG" get cd/z | jq -r .status)" Working
eq "archive: a row not yet old enough stays (ended in the future)" "$("$REG" get ce/new | jq -r .status)" Retired
cp "$FLEET_STATE_DIR/fleet-archive.json" "$T/c.arch"
eq "archive: idempotent, a second run moves nothing" "$("$REG" archive)" "[]"
check "archive: and leaves the archive file unchanged" cmp -s "$T/c.arch" "$FLEET_STATE_DIR/fleet-archive.json"
check "get: the live file no longer has an archived row" bash -c "! '$REG' get ca/w"
eq "get --archived finds it" "$("$REG" get --archived ca/w | jq -r .name)" ca/w
check "get --archived still finds a live row" bash -c "'$REG' get --archived cd/z"
eq "list does not show archived rows" "$("$REG" list --team ca | jq length)" 0
eq "list --with-archived does" "$("$REG" list --with-archived --team ca | jq length)" 2
eq "retire --summary reports the archived team's rows" "$("$SCRIPTS/retire.sh" --summary ca 2>/dev/null | jq -c '[.. | objects | select(.name? == "ca/w")] | length > 0')" true
eq "a debrief-queue row is still found after an archive run" "$("$REG" list | jq -c '[.[] | select(.outcome != null and (.lessons // "") == "") | .name] | sort')" '["cb/x"]'
export FLEET_STATE_DIR="$_cstate" FLEET_REGISTRY="$_creg"; [ -n "$_cinbox" ] && export FLEET_INBOX="$_cinbox" || unset FLEET_INBOX
check "SKILL.md documents the registry archive" grep -q 'registry.sh archive' "$SCRIPTS/../SKILL.md"
check "registry.md documents archive_after_days" grep -q 'archive_after_days' "$SCRIPTS/../references/registry.md"

# version and docs
SK="$SCRIPTS/.."; PLUGIN="$SK/../.."
eq "plugin.json version" "$(jq -r .version "$PLUGIN/.claude-plugin/plugin.json")" 3.6.1
eq "marketplace.json developer version" "$(jq -r '.plugins[] | select(.name == "developer") | .version' "$PLUGIN/../../.claude-plugin/marketplace.json")" 3.6.1
for k in min_free_gb warn_free_gb fleet-archive; do
  check "SKILL.md mentions $k" grep -q "$k" "$SK/SKILL.md"; check "README mentions $k" grep -q "$k" "$SK/README.md"
done
check "docs say the image marks" grep -q 'FLEET_IMAGE_TAG' "$SK/SKILL.md"
eq "no docker call reached the real binary (whole run)" "$(wc -l <"$REAL_DOCKER_LOG" | tr -d ' ')" 0

# Isolation
if command -v kubectl >/dev/null 2>&1; then
  eq "absent team kubeconfig shows no contexts" "$(KUBECONFIG="$FLEET_STATE_DIR/env/none/kubeconfig" kubectl config get-contexts -o name 2>/dev/null)" ""
else echo "skip kubectl not installed"; fi

# CI workflow (DEV-357): runs exactly this suite, and shellcheck at error severity on changed scripts
WF="$SCRIPTS/../../../../../.github/workflows/fleet-tests.yml"
check "CI workflow exists" test -f "$WF"
check "CI runs exactly the suite command" grep -qx '        run: bash plugins/developer/skills/fleet/scripts/test/run.sh' "$WF"
check "CI tests job runs on macos-latest" grep -q 'runs-on: macos-latest' "$WF"
check "CI shellcheck job runs on ubuntu-latest" grep -q 'runs-on: ubuntu-latest' "$WF"
check "CI runs shellcheck --severity=error" grep -q 'shellcheck --severity=error' "$WF"
check "CI lists changed *.sh against the base" grep -q "diff --name-only --diff-filter=ACMR .*-- '\*.sh'" "$WF"
check "CI shellcheck job fetches full history" grep -q 'fetch-depth: 0' "$WF"
check "CI triggers on pull_request" grep -qx '  pull_request:' "$WF"
check "CI permissions are contents: read" grep -qx '  contents: read' "$WF"
eq "CI jobs have a 30 minute timeout" "$(grep -c 'timeout-minutes: 30' "$WF")" 2
eq "CI has no install step" "$(grep -ciE 'brew |apt|apt-get|npm i|pip install' "$WF")" 0
check "run.sh exits non-zero on a failed assertion" bash -c "tail -n 1 '$HERE/run.sh' | grep -qx '\[ \"\$failn\" = 0 \]'"

printf '\n%d passed, %d failed\n' "$pass" "$failn"
[ "$failn" = 0 ]
