#!/usr/bin/env bash
# What the fleet did, from the event log and the agents' Claude Code transcripts.
#
#   metrics.sh [--since 7d] [--json]
#   metrics.sh --morning [--since 12h]
#
# --morning prints the morning report of overnight mode instead (tick writes it to reports/fleet-morning-<date>.md):
# six sections in a fixed order, one line per entry and "none" for an empty one (references/output.md): Ready to
# merge (the merge queue as it is now), Decisions taken (the leads' decision notes), UNVERIFIED (lines of the done
# summaries), Takeovers (claims taken from us, lapsed claims released), Boots (with the search that picked each issue)
# and Merge-order conflicts (pr_conflicting events, and PRs that conflict now).
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
# Reads $FLEET_STATE_DIR/events.jsonl and the registry. The reply is the weekly table, | Week | Issues shipped | PRs |
# Rework | Median cycle |, then "Report: <path>": reports/fleet-metrics-<date>.md (common.sh report_dir), which holds
# that table and one row per PR. --json prints the per-PR rows instead and writes nothing.
# UNVERIFIED: the transcript line shape (`.timestamp`, `.type == "assistant"`, `.message.usage`).
# Command: Show per-PR metrics from the event log · e.g. fleet metrics --since 7d
set -euo pipefail
. "$(dirname "$0")/common.sh"

since=""; json=false; morning=false
while [ $# -gt 0 ]; do
  case "$1" in
    --since) since="${2:?--since needs a value like 7d}"; shift 2 ;;
    --json) json=true; shift ;;
    --morning) morning=true; shift ;;
    *) die "unknown option: $1" ;;
  esac
done
[ -n "$since" ] || { if $morning; then since=12h; else since=7d; fi; }
n="${since%[dhm]}"; unit="${since#"$n"}"
case "$n" in "" | *[!0-9]*) die "--since must look like 7d, 12h or 30m: $since" ;; esac
case "$unit" in d) secs=$((n * 86400)) ;; h) secs=$((n * 3600)) ;; m) secs=$((n * 60)) ;; *) die "--since must look like 7d, 12h or 30m: $since" ;; esac

now_iso="${FLEET_NOW:-$(now)}"
now_epoch="$(jq -rn --arg t "$now_iso" '$t | fromdateiso8601')"
cutoff="$(jq -rn --argjson e "$((now_epoch - secs))" '$e | todate')"
f="$(events_file)"
events='[]'; [ ! -s "$f" ] || events="$(jq -sc --arg c "$cutoff" '[.[] | select(.at >= $c)]' "$f")"

# The morning report: each section a heading, then its lines (or "none"), a blank line between blocks.
section() { printf '\n## %s\n\n%s\n' "$1" "${2:-none}"; }
if $morning; then
  rows="$("$FLEET_SCRIPTS/registry.sh" list --with-archived 2>/dev/null || echo '[]')"
  q="$("$FLEET_SCRIPTS/queue.sh" 2>/dev/null)" || q='{"ready":[],"not_ready":[],"notes":[]}'
  printf '# Morning report %s\n' "$(local_time "$now_epoch" %Y-%m-%d)"
  section "Ready to merge" "$(render_queue "$q")"
  section "Decisions taken" "$(jq -r --arg c "$cutoff" "$RENDER_DEFS"'.[] | .name as $n | (.notes // [])[]
    | select(.kind == "decision" and (.at // "") >= $c) | "- \($n | md): \(.message | md)"' <<<"$rows")"
  section "UNVERIFIED" "$(jq -r --arg c "$cutoff" "$RENDER_DEFS"'.[] | select((.updated_at // "") >= $c) | .name as $n
    | (.summary // "") | split("\n")[] | split("; ")[] | select(test("UNVERIFIED")) | "- \($n | md): \(. | md)"' <<<"$rows")"
  section "Takeovers" "$(jq -r '.[] | select(.type == "claim_takeover" or .type == "claim_released" or .type == "claim_lost")
    | ((.detail // "") | sub("^holder "; "") | split(": ")[0]) as $h
    | if .type == "claim_takeover" then "- \(.issue // "?"): taken over by \($h)"
      elif .type == "claim_lost" then "- \(.issue // "?"): this machine'"'"'s claim was released by another machine (\(.team // "?"))"
      else "- \(.issue // "?"): released from \($h) (heartbeat lapsed, no open PR)" end' <<<"$events")"
  section "Boots" "$(jq -r --argjson rows "$rows" '.[] | select(.type == "boot") | .team as $t
    | ([$rows[] | select(.name == ($t + "/lead")) | (.notes // [])[] | select(.kind == "picked") | .message] | last) as $why
    | "- \($t)\(if (.issue // "") != "" then " on " + .issue else "" end): \($why // "named by the user")"' <<<"$events")"
  section "Merge-order conflicts" "$( { jq -r "$RENDER_DEFS"'.[] | select(.type == "pr_conflicting")
      | ((.detail // "") | sub("^after "; "") | split(", ") | map(select(test("^https?://\\S+/[0-9]+$")) | pr_cell(.)) | join(", ")) as $after
      | "- \(pr_cell(.pr)): conflicts \(if $after == "" then "with main" else "after " + $after end)"' <<<"$events"
    jq -r '.not_ready[] | select((.missing | index("conflicting")) != null) | "- \(.pr): conflicting now"' <<<"$q"; } )"
  exit 0
fi

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
if [ "$(printf '%s' "$out" | jq length)" = 0 ]; then render_line no_prs since="$since"; exit 0; fi
# The reply is the weekly table; the report file holds it and one row per PR.
weekly="$(render_metrics "$out")"
report="$(report_dir)/fleet-metrics-${now_iso:0:10}.md"
mkdir -p "$(dirname "$report")" || die "cannot create $(dirname "$report")"
{ printf '# Fleet metrics, the last %s to %s\n\n%s\n\n' "$since" "${now_iso:0:10}" "$weekly"
  render_metrics_prs "$out"; } >"$report" || die "cannot write $report"
reply "$weekly" "$(render_line report path="$report")"
