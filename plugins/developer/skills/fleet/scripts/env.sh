#!/usr/bin/env bash
# A team's own disposable test environment, declared by the repo and created on demand.
#
#   env.sh up [--branch B] <team>   allocate a port slot, run the repo's `up`, write the team kubeconfig
#   env.sh down <team>              run the repo's `down`, remove the kubeconfig, free the slot
#   env.sh status [<team>]          one env as JSON, or every env as a table
#
# The repo opts in with <repo>/.claude/fleet-env.json:
#   {"up": "...", "down": "...", "kubeconfig": "..."}   command templates; placeholders:
#   {{cluster}} {{http_port}} {{https_port}} {{branch}} {{kubeconfig}} {{team}}
# `up` and `kubeconfig` run in the repo directory with KUBECONFIG=<team kubeconfig>. The
# kubeconfig template writes the file itself; env.sh then sets mode 600 and checks that
# it holds exactly one context. Without the file, `up` does nothing (exit 0).
#
# Exit codes: 0 ok, 1 error, 75 queued (max_envs reached; retry `up` once an env is down).
# Env: FLEET_WORKTREE (default source of {{branch}}), max_envs in config.toml (default 3).
set -euo pipefail
. "$(dirname "$0")/common.sh"
registry="$FLEET_SCRIPTS/registry.sh"

sub="${1:-}"; shift || true

team_repo() { "$registry" list --team "$1" | jq -r '[.[].repo | select(. != null and . != "")] | first // ""'; }

port_busy() { # listening on the host?
  if command -v nc >/dev/null 2>&1; then nc -z 127.0.0.1 "$1" >/dev/null 2>&1
  elif command -v lsof >/dev/null 2>&1; then lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else return 1; fi
}

kube_contexts() { # count contexts in a kubeconfig file
  awk '/^contexts:/ {on = 1; next} /^[^ -]/ {on = 0} on && /^- / {n++} END {print n + 0}' "$1"
}

run_tpl() { # run_tpl <repo> <kubeconfig> <template>
  (cd "$1" && KUBECONFIG="$2" bash -c "$3")
}

fail() { "$registry" env-set "$team" state=Failed >/dev/null; die "$*"; }

case "$sub" in
  up)
    branch=""
    while [ $# -gt 0 ]; do
      case "$1" in --branch) branch="${2:?--branch needs a value}"; shift 2 ;; *) break ;; esac
    done
    team="${1:?usage: env.sh up [--branch B] <team>}"
    repo="$(team_repo "$team")"; [ -n "$repo" ] || die "no repo recorded for team '$team' in the registry"
    cfg="$(env_config "$repo")"
    if [ -z "$cfg" ]; then echo "fleet: no team environment declared ($repo/.claude/fleet-env.json); nothing to do"; exit 0; fi
    up_t="$(jq -r '.up // ""' "$cfg")"; down_t="$(jq -r '.down // ""' "$cfg")"; kc_t="$(jq -r '.kubeconfig // ""' "$cfg")"
    [ -n "$up_t" ] && [ -n "$down_t" ] || die "$cfg must declare \"up\" and \"down\""

    cluster="$(agent_name "fleet-$team")"
    cur="$("$registry" env-get "$team" 2>/dev/null || echo '{}')"
    if [ "$(printf '%s' "$cur" | jq -r '.state // ""')" = "Up" ]; then
      echo "fleet: $team environment already up ($(printf '%s' "$cur" | jq -r '.cluster'))"; exit 0
    fi

    if [ -z "$branch" ]; then
      wt="${FLEET_WORKTREE:-$PWD}"
      branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
      [ -n "$branch" ] && [ "$branch" != "HEAD" ] || die "cannot tell the branch for {{branch}} from $wt; pass --branch"
    fi
    git -C "$repo" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1 ||
      warn "branch '$branch' is not on origin; the cluster will sync whatever origin has"

    max="$(max_envs)"; busy=""
    for n in $(seq 0 $((max - 1))); do
      if port_busy $((8080 + 10 * n)) || port_busy $((8443 + 10 * n)); then busy="$busy${busy:+,}$n"; fi
    done
    claim="$("$registry" env-claim "$team" "$max" "$cluster" "$busy")"
    if [ "$(printf '%s' "$claim" | jq -r '.state')" = "Queued" ]; then
      echo "fleet: $team queued: max_envs=$max reached or every port slot is busy; no cluster created. Retry 'env.sh up $team' after another team's env is down." >&2
      exit 75
    fi
    http="$(printf '%s' "$claim" | jq -r .http_port)"; https="$(printf '%s' "$claim" | jq -r .https_port)"
    dir="$(env_dir "$team")"; kc="$dir/kubeconfig"
    mkdir -p "$dir"; chmod 700 "$dir"
    "$registry" env-set "$team" repo="$repo" branch="$branch" kubeconfig="$kc" >/dev/null

    echo "fleet: creating $cluster (http $http, https $https, branch $branch)"
    run_tpl "$repo" "$kc" "$(render_env "$up_t" "$team" "$cluster" "$http" "$https" "$branch" "$kc")" >&2 ||
      fail "up failed for $cluster; the slot is kept until 'env.sh down $team'"
    if [ -n "$kc_t" ]; then
      run_tpl "$repo" "$kc" "$(render_env "$kc_t" "$team" "$cluster" "$http" "$https" "$branch" "$kc")" >&2 ||
        fail "kubeconfig step failed for $cluster"
    fi
    [ -f "$kc" ] || fail "no kubeconfig at $kc after up"
    chmod 600 "$kc"
    [ "$(kube_contexts "$kc")" = "1" ] || fail "$kc must contain exactly one context"
    "$registry" env-set "$team" state=Up >/dev/null
    echo "fleet: $cluster up; KUBECONFIG=$kc"
    ;;
  down)
    team="${1:?usage: env.sh down <team>}"
    cur="$("$registry" env-get "$team" 2>/dev/null || true)"
    [ -n "$cur" ] || { echo "fleet: $team has no environment; nothing to do"; exit 0; }
    cluster="$(agent_name "fleet-$team")"
    # Only ever act on a cluster this registry created under the fleet-<team> name.
    [ "$(printf '%s' "$cur" | jq -r '.cluster // ""')" = "$cluster" ] || die "registry cluster for $team is not $cluster; refusing to run down"
    state="$(printf '%s' "$cur" | jq -r '.state // ""')"
    [ "$state" != "Down" ] || { echo "fleet: $team environment already down"; exit 0; }
    if [ "$state" != "Queued" ]; then
      repo="$(printf '%s' "$cur" | jq -r '.repo // ""')"; cfg="$(env_config "$repo")"
      [ -n "$cfg" ] || die "cannot run down for $team: $repo/.claude/fleet-env.json is gone"
      kc="$(printf '%s' "$cur" | jq -r '.kubeconfig')"
      http="$(printf '%s' "$cur" | jq -r '.http_port // ""')"; https="$(printf '%s' "$cur" | jq -r '.https_port // ""')"
      br="$(printf '%s' "$cur" | jq -r '.branch // ""')"
      run_tpl "$repo" "$kc" "$(render_env "$(jq -r '.down' "$cfg")" "$team" "$cluster" "$http" "$https" "$br" "$kc")" >&2 ||
        { "$registry" env-set "$team" state=Failed >/dev/null; die "down failed for $cluster; slot kept"; }
    fi
    rm -rf "$(env_dir "$team")"
    "$registry" env-release "$team"
    echo "fleet: $cluster down; slot freed"
    ;;
  status)
    if [ -n "${1:-}" ]; then "$registry" env-get "$1" || echo '{}'; exit 0; fi
    "$registry" list --envs | jq -r '
      (["TEAM", "CLUSTER", "STATE", "SLOT", "HTTP", "HTTPS"] | @tsv),
      (to_entries[] | [.key, .value.cluster, .value.state, (.value.slot // "-"), (.value.http_port // "-"), (.value.https_port // "-")] | map(tostring) | @tsv)' |
      column -t -s $'\t'
    ;;
  *) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
