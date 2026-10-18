#!/usr/bin/env bash
# One Orchestrator tick: everything that changed since the last tick, as one JSON array.
# A quiet tick prints nothing and exits 0; the Orchestrator's whole reply to it is one line.
# Supersedes watch.sh for the Orchestrator loop (watch.sh stays for humans).
#
#   tick.sh [--team T]
#
# Events (each has type, team, name; url where a PR exists). Each is reported once; what has
# been reported lives in $FLEET_STATE_DIR/tick.state.json.
#   stalled, dead   status.sh says Stalled or Zombie, on the transition only
#   escalation      an open escalation not yet reported (key name|at|severity)
#   pr_ready        the row's PR is open, mergeable, checks green (or none exist and the repo is in
#                   no_pr_ci in config.toml), the tester's signed-off SHA is the PR head, and the
#                   body has no "DO NOT MERGE", "merge order" or "before/after". Once per (PR, head SHA).
#   pr_merged       the row's PR was merged; the Orchestrator answers with next.sh. Once per PR.
#   repo_without_team  a repo in config.toml `repos` with no live team, when it becomes so
#   disk, disk_ok   free disk crossed below warn_free_gb, and recovered
#   claim_takeover  reserved (claims land in a later slice)
# PR state is read with `gh pr view` (FLEET_GH), read-only. A gh failure for one PR is logged on
# stderr and skips that PR for this tick; no gh on PATH is one warning and no PR events.
set -euo pipefail
. "$(dirname "$0")/common.sh"
require_herdr
registry="$FLEET_SCRIPTS/registry.sh"

team=""
while [ $# -gt 0 ]; do
  case "$1" in
    --team) team="${2:?--team needs a name}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

state="$(tick_state)"
events="[]"
add_events() { events="$(jq -cn --argjson a "$events" --argjson b "$1" '$a + $b')"; }

# Source hooks the claims slice fills in.
heartbeat() { :; }
claims_taken_over() { :; }
heartbeat
claims_taken_over

# --- stalled / dead -------------------------------------------------------------------------
targs=(); [ -n "$team" ] && targs=(--team "$team")
if rows="$("$FLEET_SCRIPTS/status.sh" ${targs[@]+"${targs[@]}"} --json 2>/dev/null)" && printf '%s' "$rows" | jq -e 'type == "array"' >/dev/null 2>&1; then
  add_events "$(jq -cn --argjson rows "$rows" --argjson st "$state" '
    [$rows[] | select(.tier != "Orchestrator" and (.status == "Stalled" or .status == "Zombie") and (($st.status // {})[.name] != .status))
      | {type: (if .status == "Zombie" then "dead" else "stalled" end), team, name, status}
        + (if (.pr // "") != "" then {url: .pr} else {} end)]')"
  state="$(jq -cn --argjson st "$state" --argjson rows "$rows" '$st + {status: (($st.status // {}) + ([$rows[] | {(.name): .status}] | add // {}))}')"
else
  warn "status.sh failed; no stalled/dead events this tick"
fi

# --- escalations ------------------------------------------------------------------------------
esc="$("$registry" escalations --open ${team:+--team "$team"})"
add_events "$(jq -cn --argjson e "$esc" --argjson st "$state" '
  [$e[] | select(((.name + "|" + .at + "|" + .severity) as $k | ($st.escalations_emitted // []) | index($k)) == null)
    | {type: "escalation", team, name, severity, message, at}]')"
state="$(jq -cn --argjson st "$state" --argjson e "$esc" '
  $st + {escalations_emitted: ((($st.escalations_emitted // []) + [$e[] | .name + "|" + .at + "|" + .severity]) | unique)}')"

# --- pull requests ----------------------------------------------------------------------------
prs="$("$registry" list ${team:+--team "$team"} | jq -c '
  [.[] | select(.status != "Retired" and (.pr // "") != "")]
  | group_by(.pr) | map({pr: .[0].pr, team: .[0].team, name: .[0].name, repo: (.[0].repo // ""),
      signoff: ([.[] | select(.signoff != null) | .signoff.sha] | first // null)})')"
if [ "$(printf '%s' "$prs" | jq length)" != 0 ]; then
  if ! command -v "$FLEET_GH" >/dev/null 2>&1; then
    warn "$FLEET_GH not found; no PR events this tick"
  else
    no_ci="$(config_list no_pr_ci)"
    while IFS= read -r p; do
      url="$(printf '%s' "$p" | jq -r .pr)"
      if ! j="$(forge_pr_json "$url" 2>"${TMPDIR:-/tmp}/fleet-tick-gh.$$")"; then
        warn "gh could not read $url: $(head -1 "${TMPDIR:-/tmp}/fleet-tick-gh.$$")"; rm -f "${TMPDIR:-/tmp}/fleet-tick-gh.$$"; continue
      fi
      rm -f "${TMPDIR:-/tmp}/fleet-tick-gh.$$"
      if ! printf '%s' "$j" | jq -e 'type == "object" and (.state | type == "string")' >/dev/null 2>&1; then
        warn "gh returned no PR state for $url"; continue
      fi
      ev="$(jq -cn --argjson p "$p" --argjson g "$j" --argjson st "$state" --argjson noci "$no_ci" '
        ($p.repo | split("/") | last) as $base
        | ($p.pr | sub("^https?://[^/]+/"; "") | sub("/(pull|merge_requests)/.*$"; "")) as $slug
        | (($noci | index($base)) != null or ($noci | index($slug)) != null or ($noci | index($p.repo)) != null) as $nociok
        | ($g.statusCheckRollup // []) as $checks
        | ($checks | map(if .__typename == "StatusContext" or (.conclusion == null and .state != null)
              then (if .state == "SUCCESS" then "ok" elif (.state == "PENDING" or .state == "EXPECTED") then "pending" else "red" end)
              else (if .status != "COMPLETED" then "pending"
                    elif (.conclusion | IN("SUCCESS", "NEUTRAL", "SKIPPED")) then "ok" else "red" end) end)) as $cs
        | (if ($cs | length) == 0 then (if $nociok then "none" else "unknown" end)
           elif ($cs | index("red")) then "red" elif ($cs | index("pending")) then "pending" else "green" end) as $ci
        | ($p.signoff // "" | ascii_downcase) as $so | ($g.headRefOid // "" | ascii_downcase) as $head
        | ($so != "" and $head != "" and ($head | startswith($so))) as $signed
        | (($g.body // "") | test("DO NOT MERGE|merge order|before/after"; "i")) as $held
        | if $g.state == "MERGED" then
            (if (($st.pr_merged_emitted // []) | index($p.pr)) == null then {type: "pr_merged", team: $p.team, name: $p.name, url: $p.pr} else null end)
          elif $g.state == "OPEN" and $g.mergeable == "MERGEABLE" and ($ci == "green" or $ci == "none") and $signed and ($held | not)
               and (($st.pr_ready_emitted // []) | index($p.pr + "@" + $head)) == null
          then {type: "pr_ready", team: $p.team, name: $p.name, url: $p.pr, sha: $head, ci: $ci}
          else null end')"
      [ "$ev" != "null" ] || continue
      add_events "[$ev]"
      case "$(printf '%s' "$ev" | jq -r .type)" in
        pr_merged) state="$(jq -cn --argjson st "$state" --arg u "$url" '$st + {pr_merged_emitted: ((($st.pr_merged_emitted // []) + [$u]) | unique)}')" ;;
        pr_ready) state="$(jq -cn --argjson st "$state" --argjson e "$ev" '$st + {pr_ready_emitted: ((($st.pr_ready_emitted // []) + [$e.url + "@" + $e.sha]) | unique)}')" ;;
      esac
    done < <(printf '%s' "$prs" | jq -c '.[]')
  fi
fi

# --- repos without a team ---------------------------------------------------------------------
live="$("$registry" list --live | jq -c '[.[] | select(.tier != "Orchestrator") | .repo // ""]')"
bare="$(jq -cn --argjson r "$(config_list repos)" --argjson live "$live" '
  [$r[] | . as $x | select(([$live[] | select(. == $x or (split("/") | last) == ($x | split("/") | last))] | length) == 0)]')"
add_events "$(jq -cn --argjson b "$bare" --argjson st "$state" '
  [$b[] | select((($st.repo_idle_emitted // []) | index(.)) == null) | {type: "repo_without_team", team: "", name: ., repo: .}]')"
state="$(jq -cn --argjson st "$state" --argjson b "$bare" '$st + {repo_idle_emitted: $b}')"

# --- disk ---------------------------------------------------------------------------------------
if free="$(free_gb)"; then
  warn_at="$(warn_free_gb)"; was="$(printf '%s' "$state" | jq -r '.disk // "ok"')"; now_d=ok
  [ "$free" -ge "$warn_at" ] || now_d=low
  if [ "$now_d" != "$was" ]; then
    add_events "$(jq -cn --arg t "$([ "$now_d" = low ] && echo disk || echo disk_ok)" --argjson f "$free" --argjson w "$warn_at" \
      '[{type: $t, team: "", name: "disk", free_gb: $f, warn_free_gb: $w}]')"
  fi
  state="$(jq -cn --argjson st "$state" --arg d "$now_d" '$st + {disk: $d}')"
fi

tick_state_write "$state"
[ "$(printf '%s' "$events" | jq length)" = 0 ] || printf '%s\n' "$events"
