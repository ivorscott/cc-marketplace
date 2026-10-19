#!/usr/bin/env bash
# Starting an agent in a pane, shared by boot.sh and respawn.sh. Source it; don't run it.
# The sourcing script sets these globals first: team, task, repo, registry (the registry.sh path),
# tool_allow (JSON array of tracker/forge allow entries) and, per start, session_id (optional,
# becomes `claude --session-id`). Needs common.sh already sourced.

render() { # render <text> <name> <worktree> <workers>
  local s="$1"
  s="${s//\{\{team\}\}/$team}"; s="${s//\{\{task\}\}/$task}"; s="${s//\{\{repo\}\}/$repo}"
  s="${s//\{\{name\}\}/$2}"; s="${s//\{\{name_slug\}\}/${2//\//-}}"; s="${s//\{\{worktree\}\}/$3}"
  s="${s//\{\{workers\}\}/$4}"; s="${s//\{\{registry\}\}/$registry}"; s="${s//\{\{scripts\}\}/$FLEET_SCRIPTS}"
  s="${s//\{\{issue_url\}\}/${issue_url:-<the full URL of the issue>}}"
  printf '%s' "$s"
}

claude_args() { # claude_args <model> <tier> <worktree> <allow-json>
  local settings extra="${4:-[]}" herdr_allow='["Bash(herdr agent get:*)", "Bash(herdr agent read:*)", "Bash(herdr agent list:*)", "Bash(herdr agent wait:*)"]'
  # Leads drive their own workers; fleet-bash-guard.sh holds them to their own team.
  [ "$2" != "Lead" ] || herdr_allow='["Bash(herdr agent get:*)", "Bash(herdr agent read:*)", "Bash(herdr agent list:*)", "Bash(herdr agent wait:*)", "Bash(herdr agent prompt:*)", "Bash(herdr agent send-keys:*)"]'
  extra="${extra//\{\{scripts\}\}/$FLEET_SCRIPTS}"
  extra="${extra//\{\{team\}\}/$team}"; extra="${extra//\{\{worktree\}\}/$3}"
  settings="$(jq -cn --arg r "$registry" --argjson extra "$extra" --argjson tools "$tool_allow" --argjson h "$herdr_allow" \
    '{permissions: {allow: (["Bash(\($r):*)"] + $h + $extra + $tools | unique)}}')"
  printf '%s\0' --settings "$settings"
  [ -n "$1" ] && printf '%s\0' --model "$1"
  [ "$2" = "Lead" ] && printf '%s\0' --agent developer:lead
  # perm_mode is checked up front by the caller (boot, respawn): a mode that turns checks off never gets here.
  printf '%s\0' --permission-mode "${perm_mode:-$(permission_mode)}"
  # --session-id pins the transcript file name, so the row can record where the agent's
  # transcript is (tell.sh and next.sh read it). boot sets session_id just before each start.
  [ -z "${session_id:-}" ] || printf '%s\0' --session-id "$session_id"
}

# Answer Claude's folder-trust dialog, but only for directories this boot owns or was
# given (the repo and our worktrees). The default option is "No, exit", so read the
# cursor position before pressing Enter.
answer_trust() { # answer_trust <agent>
  local i screen
  for i in 1 2 3 4; do
    screen="$(hd agent read "$1" --source visible 2>/dev/null || true)"
    case "$screen" in *"trust this folder"*) ;; *) return 0 ;; esac
    if printf '%s' "$screen" | grep -q '❯ *Yes, I trust this folder'; then
      hd agent send-keys "$1" enter >/dev/null; sleep 1; return 0
    fi
    hd agent send-keys "$1" down >/dev/null; sleep 0.3
  done
  return 1
}

alive() { # the pane runs something other than its shell (gotcha: idle can mean "exited")
  hd pane process-info --pane "$1" 2>/dev/null |
    jq -e '.result.process_info | .foreground_process_group_id != .shell_pid' >/dev/null
}

# scrub_cmd: the line typed into an agent's pane shell before the agent starts. herdr starts the canonical
# `claude`, so `env -u` cannot prefix it: the shell drops the variables first, and the harness and every Bash
# call it makes start without them. The Linear key, the AWS credentials and profile, and anything named in
# config scrub_env are unset; the AWS shared files point at /dev/null; KUBECONFIG is /dev/null unless the
# pane got the team's own (.../env/<team>/kubeconfig). Always on: there is no switch to turn it off.
scrub_cmd() {
  local extra
  extra="$(config_list scrub_env | jq -r '.[] | select(test("^[A-Za-z_][A-Za-z0-9_]*$"))' 2>/dev/null | tr '\n' ' ')"
  printf 'unset LINEAR_API_KEY AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN %s; ' "$extra"
  printf 'export AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_CONFIG_FILE=/dev/null; '
  # shellcheck disable=SC2016 # expanded by the pane's shell, not here
  printf '%s' 'case "${KUBECONFIG:-}" in */env/*/kubeconfig) ;; *) export KUBECONFIG=/dev/null ;; esac'
}

start_agent_once() { # start_agent_once <agent> <kind> <pane> <model> <tier> <worktree> <allow-json> → prints status
  local agent="$1" kind="$2" pane="$3" args=() out code tries=0
  # Every kind of harness, not only claude: a codex pane must not keep the key or the cloud credentials either.
  hd pane run "$pane" "$(scrub_cmd)" >/dev/null 2>&1 || warn "could not scrub the environment of pane $pane for $agent; it may still hold credentials"
  if [ "$kind" = "claude" ]; then
    while IFS= read -r -d '' a; do args+=("$a"); done < <(claude_args "$4" "$5" "$6" "${7:-[]}")
  fi
  # A fresh pane isn't "an available shell" until its shell has finished starting up
  # (rc files, prompt hooks), which can take several seconds in a git worktree. Retry
  # agent_pane_busy for up to 30s instead of failing the agent as a Zombie.
  while :; do
    out="$(hd agent start "$agent" --kind "$kind" --pane "$pane" --timeout 60000 -- ${args[@]+"${args[@]}"} 2>&1 || true)"
    code="$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null || true)"
    [ "$code" = "agent_pane_busy" ] && [ $((tries += 1)) -le 30 ] || break
    sleep 1
  done
  if [ "$code" = "agent_not_ready" ]; then
    answer_trust "$agent" || true
  elif [ -n "$code" ]; then
    warn "agent start $agent: $out"; printf 'Zombie'; return 0
  fi
  hd agent wait "$agent" --until idle --timeout 30000 >/dev/null 2>&1 || true
  if ! alive "$pane"; then printf 'Zombie'; return 0; fi
  case "$(hd agent get "$agent" 2>/dev/null | jq -r '.result.agent.agent_status // "unknown"')" in
    blocked) printf 'Needs input' ;;
    *) printf 'Working' ;;
  esac
}

# The start command can be eaten by a shell that is still starting up: an oh-my-zsh update
# prompt reads the first key typed, so `claude` arrives as `laude`. That key is gone once
# consumed, so a second try into the same pane works. Retry once before calling it a Zombie.
start_agent() { # same arguments as start_agent_once
  local status
  status="$(start_agent_once "$@")"
  if [ "$status" = "Zombie" ]; then
    warn "agent $1 did not start; retrying once"
    status="$(start_agent_once "$@")"
  fi
  printf '%s' "$status"
}
