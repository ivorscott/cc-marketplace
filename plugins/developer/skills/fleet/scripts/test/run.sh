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
echo "up $*" >>"$STUB_LOG"; [ -z "${STUB_FAIL:-}" ] || exit 1
[ ! -f BRANCH_MARKER ] || echo "src $(cat BRANCH_MARKER)" >>"$STUB_LOG"
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
cd "$T/repo" # env.sh up falls back to $PWD for {{branch}}; never depend on the caller's cwd
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
"$REG" env-set build-plain cluster=foreign-cluster state=Up >/dev/null
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

: >"$HERDR_LOG"; "$SCRIPTS/boot.sh" build plainbt "$T/plain" task >/dev/null 2>&1
eq "boot without file: no KUBECONFIG arg (3.0.1 behaviour)" "$(grep -c -- '--env KUBECONFIG' "$HERDR_LOG")" 0
check "boot without file: no env dir" test ! -e "$FLEET_STATE_DIR/env/build-plainbt"

# No env anywhere: status header and retire JSON are the 3.0.1 ones
: >"$HERDR_LOG"; "$SCRIPTS/boot.sh" build plainst "$T/plain" task >/dev/null 2>&1
saved="$(cat "$FLEET_REGISTRY")"; jq 'del(.envs)' <<<"$saved" >"$FLEET_REGISTRY"
eq "no envs: status header is the 3.0.1 one" "$("$SCRIPTS/status.sh" --team build-plainst 2>/dev/null | head -1 | tr -s ' ')" "AGENT TIER STATUS ESC HERDR ASSIGNMENT"
"$SCRIPTS/retire.sh" build-plainst >"$T/r0.json" 2>"$T/r0.err"
eq "no envs: retire prints no env line" "$(cat "$T/r0.err" "$T/r0.json" | grep -ci 'environment\|env\.sh\|nothing to do')" 0
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
echo note >"$T/wt-keep/notes.md"; mkdir -p "$T/wt-keep/reports"; echo r >"$T/wt-keep/reports/r.md"
"$REG" add "$(jq -cn --arg t build-keep --arg r "$T/repo" --arg w "$T/wt-keep" '{name: "build-keep/tester", team: $t, repo: $r, tier: "Worker", status: "Working", herdr_ref: "x", pane: "p", worktree: $w}')"
"$SCRIPTS/retire.sh" build-keep >"$T/keep.json" 2>"$T/keep.err"
eq "retire keeps a worktree with untracked files" "$(jq -c '.kept_worktrees' "$T/keep.json")" "[\"$T/wt-keep\"]"
eq "retire lists untracked files in kept_untracked" "$(jq -c --arg w "$T/wt-keep" '.kept_untracked[$w] | sort' "$T/keep.json")" '["notes.md","reports/r.md"]'
check "retire warns with the untracked file name" grep -q '?? reports/r.md' "$T/keep.err"

# retire --summary: read-only, needs no herdr, gathers PRs, UNVERIFIED, escalations, worktrees
git -C "$T/repo" remote add origin git@github.com:acme/widgets.git
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
eq "summary: PRs deduped with the GitHub repo" "$(jq -c '[.prs[] | [.repo, .number]]' "$T/sum.json")" '[["acme/widgets",12],["acme/widgets",13]]'
eq "summary: UNVERIFIED rows" "$(jq -c '[.unverified[].name]' "$T/sum.json")" '["build-sum/tester"]'
eq "summary: open escalation" "$(jq -c '[.escalations[] | [.name, .severity, .open]]' "$T/sum.json")" '[["build-sum/lead","P1",true]]'
eq "summary: worktree would be kept, untracked named" "$(jq -c '[.worktrees[] | [.kept, .untracked]]' "$T/sum.json")" '[[true,["report.md"]]]'
"$SCRIPTS/retire.sh" --summary build-nope >/dev/null 2>&1; rc=$?
check "summary: unknown target fails" test "$rc" != 0

# Isolation
if command -v kubectl >/dev/null 2>&1; then
  eq "absent team kubeconfig shows no contexts" "$(KUBECONFIG="$FLEET_STATE_DIR/env/none/kubeconfig" kubectl config get-contexts -o name 2>/dev/null)" ""
else echo "skip kubectl not installed"; fi

printf '\n%d passed, %d failed\n' "$pass" "$failn"
[ "$failn" = 0 ]
