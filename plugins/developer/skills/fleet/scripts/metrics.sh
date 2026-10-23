#!/usr/bin/env bash
# What the fleet did, from the event log and the agents' Claude Code transcripts.
#
#   metrics.sh [--since 7d] [--json]
#
# --since takes Nd (days), Nh (hours) or Nm (minutes); default 7d. One row per PR seen in the window:
#   ready_minutes   from the team's last `boot`/`next` before the PR's first `pr_ready` to that event
#   rework_rounds   distinct head SHAs among the PR's `pr_ready` and `signoff` events, minus one (SHAs are
#                   lowercased, and a short SHA counts as the full one it is a prefix of)
#   stalls          `stalled` events for the team between its start and the PR's end
#   missed_messages `brief_failed` events for the team in the window
#   tokens          input + cache read + cache creation + output tokens of every assistant turn in
#                   the team's transcripts (only the session files on the team's rows, live and archived:
#                   each `transcript` and the earlier ones in `transcripts`) between the PR's start and
#                   its merge (or now); lines are parsed one at a time and unparsable ones skipped
# Reads $FLEET_STATE_DIR/events.jsonl and the registry; writes nothing.
# UNVERIFIED: the transcript line shape (`.timestamp`, `.type == "assistant"`, `.message.usage`).
# Command: Show per-PR metrics from the event log · e.g. fleet metrics --since 7d
set -euo pipefail
. "$(dirname "$0")/common.sh"

since="7d"; json=false
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="${2:?--since needs a value like 7d}"; shift 2 ;;
    --json) json=true; shift ;;
    *) die "unknown option: $1" ;;
  esac
done
n="${since%[dhm]}"; unit="${since#"$n"}"
case "$n" in "" | *[!0-9]*) die "--since must look like 7d, 12h or 30m: $since" ;; esac
case "$unit" in d) secs=$((n * 86400)) ;; h) secs=$((n * 3600)) ;; m) secs=$((n * 60)) ;; *) die "--since must look like 7d, 12h or 30m: $since" ;; esac

now_iso="${FLEET_NOW:-$(now)}"
now_epoch="$(jq -rn --arg t "$now_iso" '$t | fromdateiso8601')"
cutoff="$(jq -rn --argjson e "$((now_epoch - secs))" '$e | todate')"
f="$(events_file)"
events='[]'; [ ! -s "$f" ] || events="$(jq -sc --arg c "$cutoff" '[.[] | select(.at >= $c)]' "$f")"

prs="$(printf '%s' "$events" | jq -c --argjson now "$now_epoch" '
  def ep: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
  . as $ev
  | [$ev[] | select(.pr != null) | .pr] | unique
  | map(. as $pr
    | ([$ev[] | select(.pr == $pr)]) as $mine
    | ($mine | map(select(.team != null) | .team) | first // "") as $team
    | ([$mine[] | select(.type == "pr_ready")] | first) as $ready
    | ([$mine[] | select(.type == "pr_merged")] | first) as $merged
    | (if $ready == null then null else
        ([$ev[] | select(.team == $team and (.type == "boot" or .type == "next") and .at <= $ready.at)] | last // null) end) as $start
    | ($start.at // ($mine[0].at)) as $start_at
    | ($merged.at // ($now | todate)) as $end_at
    | {pr: $pr, team: $team, issue: ([$ev[] | select(.team == $team and .issue != null) | .issue] | last // null),
       started_at: $start_at, ready_at: ($ready.at // null), merged_at: ($merged.at // null), end_at: $end_at,
       ready_minutes: (if $ready == null then null else ((($ready.at | ep) - ($start_at | ep)) / 60 | floor) end),
       rework_rounds: ([$mine[] | select((.type == "pr_ready" or .type == "signoff") and .sha != null) | .sha | ascii_downcase] | unique
         | . as $all | [.[] | . as $s | select([$all[] | select(. != $s and startswith($s))] | length == 0)]
         | length | (if . > 0 then . - 1 else 0 end)),
       stalls: ([$ev[] | select(.type == "stalled" and .team == $team and .at >= $start_at and .at <= $end_at)] | length),
       missed_messages: ([$ev[] | select(.type == "brief_failed" and .team == $team)] | length)})')"

# tokens per PR from the team's transcripts
tokens_for() { # tokens_for <team> <from ISO> <to ISO>
  local list t files=()
  list="$("$FLEET_SCRIPTS/registry.sh" list --team "$1" --with-archived 2>/dev/null | jq -r '.[] | ((.transcript // empty), (.transcripts // [] | if type == "array" then .[] else empty end)) | select(type == "string")' | sort -u)" || list=""
  while IFS= read -r t; do
    [ -f "$t" ] && files+=("$t")
  done <<<"$list"
  [ "${#files[@]}" -gt 0 ] || { echo 0; return 0; }
  for t in "${files[@]}"; do cat "$t"; echo; done 2>/dev/null | jq -Rn --arg a "$2" --arg b "$3" '
    def ep: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    [inputs | (fromjson? // empty) | select(type == "object")
      | select(.type == "assistant" and (.timestamp | type == "string") and (.message.usage | type == "object"))
      | select((.timestamp | ep) >= ($a | ep) and (.timestamp | ep) <= ($b | ep))
      | .message.usage | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.output_tokens // 0)]
    | add // 0' 2>/dev/null || echo 0
}
out='[]'
while IFS= read -r p; do
  [ -n "$p" ] || continue
  tk="$(tokens_for "$(printf '%s' "$p" | jq -r .team)" "$(printf '%s' "$p" | jq -r .started_at)" "$(printf '%s' "$p" | jq -r .end_at)")"
  out="$(jq -cn --argjson o "$out" --argjson p "$p" --argjson t "${tk:-0}" '$o + [$p + {tokens: $t}]')"
done < <(printf '%s' "$prs" | jq -c '.[]')

if $json; then printf '%s\n' "$out"; exit 0; fi
if [ "$(printf '%s' "$out" | jq length)" = 0 ]; then printf 'no PRs in the last %s\n' "$since"; exit 0; fi
printf '%s' "$out" | jq -r '(["PR", "TEAM", "READY_MIN", "REWORK", "STALLS", "MISSED", "TOKENS"] | @tsv),
  (.[] | [.pr, .team, (.ready_minutes // "-"), .rework_rounds, .stalls, .missed_messages, .tokens] | map(tostring) | @tsv)' | column -t -s $'\t'
