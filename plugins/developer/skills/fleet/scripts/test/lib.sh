#!/usr/bin/env bash
# The shared test harness: assertions (ok, bad, check, eq), a temporary fleet root under $T that never touches the live
# fleet (FLEET_TEST=1), shims for herdr, gh, docker, go and df, the golden fixture (gfix, gold) and the queue fixtures.
# Sourced by run.sh before the area files.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(dirname "$HERE")"
pass=0; failn=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { failn=$((failn + 1)); printf 'FAIL %s\n' "$1"; }
check() { # check <desc> <cmd...>
  local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }
told() { case "$1" in "Told "*" (delivered)" | "Told "*" (sent)" | "Told "*" (queued)") echo true ;; *) echo false ;; esac; } # tell.sh's reply line: was it delivered?

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# The suite never touches the live fleet: FLEET_TEST=1 makes common.sh refuse a registry, state dir or inbox under the
# live default, computed from the real HOME captured here, before HOME is overridden below.
export FLEET_REAL_HOME="$HOME" FLEET_TEST=1
export FLEET_STATE_DIR="$T/state" FLEET_CONFIG_DIR="$T/config" FLEET_REGISTRY="$T/state/fleet.json" FLEET_INBOX="$T/state/escalations.jsonl" FLEET_WORKTREES="$T/state/worktrees"
export FLEET_SESSION=test FLEET_MACHINE=test HOME="$T/home"; mkdir -p "$HOME" "$FLEET_CONFIG_DIR" "$T/bin"
# CI time: every wait or timeout override at its minimum, so no case waits on a real timeout.
export FLEET_TELL_POLL=0.1 FLEET_TELL_CONFIRM_SECS=2 FLEET_EXIT_WAIT_SECS=1 FLEET_CLAIM_SETTLE_SECS=0 FLEET_INSTALL_WAIT=3 FLEET_START_RETRY_SECS=0
unset FLEET_WORKTREE KUBECONFIG FLEET_ROLE FLEET_NAME FLEET_TEAM
export FLEET_TTY=0 # replies as markdown, wherever the suite runs (a case sets FLEET_TTY=1 for the terminal form)
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
      dangling=true) cat "$DKDIR/dimages" 2>/dev/null ;; # DEV-408 R8: the dangling images' sizes, one per line
    esac
    exit 0 ;;
  "buildx ls") cat "$DKDIR/builders"; exit 0 ;;
  "buildx rm") grep -vx "${4:-}\*\?" "$DKDIR/builders" >"$DKDIR/b.tmp"; mv "$DKDIR/b.tmp" "$DKDIR/builders"; exit 0 ;;
  # DEV-408 item 12. containers: ID <tab> kind cluster <tab> volumes (comma-separated); dangling: one volume per line;
  # df: the Type and Reclaimable columns of `docker system df`, tab-separated
  "ps -a") awk -F'\t' -v c="${4#label=io.x-k8s.kind.cluster=}" '$2 == c {print $1}' "$DKDIR/containers" 2>/dev/null; exit 0 ;;
  "inspect -f") awk -F'\t' -v i="$4" '$1 == i {gsub(",", "\n", $3); print $3}' "$DKDIR/containers" 2>/dev/null; exit 0 ;;
  "volume ls") cat "$DKDIR/dangling" 2>/dev/null; exit 0 ;;
  "system df") case "$*" in *'{{.Type}}'*) cat "$DKDIR/df" 2>/dev/null ;; *) cut -f2 "$DKDIR/df" 2>/dev/null ;; esac; exit 0 ;;
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
# Go is always a stub too (tick's prune, DEV-408 item 12): FLEET_GO points at it; a go shim first on PATH records any
# call that would reach a real binary and fails it. The stub's GOCACHE is $GO_CACHE.
export GO_LOG="$T/go.log" REAL_GO_LOG="$T/realgo.log" GO_CACHE="$T/gocache"; : >"$GO_LOG"; : >"$REAL_GO_LOG"; mkdir -p "$GO_CACHE"
printf '#!/usr/bin/env bash\necho "$*" >>"$REAL_GO_LOG"; exit 1\n' >"$T/bin/go"
printf '#!/usr/bin/env bash\necho "$*" >>"$GO_LOG"\n[ "$*" != "env GOCACHE" ] || echo "$GO_CACHE"\n' >"$T/go-stub"
chmod +x "$T/bin/go" "$T/go-stub"; export FLEET_GO="$T/go-stub"
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
# DEV-1107: the herdr server's pid and environment. lsof lists a client and the server on the socket ($AS/server.pid holds the
# server's pid; no file: no listener); ps eww shows HERDR_SERVER_ENV after the command, any other ps goes to the real one.
export HERDR_SOCK="$T/herdr.sock"
printf '#!/usr/bin/env bash\n[ -f "$AS/server.pid" ] || exit 1\nprintf "p999\\nn->0x1\\np%%s\\nn%%s\\n" "$(cat "$AS/server.pid")" "$HERDR_SOCK"\n' >"$T/bin/lsof"
printf '#!/usr/bin/env bash\ncase "$*" in *eww*) [ -f "$AS/server.pid" ] || exit 1; echo "herdr server PATH=/usr/bin ${HERDR_SERVER_ENV:-LANG=C}" ;; *) exec /bin/ps "$@" ;; esac\n' >"$T/bin/ps"
chmod +x "$T/bin/lsof" "$T/bin/ps"
# boot.sh and retire.sh with a shim herdr
cat >"$T/bin/herdr" <<'S'
#!/usr/bin/env bash
[ "${1:-}" != --version ] || { echo "herdr ${HERDR_VERSION:-0.9.1}"; exit 0; } # DEV-512 item 5
shift 2 # --session <name>
# Log a --settings file by its content, so allow-list checks read what the agent gets.
logged=(); prev=""
for a in "$@"; do
  if [ "$prev" = "--settings" ] && [ -f "$a" ]; then logged+=("$(cat "$a")"); else logged+=("$a"); fi
  prev="$a"
done
# One line per call, whole: parallel restarts log long lines (the --settings content), so a line is appended under a
# lock (DEV-512 item 23: two lines written at once came out interleaved).
until mkdir "$HERDR_LOG.lock" 2>/dev/null; do sleep 0.01; done
echo "${logged[*]}" >>"$HERDR_LOG"; rmdir "$HERDR_LOG.lock"
case "$1 $2" in
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"p0"}}}' ;;
  # SPLIT_FAIL_AT=<n>: the n-th split fails (DEV-408 item 8, a boot that dies after the first panes)
  "pane split") n=$(( $(grep -c '^pane split' "$HERDR_LOG") )); [ "${SPLIT_FAIL_AT:-0}" != "$n" ] || exit 1
    echo "{\"result\":{\"pane\":{\"pane_id\":\"p$n\"}}}" ;;
  "pane process-info")
    if [ -n "${GONE_ONCE:-}" ] && [ -e "$GONE_ONCE" ]; then rm -f "$GONE_ONCE"; exit 1; fi
    # an agent that got /exit shows its shell until it is started again
    if ls "$AS"/exited.* >/dev/null 2>&1; then
      for xr in $(jq -r --arg p "$4" '.agents[] | select(.pane == $p) | .herdr_ref' "$FLEET_STATE_DIR/fleet.json" 2>/dev/null); do
        if [ -e "$AS/exited.$xr" ]; then echo '{"result":{"process_info":{"foreground_process_group_id":1,"shell_pid":1}}}'; exit 0; fi
      done
    fi
    if [ -n "${PANE_GONE:-}" ]; then echo '{"result":{"process_info":{"foreground_process_group_id":1,"shell_pid":1}}}'; exit 1; fi
    if [ -n "${DEAD_ONCE:-}" ] && [ -e "$DEAD_ONCE" ]; then rm -f "$DEAD_ONCE"; echo '{"result":{"process_info":{"foreground_process_group_id":1,"shell_pid":1}}}'
    else echo '{"result":{"process_info":{"foreground_process_group_id":2,"shell_pid":1}}}'; fi ;;
  # Per-agent state in $AS: "agent get" reports it (idle when unset), a prompt makes the agent
  # working unless PROMPT_NOSTATE is set, and `agent read` prints $AS/<agent>.read.
  # A pane started by the shim runs what boot types into it, so its env can be dumped: $AS/<pane>.env.
  "pane run") ( eval "${*:4}"; env ) >"$AS/$3.env" 2>/dev/null; echo '{}' ;;
  # START_HOLD=<agent>: its start leaves $AS/held.<agent> and takes 2s, so a test can interrupt the boot there.
  # START_WAIT=<agent>: its start leaves $AS/held.<agent> and waits until the test removes it (30s at most).
  # NAME_TAKEN=<file holding n>: the next n starts are refused with agent_name_taken (DEV-512 item 12)
  "agent start") if [ -n "${NAME_TAKEN:-}" ] && [ "$(cat "$NAME_TAKEN" 2>/dev/null || echo 0)" -gt 0 ]; then
      echo $(($(cat "$NAME_TAKEN") - 1)) >"$NAME_TAKEN"; echo '{"error":{"code":"agent_name_taken","message":"agent name is taken"}}'; exit 1; fi
    rm -f "$AS/$3" "$AS/$3.read" "$AS/exited.$3"
    if [ "${START_HOLD:-}" = "$3" ]; then : >"$AS/held.$3"; sleep 2; fi
    if [ "${START_WAIT:-}" = "$3" ]; then : >"$AS/held.$3"; for _ in $(seq 1 300); do [ -e "$AS/held.$3" ] || break; sleep 0.1; done; fi
    echo '{}' ;;
  "agent list") [ -z "${AGENT_LIST_FAIL:-}" ] || exit 1; cat "$AS/agent-list.json" 2>/dev/null || echo '{}' ;;
  # A pane with $AS/<pane>.name answers `agent get <pane>` with that name and its pane id, as herdr does.
  "agent get") echo "{\"result\":{\"agent\":{\"agent_status\":\"$(cat "$AS/$3" 2>/dev/null || echo idle)\",\"state_change_seq\":$(cat "$AS/$3.seq" 2>/dev/null || echo 0)$([ ! -f "$AS/$3.name" ] || printf ',"name":"%s","pane_id":"%s"' "$(cat "$AS/$3.name")" "$3")}}}" ;;
  "agent wait") [ ! -e "$AS/$3" ] || echo idle >"$AS/$3"; echo '{}' ;;
  "agent prompt")
    [ -z "${PROMPT_FAIL:-}" ] || exit 1
    [ -n "${PROMPT_NOSTATE:-}" ] || echo working >"$AS/$3"
    [ -z "${PROMPT_SEQ:-}" ] || echo $(( $(cat "$AS/$3.seq" 2>/dev/null || echo 0) + 1 )) >"$AS/$3.seq"
    [ -z "${PROMPT_TRANSCRIPT:-}" ] || jq -nc --arg c "$4" '{type: "user", message: {role: "user", content: $c}}' >>"$PROMPT_TRANSCRIPT"
    # A brief pointer shows up in the agent's transcript as a user line (BRIEF_QUEUED: a queued_command attachment;
    # BRIEF_LOST: nowhere), like Claude Code writing the prompt it received. /exit leaves the pane at its shell.
    case "$4" in
      "Read your brief: "*)
        if [ -z "${BRIEF_LOST:-}" ]; then
          xt="$(jq -r --arg r "$3" '[.agents[] | select(.herdr_ref == $r) | .transcript // ""] | first // ""' "$FLEET_STATE_DIR/fleet.json" 2>/dev/null)"
          if [ -n "$xt" ]; then
            mkdir -p "$(dirname "$xt")"
            if [ -n "${BRIEF_QUEUED:-}" ]; then jq -nc --arg c "$4" '{type: "attachment", attachment: {type: "queued_command", prompt: $c}}' >>"$xt"
            else jq -nc --arg c "$4" '{type: "user", message: {role: "user", content: $c}}' >>"$xt"; fi
          fi
        fi ;;
      # EXIT_DIALOG=1: Claude asks first, as it does with background work running, until enter confirms (DEV-512 item 14)
      /exit) if [ -n "${EXIT_DIALOG:-}" ]; then printf 'Background work is running\n\n  1. Exit and stop tasks\n\nEnter to confirm\n' >"$AS/$3.read"; : >"$AS/$3.dialog"
             elif [ -z "${EXIT_STUCK:-}" ]; then : >"$AS/exited.$3"; fi ;;
    esac
    echo '{}' ;;
  "agent send-keys") [ -z "${ENTER_WORKS:-}" ] || [ "$4" != enter ] || echo working >"$AS/$3"
    # SEND_KEYS_FAIL=<key>: herdr refuses that key (4.1.3, bug 9)
    [ "${SEND_KEYS_FAIL:-}" != "$4" ] || { echo '{"error":{"code":"invalid_key"}}' >&2; exit 1; }
    if [ -e "$AS/$3.dialog" ] && [ "$4" = enter ]; then rm -f "$AS/$3.dialog" "$AS/$3.read"; : >"$AS/exited.$3"; fi; echo '{}' ;;
  "agent read") cat "$AS/$3.read" 2>/dev/null || true ;;
  "notification show") if [ -n "${NOTIFY_FAIL:-}" ]; then echo "herdr: no server" >&2; exit 1; fi; echo '{}' ;;
  # herdr's Claude integration: current unless HERDR_INTEGRATION says otherwise (DEV-408 item 13), or the whole
  # answer in HERDR_INTEGRATION_FILE (DEV-512 item 4: a long one).
  # status server --json (DEV-1107): only the socket path, as in herdr 0.9.1 (no pid, no start time)
  "status server") printf '{"status":"running","socket":"%s"}\n' "${HERDR_SOCK:-/nonexistent/herdr.sock}" ;;
  "integration status") if [ -n "${HERDR_INTEGRATION_FILE:-}" ]; then cat "$HERDR_INTEGRATION_FILE"; else printf '%s\n' "${HERDR_INTEGRATION:-claude: current}"; fi ;;
  # the panel metadata (DEV-408 item 14); META_FAIL=1 makes herdr refuse it. Like herdr 0.9, the id comes first: an
  # option before it is refused (DEV-512 item 5).
  "workspace report-metadata" | "pane report-metadata")
    case "${3:-}" in --*) echo "unknown option: ${4:-}" >&2; exit 2 ;; esac
    [ -z "${META_FAIL:-}" ] || { echo '{"error":{"code":"metadata_refused","message":"metadata refused"}}' >&2; exit 1; }; echo '{}' ;;
  # slim (DEV-408 item 15): RELOAD_FAIL=1 makes herdr refuse to reload its config
  "server reload-config") [ -z "${RELOAD_FAIL:-}" ] || exit 1; echo '{}' ;;
  *) echo '{}' ;;
esac
S
chmod +x "$T/bin/herdr"; export HERDR_LOG="$T/herdr.log" AS="$T/as"; mkdir -p "$AS"
# Nothing in the suite reaches GitHub: a gh on PATH logs the call and fails (the cases point FLEET_GH at shims).
export REAL_GH_LOG="$T/realgh.log"; : >"$REAL_GH_LOG"
printf '#!/usr/bin/env bash\necho "$*" >>"$REAL_GH_LOG"; exit 1\n' >"$T/bin/gh"; chmod +x "$T/bin/gh"

# The golden fixture (DEV-408 item 17): a fleet with fixed times, rendered against scripts/test/golden/<entry>.md.
# gfix points the state root at a fresh $T/gold and seeds the registry, an env and the event log; gold compares one
# reply with its golden file, after $T is written as <T>. FLEET_GOLDEN_UPDATE=1 writes the files instead (review the diff).
GD="$HERE/golden"
gfix() {
  G="$T/gold"; rm -rf "$G"; mkdir -p "$G/state" "$G/repo"
  export FLEET_STATE_DIR="$G/state" FLEET_REGISTRY="$G/state/fleet.json" FLEET_INBOX="$G/state/escalations.jsonl" FLEET_WORKTREES="$G/state/worktrees"
  git init -q -b main "$G/repo"; git -C "$G/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git init -q --bare "$G/origin.git"; git -C "$G/repo" remote add origin "$G/origin.git"; git -C "$G/repo" push -q origin main 2>/dev/null
  rm -f "$AS"/g[aowd]-*; echo working >"$AS/ga-lead"; echo working >"$AS/ga-builder"
  jq -n --arg r "$G/repo" '
    def row($n; $tier; $st; $ref; $pane): {name: $n, team: ($n | split("/")[0]), tier: $tier, template: "build", harness: "claude",
      status: $st, herdr_ref: $ref, pane: $pane, workspace: "gw1", repo: $r, cwd: $r, machine: "test", assignment: "task",
      started: "2026-10-24T07:00:00Z", updated_at: "2026-10-24T08:30:00Z", discovered: [], escalations: []};
    {agents: ([
      row("build-api/lead"; "Lead"; "Working"; "ga-lead"; "pga1") + {model: "opus", issue: "DEV-12", issue_url: "https://linear.app/acme/issue/DEV-12/export", issue_title: "API: export",
        escalation: "P1", escalations: [{id: "20261024T080000Z-1", severity: "P1", message: "which database?", options: ["postgres", "sqlite"], at: "2026-10-24T08:00:00Z"}]},
      row("build-api/builder"; "Worker"; "Working"; "ga-builder"; "pga2") + {model: "sonnet", issue: "DEV-12", issue_url: "https://linear.app/acme/issue/DEV-12/export", issue_title: "API: export", pr: "https://github.com/acme/app-api/pull/214"},
      row("build-api/tester"; "Worker"; "Idle"; "ga-tester"; "pga3") + {model: "sonnet", issue: "DEV-12", issue_url: "https://linear.app/acme/issue/DEV-12/export", issue_title: "API: export"},
      row("build-web/lead"; "Lead"; "Done"; "gw-lead"; "pgw1") + {model: "opus", issue: "DEV-13", outcome: "Shipped", pr: "https://github.com/acme/app-web/pull/121"},
      row("build-web/builder"; "Worker"; "Done"; "gw-builder"; "pgw2") + {model: "sonnet", issue: "DEV-13", outcome: "Shipped"},
      row("build-web/tester"; "Worker"; "Done"; "gw-tester"; "pgw3") + {model: "sonnet", issue: "DEV-13", outcome: "Shipped",
        pr: "https://github.com/acme/app-web/pull/121", signoff: {pr: "https://github.com/acme/app-web/pull/121", sha: "1111111", at: "2026-10-23T11:20:00Z"}},
      row("build-old/lead"; "Lead"; "Parked"; "go-lead"; "pgo1") + {model: "opus", issue: "DEV-9", parked_reason: "park", parked_at: "2026-10-23T18:00:00Z"},
      row("build-old/builder"; "Worker"; "Parked"; "go-builder"; "pgo2") + {model: "sonnet", issue: "DEV-9", parked_reason: "park", parked_at: "2026-10-23T18:00:00Z"},
      row("build-done/lead"; "Lead"; "Retired"; "gd-lead"; "pgd1") + {outcome: "Shipped", ended: "2026-10-24T06:00:00Z", discovered: [{message: "flaky smoke test", at: "2026-10-24T05:00:00Z"}]},
      row("build-done/builder"; "Worker"; "Retired"; "gd-builder"; "pgd2") + {outcome: "Partial", ended: "2026-10-24T06:00:00Z", lessons: "push before done"}
    ] | map({(.name): .}) | add),
    envs: {"build-api": {cluster: "fleet-build-api", state: "Up", slot: 0, http_port: 8080, https_port: 8443, updated_at: "2026-10-24T08:00:00Z"}}}' >"$FLEET_REGISTRY"
  cat >"$FLEET_STATE_DIR/events.jsonl" <<'J'
{"at":"2026-10-23T10:00:00Z","type":"boot","team":"build-web","issue":"DEV-13"}
{"at":"2026-10-23T11:30:00Z","type":"pr_ready","team":"build-web","name":"build-web/lead","pr":"https://github.com/acme/app-web/pull/120","sha":"1111111aaaa"}
{"at":"2026-10-23T12:00:00Z","type":"pr_merged","team":"build-web","name":"build-web/lead","pr":"https://github.com/acme/app-web/pull/120"}
{"at":"2026-10-24T07:00:00Z","type":"boot","team":"build-api","issue":"DEV-12"}
{"at":"2026-10-24T08:40:00Z","type":"signoff","team":"build-api","name":"build-api/tester","pr":"https://github.com/acme/app-api/pull/214","sha":"abc1234"}
{"at":"2026-10-24T08:45:00Z","type":"pr_ready","team":"build-api","name":"build-api/tester","pr":"https://github.com/acme/app-api/pull/214","sha":"abc1234def"}
{"at":"2026-10-24T08:50:00Z","type":"brief_delivered","team":"build-api","name":"build-api/builder"}
J
  # GitHub (the queue): app-web #121 signed, green and mergeable; app-api #214 not signed off. Linear: no relations.
  mkdir -p "$G/ghd"; export GOLD_GH="$G/ghd" FLEET_GH="$G/gh-gold"
  cat >"$FLEET_GH" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") cat "$GOLD_GH/${3##*/}.json" ;;
  "pr list") jq -s --arg r "${4##*/}" '[.[] | select(.url | contains("/" + $r + "/pull/"))]' "$GOLD_GH"/*.json ;;
esac
S
  chmod +x "$FLEET_GH"
  for p in "app-api 214 abc1234def5678 fleet/dev-12-export DEV-12/export 2026-10-24T08:00:00Z api/export.go" "app-web 121 1111111aaaa fleet/dev-13-web DEV-13/web 2026-10-23T11:00:00Z web/app.ts"; do
    set -- $p
    jq -n --arg r "$1" --argjson n "$2" --arg h "$3" --arg b "$4" --arg i "$5" --arg c "$6" --arg f "$7" '{number: $n, url: "https://github.com/acme/\($r)/pull/\($n)",
      state: "OPEN", title: "t", headRefOid: $h, headRefName: $b, baseRefName: "main", mergeable: "MERGEABLE", isDraft: false,
      statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"}], body: "Fixes https://linear.app/acme/issue/\($i)",
      createdAt: $c, files: [{path: $f}]}' >"$GOLD_GH/$2.json"
  done
  export LINEAR_STUB_KEY="${LINEAR_STUB_KEY:-KEYFIXTURE-gold}" LINEAR_DB="$G/linear.json" LINEAR_LOG="$G/linear.log" LINEAR_ARGV_LOG="$G/linear.argv" FLEET_CURL="$HERE/linear-stub.sh"
  printf '%s\n' "$LINEAR_STUB_KEY" >"$FLEET_CONFIG_DIR/linear_api_key"; chmod 600 "$FLEET_CONFIG_DIR/linear_api_key"
  jq -n '{team: "T1", states: {}, next: 1, labels: [], issues: [("DEV-12", "DEV-13") as $i | {id: $i, identifier: $i, team: {id: "T1"}, state: {id: "S", name: "In Progress"}, labelIds: [], comments: []}]}' >"$LINEAR_DB"
}
# The merge queue cases (DEV-408 item 18): qfresh <name> gives a fresh state root and empty gh answers; qpr writes one
# PR's `gh pr view` answer; qteam adds a Done builder that holds the PR and its tester (signed off when a sha is given);
# q runs queue.sh through the gh shim; qorder prints "repo#N|why|after ; ..." for the ready ones.
QD="$T/q408"; mkdir -p "$QD/gh"; export QGHD="$QD/gh"
# `pr list --repo acme/<r>` answers every qpr PR of <r> and the PRs in list-<r>.json (other machines' ones).
cat >"$QD/gh-shim" <<'S'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") n="${3##*/}"; r="$(printf %s "$3" | sed -E "s#https://[^/]+/[^/]+/([^/]+)/pull/.*#\\1#")"; cat "$QGHD/$r-$n.json" ;;
  "pr list") r="${4##*/}"; case " $* " in *" --state merged "*) cat "$QGHD/merged-$r.json" 2>/dev/null || echo '[]'; exit 0 ;; esac
    { for f in "$QGHD/$r"-[0-9]*.json; do [ ! -f "$f" ] || cat "$f"; done
      [ ! -f "$QGHD/list-$r.json" ] || jq -c '.[]' "$QGHD/list-$r.json"; } | jq -s . ;;
esac
S
chmod +x "$QD/gh-shim"
qfresh() { export FLEET_STATE_DIR="$QD/state.$1" FLEET_REGISTRY="$QD/state.$1/fleet.json"; mkdir -p "$FLEET_STATE_DIR"; rm -f "$QGHD"/*.json; }
qpr() { # qpr <repo> <n> <head> <base> <created> <files json> <body> [mergeable] [title]
  jq -cn --arg r "$1" --argjson n "$2" --arg h "$3" --arg b "$4" --arg c "$5" --argjson f "$6" --arg body "$7" --arg m "${8:-MERGEABLE}" --arg t "${9:-t}" \
    '{number: $n, url: "https://github.com/acme/\($r)/pull/\($n)", state: "OPEN", title: $t, headRefOid: "aaaaaaa\($n)", headRefName: $h, baseRefName: $b,
      mergeable: $m, isDraft: false, statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"}], body: $body,
      createdAt: $c, files: ($f | map({path: .}))}' >"$QGHD/$1-$2.json"
}
qteam() { # qteam <team> <repo> <n> <issue> [signed sha]
  "$REG" add "$(jq -cn --arg t "$1" --arg u "https://github.com/acme/$2/pull/$3" --arg i "$4" '{name: ($t + "/builder"), team: $t, tier: "Worker", status: "Done", herdr_ref: ($t + "-b"), pane: "p", pr: $u, issue: $i}')" >/dev/null
  "$REG" add "$(jq -cn --arg t "$1" --arg i "$4" '{name: ($t + "/tester"), team: $t, tier: "Worker", status: "Done", herdr_ref: ($t + "-t"), pane: "p", issue: $i}')" >/dev/null
  [ -z "${5:-}" ] || "$REG" signoff "$1/tester" "https://github.com/acme/$2/pull/$3" "$5" >/dev/null
}
q() { FLEET_GH="$QD/gh-shim" "$SCRIPTS/queue.sh"; }
# The redact check (DEV-408 item 5): rfix <dir> makes a repo whose branch `feat` adds a line with a term (in another
# case), `msg` has a term only in its commit message, and `clean` has neither; rterms <state dir> writes the made-up
# terms zebra-corp and acme-secret, with a comment and a blank line, to its private/redact_terms.txt (mode 600). Tests
# point FLEET_STATE_DIR at a temp dir, so the real terms file is never read.
rterms() { mkdir -p "$1/private"; (umask 077; printf '# made-up terms\n\n  zebra-corp\nacme-secret\n' >"$1/private/redact_terms.txt"); }
rfix() {
  local d="$1"; git init -q -b main "$d"; git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$d" checkout -q -b feat; printf 'see the Zebra-Corp docs\nplain line\n' >"$d/a.txt"; git -C "$d" add a.txt; git -C "$d" -c user.email=t@t -c user.name=t commit -q -m "add notes"
  git -C "$d" checkout -q -b msg main; echo ok >"$d/b.txt"; git -C "$d" add b.txt; git -C "$d" -c user.email=t@t -c user.name=t commit -q -m "for acme-secret review"
  git -C "$d" checkout -q -b clean main; echo ok >"$d/c.txt"; git -C "$d" add c.txt; git -C "$d" -c user.email=t@t -c user.name=t commit -q -m "tidy"
  git -C "$d" checkout -q main
}
# Background tasks (DEV-408 item 6): bgk <file> [stop tool] [input key] [notified] writes a transcript with a background
# Bash start (kjob1), then how it ended; bgn <file> is transcript_bg_running's count an hour later.
bgk() {
  { jq -nc '{type: "assistant", timestamp: "2026-10-24T09:00:00Z", message: {content: [{type: "tool_use", id: "toolu_k", name: "Bash", input: {command: "x", run_in_background: true}}]}}'
    jq -nc '{type: "user", message: {content: [{type: "tool_result", tool_use_id: "toolu_k", content: "Command running in background with ID: kjob1. Output is being written to: /x"}]}}'
    [ -z "${2:-}" ] || jq -nc --arg n "$2" --arg k "$3" '{type: "assistant", message: {content: [{type: "tool_use", id: "toolu_s", name: $n, input: {($k): "kjob1"}}]}}'
    [ -z "${4:-}" ] || jq -nc '{type: "user", message: {content: "<task-notification><task-id>kjob1</task-id><status>completed</status></task-notification>"}}'
  } >"$1"
}
bgn() { FLEET_NOW=2026-10-24T10:00:00Z bash -c '. "$1/common.sh"; transcript_bg_running "$2"' _ "$SCRIPTS" "$1"; }
qorder() { q | jq -r '[.ready[] | "\(.url | sub(".*/acme/"; "") | sub("/pull/"; "#"))|\(.why)|\(.after)"] | join(" ; ")'; }
gcfg() { printf '%s\n' "$@" >"$FLEET_CONFIG_DIR/config.toml"; } # gcfg ['key = value'...]: the whole config.toml, nothing else
gold() { # gold <entry> <reply>
  local got name="${GOLD_PREFIX:-}dev408-17 output: golden $1"; got="$(printf '%s\n' "$2" | sed "s#$T#<T>#g")"
  if [ "${FLEET_GOLDEN_UPDATE:-}" = 1 ]; then printf '%s\n' "$got" >"$GD/$1.md"; ok "$name (written)"; return; fi
  if [ -f "$GD/$1.md" ] && [ "$got" = "$(cat "$GD/$1.md")" ]; then ok "$name"
  else bad "$name"; diff <(cat "$GD/$1.md" 2>/dev/null) <(printf '%s\n' "$got") | head -n 12 | sed 's/^/      /'; fi
}
