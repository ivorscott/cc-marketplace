#!/usr/bin/env bash
# The merge queue: the open PRs the fleet holds, the ones ready to merge in the order to merge them. It is rebuilt
# from GitHub and the registry on every call, never from chat or a cache. Internal: `status`, the pr_ready and
# pr_merged wakes and the morning report print it through render_queue (references/output.md).
#
#   queue.sh      JSON {ready: [{n, url, pr, issue, machine, why, after}], not_ready: [{url, pr, machine, missing: [...]}], notes: [...]}
#
# Inputs: the registry rows not Retired (Parked and Done rows included), one read-only `gh pr list --state open` per
# repo (FLEET_GH; the repos of the rows' PR URLs and of their own origin remotes), and Linear's `blocks` relations of
# the queued issues (linear.sh blocks; without a key the queue says the Linear order is unknown). Ours is an open PR a
# row names, or one whose head branch a local team pushed (common.sh head_team: the row's branch, fleet/<team>/...,
# or fleet/<issue key>-...), whatever local branch it came from; theirs is any other open fleet/* PR.
# Ready is common.sh PR_DEFS, the rule tick's pr_ready uses: the tester's signed SHA is the head, CI green (or none
# in a no_pr_ci repo), mergeable (UNKNOWN is "mergeable unknown", never conflicting), not a draft, not held. Another
# machine's PR is ready here only when that machine's published summary (linear.sh peers: the `summary=` line of its
# label, `r`) says so and the summary is not older than lease_hours; its sign-off is not ours to see. Otherwise it is
# an order input only, listed as missing "other machine" with its state when the summary has one. One queue for every
# machine: each row has the machine that holds the PR. A ready PR whose changed files another PR, not ready yet, also
# touches says so in its "why".
#
# Order, the first rule that decides:
#   1. dependencies: a PR another needs goes first. Linear `blocks` ("blocks DEV-x"), the same "Part of <issue>"
#      series by slice, else PR number ("Part of DEV-x, slice n"), a base branch that is another PR's head ("base of
#      #N"), a "Depends on <PR url>" line in the dependent's body ("<repo> #N uses its contract"), a "Merge after #N"
#      (or <PR url>, or "Stacked on") line ("<repo> #N merges after it"). The dependent
#      says "needs <repo> #N". A PR whose dependency is not ready waits ("waits for <repo> #N"); a cycle is named.
#   2. fewest rebases: PRs that share changed files or a migration number (the numeric prefix of a file under a
#      migrations/ directory) go in ascending order of how many others they overlap; the later one gets "rebase
#      after #N", or "renumber migration after #N" for a migration clash.
#   3. oldest first.
set -euo pipefail
. "$(dirname "$0")/common.sh"
[ $# = 0 ] || die "usage: queue.sh"

rows="$("$FLEET_SCRIPTS/registry.sh" list | jq -c '[.[] | select(type == "object" and .status != "Retired" and .tier != "Orchestrator")]')"
rowurls="$(jq -c '[.[] | .pr // "" | strings | select(startswith("https://"))] | unique' <<<"$rows")"
# The repos to read: those of the rows' PR URLs, and of the rows' own repos (their origin remotes), so a PR that no
# row knows yet is found too.
slugs="$({ jq -r '.[] | capture("^https?://[^/]+/(?<s>[^/]+/[^/]+)/").s // empty' <<<"$rowurls"
  jq -r '[.[] | .repo // "" | strings | select(. != "")] | unique[]' <<<"$rows" | while IFS= read -r d; do [ ! -d "$d" ] || repo_slug "$d"; done; } | sort -u)"
if [ -z "$slugs" ] && [ "$rowurls" = "[]" ]; then echo '{"ready":[],"not_ready":[],"notes":[]}'; exit 0; fi
if ! command -v "$FLEET_GH" >/dev/null 2>&1; then
  [ "$rowurls" != "[]" ] || { echo '{"ready":[],"not_ready":[],"notes":[]}'; exit 0; }
  jq -c "$RENDER_DEFS"'{ready: [], not_ready: map({url: ., pr: pr_cell(.), missing: ["GitHub unreadable"]}), notes: ["Merge queue unknown: gh not found"]}' <<<"$rowurls"
  exit 0
fi

# The other machines' summaries (linear.sh peers: read-only; status passes what it already read in FLEET_PEERS_JSON):
# pr URL -> {machine, state, issue, ready} for each PR a fresh summary lists; a stale one lists its PRs not ready.
me="$(machine_key 2>/dev/null || echo local)"
peers="${FLEET_PEERS_JSON:-}"
[ -n "$peers" ] || peers="$("$FLEET_SCRIPTS/linear.sh" peers 2>/dev/null)" || peers='[]'
printf '%s' "$peers" | jq -e 'type == "array"' >/dev/null 2>&1 || peers='[]'
psum="$(jq -c --arg now "${FLEET_NOW:-$(now)}" --argjson lease "$(lease_hours)" '
  [group_by(.machine)[] | map(select(.summary != null)) | select(length > 0) | first | . as $c
    | (if $c.heartbeat == null then false else ((($now | fromdateiso8601) - ($c.heartbeat | fromdateiso8601)) <= ($lease * 3600)) end) as $fresh
    | $c.summary[] | select((.pr // "") != "") | {key: .pr, value: {machine: $c.machine, state: (.s // ""), issue: (.i // ""), ready: ((.r // false) and $fresh)}}] | from_entries' <<<"$peers" 2>/dev/null)" || psum='{}'
[ -n "$psum" ] || psum='{}'

noci="$(config_list no_pr_ci)"; fields=number,url,state,title,headRefOid,headRefName,baseRefName,mergeable,isDraft,statusCheckRollup,body,createdAt,files,isCrossRepository
# One read-only list of the open PRs per repo. A repo GitHub cannot list leaves its rows' PRs "GitHub unreadable".
open='[]'
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  if l="$("$FLEET_GH" pr list --repo "$slug" --state open --limit 200 --json "$fields" 2>/dev/null)" && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$l"; then
    open="$(jq -c --arg s "$slug" --slurpfile l <(printf '%s' "$l") '. + [{slug: $s, ok: true, prs: $l[0]}]' <<<"$open")"
  else open="$(jq -c --arg s "$slug" '. + [{slug: $s, ok: false, prs: []}]' <<<"$open")"; fi
done <<<"$slugs"
# Ours: an open PR a row names, or whose head branch a local team pushed (common.sh head_team), with that team's issue
# and its tester's sign-off. Theirs: the other open fleet/* PRs, as order inputs only ("other machine"). A row's PR
# missing from its repo's open list was merged or closed: it is gone. Fork PRs are never either.
all="$(jq -cn --slurpfile rows <(printf '%s' "$rows") --slurpfile open <(printf '%s' "$open") --argjson urls "$rowurls" --argjson noci "$noci" --argjson psum "$psum" --arg me "$me" "$PR_DEFS$HEAD_TEAM_JQ"'
  $rows[0] as $rows | $open[0] as $open
  | def entry($t; $url): [$rows[] | select(.team == $t)] as $g | {url: $url, team: $t,
      repo_dir: ([$g[] | .repo // empty | select(. != "")] | first // ""),
      issue: ([$g[] | .issue // empty | select(. != "")] | first // ""), issue_url: ([$g[] | .issue_url // empty | select(. != "")] | first // ""),
      issue_title: ([$g[] | .issue_title // empty | select(. != "")] | first // ""),
      signoff: ([$g[] | select((.name | endswith("/tester")) and ((.signoff | objects | .sha) != null) and ((.signoff.pr // .pr // "") == $url))
        | .signoff.sha] | first // "")};
  def gh_fields: {number, title: (.title // ""), head: (.headRefName // ""), base: (.baseRefName // ""), body: (.body // ""),
      created: (.createdAt // ""), files: [(.files // [])[] | .path // empty]};
  ([$open[] | select(.ok) | .slug]) as $readable
  | [$open[] | select(.ok) | .prs[]? | select(type == "object" and (.isCrossRepository // false) != true) | . as $g
      | (if ($urls | index($g.url)) != null then ([$rows[] | select(.pr == $g.url) | .team] | first) else ($g.headRefName // "" | head_team($rows)) end) as $t
      | if $t != null then entry($t; $g.url) as $p
          | $p + ($g | gh_fields) + {other: false, machine: $me, missing: ($g | pr_missing($p.signoff; pr_noci_ok($noci; $p.repo_dir; $p.url)))}
        elif ($g.headRefName // "" | startswith("fleet/")) then ($psum[$g.url]) as $ps
          | {url: $g.url, team: "", issue: ($ps.issue // ""), issue_url: "", issue_title: ""} + ($g | gh_fields)
            + {other: true, machine: ($ps.machine // "other machine"),
               missing: (if $ps.ready == true then [] else ["other machine" + (if ($ps.state // "") != "" then " (\($ps.state))" else "" end)] end)}
        else empty end]
  + [$urls[] | select((capture("^https?://[^/]+/(?<s>[^/]+/[^/]+)/").s // "") as $s | ($readable | index($s)) == null) | . as $u
      | entry([$rows[] | select(.pr == $u) | .team] | first; $u)
        + {number: (($u | capture("/(?<n>[0-9]+)$").n | tonumber) // 0), title: "", head: "", base: "", body: "", created: "", files: [], other: false, machine: $me, missing: ["GitHub unreadable"]}]')"

# Linear: which queued issue blocks which (one read for all of them).
blocks='{}'; notes='[]'
issues="$(jq -r '[.[] | select(.other | not) | .issue | select(. != "")] | unique | .[]' <<<"$all")"
if [ "$(jq length <<<"$all")" -ge 2 ] && [ -n "$issues" ]; then
  # shellcheck disable=SC2086
  if b="$("$FLEET_SCRIPTS/linear.sh" blocks $issues 2>/dev/null)" && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$b"; then blocks="$b"
  else notes='["Linear order unknown (no key)"]'; fi
fi

jq -c --argjson notes "$notes" --slurpfile blocks <(printf '%s' "$blocks") "$RENDER_DEFS$PART_OF_JQ$PR_DEFS"'$blocks[0] as $blocks |
  def repo: .url | capture("^https?://[^/]+/[^/]+/(?<r>[^/]+)/").r // "?";
  def ref: "\(repo) #\(.number)";
  def series: (.body | part_of); # "Part of DEV-7", its tracker URL, or a markdown link to it (common.sh)
  def slice: ((.title + " " + .body) | [match("(?i)slice\\s*([0-9]+)").captures[0].string | tonumber] | first // null);
  def migs: [.files[] | select(test("(^|/)migrations/")) | (split("/") | last | capture("^(?<m>[0-9]+)").m // empty)] | unique;
  . as $all
  # dependency edges {from, to, why_from}: from goes first
  | ([range(0; $all | length) as $i | range(0; $all | length) as $j | select($i != $j) | $all[$i] as $a | $all[$j] as $b
      | (if $a.issue != "" and $b.issue != "" and (($blocks[$a.issue] // []) | index($b.issue)) != null then "blocks \($b.issue)"
         elif ($a | series) != null and ($a | series) == ($b | series) and ([($a | slice // $a.number), ($b | slice // $b.number)] | .[0] < .[1])
           then "Part of \($a | series), slice \($a | slice // $a.number)"
         elif $a.head != "" and $b.base == $a.head then "base of #\($b.number)"
         elif ($b.body | test("(?im)^\\s*depends on\\s+" + ($a.url | gsub("[.]"; "\\.")) + "(?![0-9])")) then "\($b | ref) uses its contract"
         elif (($b | pr_after($b.url)) | index($a.url)) != null then "\($b | ref) merges after it"
         else empty end) as $why | {from: $i, to: $j, why: $why}]) as $edges
  | def has($set; $v): ($set | index($v)) != null;
  # Kahn over every PR, to find a cycle; the PRs left over are in one
  (def kahn($e; $left): ([$left[] | . as $n | select(([$e[] | select(.to == $n and has($left; .from))] | length) == 0)]) as $free
       | if ($free | length) == 0 then $left else kahn($e; $left - $free) end;
     kahn($edges; [range(0; $all | length)])) as $cyclic
  # blocked: not ready itself, in a cycle, or behind a blocked PR (transitively)
  | (def spread($b): ([range(0; $all | length) | . as $n | select((has($b; $n) | not) and ([$edges[] | select(.to == $n and has($b; .from))] | length) > 0)]) as $new
       | if ($new | length) == 0 then $b else spread($b + $new) end;
     spread([range(0; $all | length) | select(($all[.].missing | length) > 0 or has($cyclic; .))])) as $blocked
  | [range(0; $all | length) | . as $i | $all[$i] + {i: $i,
      waits: ([$edges[] | select(.to == $i and has($blocked; .from)) | $all[.from] | ref] | unique),
      cycle: (if has($cyclic; $i) then ([$edges[] | select(.to == $i and has($cyclic; .from)) | "#\($all[.from].number)"] | first) else null end)}] as $nodes
  | [$nodes[] | select(has($blocked; .i) | not)] as $ready
  | ($ready | map(.i)) as $rids
  # overlap degree among the ready ones: shared files or a shared migration number
  | ($ready | map(. as $x | {key: (.i | tostring), value: [$ready[] | select(.i != $x.i and repo == ($x | repo) and ((([.files[]] - ([.files[]] - $x.files)) | length) > 0 or (((. | migs) - ((. | migs) - ($x | migs))) | length) > 0)) | .i]}) | from_entries) as $ov
  # greedy: among the PRs whose ready dependencies are placed, the one with the fewest overlaps, then the oldest
  | (def place($left; $out): if ($left | length) == 0 then $out else
        ([$left[] | . as $n | select(([$edges[] | select(.to == $n and has($left; .from))] | length) == 0)]
          | map($nodes[.]) | sort_by(($ov[.i | tostring] | length), .created, .number) | first) as $pick
        | place($left - [$pick.i]; $out + [$pick.i]) end;
     place($rids; [])) as $order
  | {ready: [range(0; $order | length) as $k | $nodes[$order[$k]] as $x | ($order[0:$k]) as $before
      | ([$edges[] | select(.from == $x.i and has($rids; .to)) | .why] | first) as $dependents
      | ([$edges[] | select(.to == $x.i) | $all[.from] | "needs \(ref)"] | first) as $needs
      | ([$before[] | . as $b | select((($x | migs) - (($x | migs) - ($nodes[$b] | migs))) | length > 0) | "#\($nodes[$b].number)"]) as $renum
      | ([$before[] | . as $b | select(($ov[$x.i | tostring] | index($b)) != null or ([$edges[] | select(.from == $b and .to == $x.i and (.why | startswith("base of")))] | length) > 0)
          | "#\($nodes[$b].number)"] - $renum) as $rebase
      | ([$nodes[] | select((.i | IN($rids[]) | not) and repo == ($x | repo) and ((([.files[]] - ([.files[]] - $x.files)) | length) > 0)) | ref]) as $notyet
      | {n: ($k + 1), url: $x.url, pr: pr_cell($x.url), issue: issue_cell($x.issue; $x.issue_url; $x.issue_title), machine: $x.machine,
         why: (($dependents // $needs // (if ($ov[$x.i | tostring] | length) > 0 then "fewest rebases" else "oldest first" end))
               + (if ($notyet | length) > 0 then "; touches the same files as \($notyet | join(", ")) (not ready yet)" else "" end)),
         after: (if ($renum | length) > 0 then "renumber migration after \($renum | join(", "))"
                 elif ($rebase | length) > 0 then "rebase after \($rebase | join(", "))" else "—" end)}],
     not_ready: [$nodes[] | select((.missing | length) > 0 or (.waits | length) > 0 or .cycle != null)
      | {url, pr: pr_cell(.url), machine, missing: (.missing + (.waits | map("waits for " + .)) + (if .cycle != null then ["dependency cycle with \(.cycle)"] else [] end))}],
     notes: $notes}' <<<"$all"
