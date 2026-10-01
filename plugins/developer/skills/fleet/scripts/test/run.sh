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
eq "down removes the tag match and the label match, tries the pinned one" "$(grep '^rmi' "$DOCKER_LOG" | sort | tr '\n' ',')" 'rmi ID2,rmi ID5,rmi app:fleet-build-a,'
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
check "boot: tester allow has the team-scoped kubectl context" grep -q -- "kubectl --context fleet-build-envt get" <(grep '^agent start build-envt-tester' "$HERDR_LOG")
eq "boot: no unsubstituted {{team}} or {{worktree}} in an allow list" "$(grep '^agent start' "$HERDR_LOG" | grep -c '{{team}}\|{{worktree}}')" 0
eq "boot: every agent gets tracker_allow" "$(grep '^agent start' "$HERDR_LOG" | grep -c 'jira issue view')" "$(grep -c '^agent start' "$HERDR_LOG")"
eq "boot: every agent gets forge_allow" "$(grep '^agent start' "$HERDR_LOG" | grep -c 'glab mr create')" "$(grep -c '^agent start' "$HERDR_LOG")"
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
check "watch prints free disk" grep -q 'disk 60 GiB free' "$T/w.out"
: >"$HERDR_LOG"; DF_GB=100 "$SCRIPTS/watch.sh" --once >/dev/null 2>&1
eq "watch: no disk notification above warn_free_gb" "$(grep -c 'fleet: disk' "$HERDR_LOG")" 0
: >"$HERDR_LOG"; DF_GB=30 "$SCRIPTS/watch.sh" --once >/dev/null 2>&1
eq "watch: below min_free_gb the notification says boot refuses" "$(grep -c 'fleet: disk 30 GiB free, boot refuses below min_free_gb=40' "$HERDR_LOG")" 1

# version and docs
SK="$SCRIPTS/.."; PLUGIN="$SK/../.."
eq "plugin.json version" "$(jq -r .version "$PLUGIN/.claude-plugin/plugin.json")" 3.3.0
eq "marketplace.json developer version" "$(jq -r '.plugins[] | select(.name == "developer") | .version' "$PLUGIN/../../.claude-plugin/marketplace.json")" 3.3.0
for k in min_free_gb warn_free_gb fleet-archive; do
  check "SKILL.md mentions $k" grep -q "$k" "$SK/SKILL.md"; check "README mentions $k" grep -q "$k" "$SK/README.md"
done
check "docs say the image marks" grep -q 'FLEET_IMAGE_TAG' "$SK/SKILL.md"
eq "no docker call reached the real binary (whole run)" "$(wc -l <"$REAL_DOCKER_LOG" | tr -d ' ')" 0

# Isolation
if command -v kubectl >/dev/null 2>&1; then
  eq "absent team kubeconfig shows no contexts" "$(KUBECONFIG="$FLEET_STATE_DIR/env/none/kubeconfig" kubectl config get-contexts -o name 2>/dev/null)" ""
else echo "skip kubectl not installed"; fi

printf '\n%d passed, %d failed\n' "$pass" "$failn"
[ "$failn" = 0 ]
