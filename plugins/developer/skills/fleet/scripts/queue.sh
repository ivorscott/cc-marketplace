#!/usr/bin/env bash
# The merge queue: the open PRs the fleet holds, the ones ready to merge in the order to merge them. It is rebuilt
# from GitHub and the registry on every call, never from chat or a cache. Internal: `status`, the pr_ready and
# pr_merged wakes and the morning report print it through render_queue (references/output.md).
#
#   queue.sh      JSON {ready: [{n, url, pr, issue, why, after}], not_ready: [{url, pr, missing: [...]}], notes: [...]}
#
# Inputs: every registry row not Retired that has a PR (Parked and Done rows included), one read-only
# `gh pr view` per PR (FLEET_GH), the other open fleet/* PRs in the same repos (`gh pr list`), and Linear's `blocks`
# relations of the queued issues (linear.sh blocks; without a key the queue says the Linear order is unknown).
# Ready is common.sh PR_DEFS, the rule tick's pr_ready uses: the tester's signed SHA is the head, CI green (or none
# in a no_pr_ci repo), mergeable (UNKNOWN is "mergeable unknown", never conflicting), not a draft, not held. Another
# machine's PR is never ready here (its sign-off is not ours to see): it is an order input, listed as missing
# "other machine".
#
# Order, the first rule that decides:
#   1. dependencies: a PR another needs goes first. Linear `blocks` ("blocks DEV-x"), the same "Part of <issue>"
#      series by slice, else PR number ("Part of DEV-x, slice n"), a base branch that is another PR's head ("base of
#      #N"), a "Depends on <PR url>" line in the dependent's body ("<repo> #N uses its contract"). The dependent
#      says "needs <repo> #N". A PR whose dependency is not ready waits ("waits for <repo> #N"); a cycle is named.
#   2. fewest rebases: PRs that share changed files or a migration number (the numeric prefix of a file under a
#      migrations/ directory) go in ascending order of how many others they overlap; the later one gets "rebase
#      after #N", or "renumber migration after #N" for a migration clash.
#   3. oldest first.
set -euo pipefail
. "$(dirname "$0")/common.sh"
[ $# = 0 ] || die "usage: queue.sh"

prs="$("$FLEET_SCRIPTS/registry.sh" list | jq -c '
  [.[] | select(type == "object" and .status != "Retired" and ((.pr // "") | type) == "string" and ((.pr // "") | startswith("https://")))]
  | group_by(.pr) | map(. as $g | {url: .[0].pr, team: .[0].team, repo_dir: (.[0].repo // ""),
      issue: ([$g[].issue // empty | select(. != "")] | first // ""), issue_url: ([$g[].issue_url // empty | select(. != "")] | first // ""),
      signoff: ([$g[] | select((.name // "" | endswith("/tester")) and ((.signoff | objects | .sha) != null)) | .signoff.sha] | first // "")})')"
if [ "$(jq length <<<"$prs")" = 0 ]; then echo '{"ready":[],"not_ready":[],"notes":[]}'; exit 0; fi
if ! command -v "$FLEET_GH" >/dev/null 2>&1; then
  jq -c "$RENDER_DEFS"'{ready: [], not_ready: map({url, pr: pr_cell(.url), missing: ["GitHub unreadable"]}), notes: ["Merge queue unknown: gh not found"]}' <<<"$prs"
  exit 0
fi

noci="$(config_list no_pr_ci)"; fields=number,url,state,title,headRefOid,headRefName,baseRefName,mergeable,isDraft,statusCheckRollup,body,createdAt,files
# Ours: one view each. A PR GitHub cannot show is not ready ("GitHub unreadable"); a merged or closed one is gone.
all='[]'
while IFS= read -r p; do
  url="$(jq -r .url <<<"$p")"
  if j="$("$FLEET_GH" pr view "$url" --json "$fields" 2>/dev/null)" && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$j"; then
    all="$(jq -c --argjson p "$p" --argjson g "$j" --argjson noci "$noci" "$PR_DEFS"'
      if ($g.state // "OPEN") != "OPEN" then . else
        . + [$p + {number: $g.number, title: ($g.title // ""), head: ($g.headRefName // ""), base: ($g.baseRefName // ""),
          body: ($g.body // ""), created: ($g.createdAt // ""), files: [($g.files // [])[] | .path // empty],
          other: false, missing: ($g | pr_missing($p.signoff; pr_noci_ok($noci; $p.repo_dir; $p.url)))}] end' <<<"$all")"
  else
    all="$(jq -c --argjson p "$p" '. + [$p + {number: (($p.url | capture("/(?<n>[0-9]+)$").n | tonumber) // 0), title: "", head: "", base: "",
      body: "", created: "", files: [], other: false, missing: ["GitHub unreadable"]}]' <<<"$all")"
  fi
done < <(jq -c '.[]' <<<"$prs")
# Theirs: the other open fleet/* PRs in the same repos, as order inputs only.
while IFS= read -r slug; do
  [ -n "$slug" ] || continue
  theirs="$("$FLEET_GH" pr list --repo "$slug" --state open --limit 100 --json number,url,title,headRefName,baseRefName,body,createdAt,files 2>/dev/null)" || continue
  all="$(jq -c --argjson t "$theirs" '. as $a | ($a | map(.url)) as $ours
    | $a + [$t[]? | select((.headRefName // "" | startswith("fleet/")) and ((.url as $u | $ours | index($u)) == null))
        | {url, team: "", issue: "", issue_url: "", number, title: (.title // ""), head: (.headRefName // ""), base: (.baseRefName // ""),
           body: (.body // ""), created: (.createdAt // ""), files: [(.files // [])[] | .path // empty], other: true, missing: ["other machine"]}]' <<<"$all" 2>/dev/null)" || true
done < <(jq -r '.[] | select(.other | not) | .url | capture("^https?://[^/]+/(?<s>[^/]+/[^/]+)/").s // empty' <<<"$all" | sort -u)

# Linear: which queued issue blocks which (one read for all of them).
blocks='{}'; notes='[]'
issues="$(jq -r '[.[] | select(.other | not) | .issue | select(. != "")] | unique | .[]' <<<"$all")"
if [ "$(jq length <<<"$all")" -ge 2 ] && [ -n "$issues" ]; then
  # shellcheck disable=SC2086
  if b="$("$FLEET_SCRIPTS/linear.sh" blocks $issues 2>/dev/null)" && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$b"; then blocks="$b"
  else notes='["Linear order unknown (no key)"]'; fi
fi

jq -c --argjson notes "$notes" --argjson blocks "$blocks" "$RENDER_DEFS"'
  def repo: .url | capture("^https?://[^/]+/[^/]+/(?<r>[^/]+)/").r // "?";
  def ref: "\(repo) #\(.number)";
  def series: (.body | [match("(?i)part of\\s+(?:https?://\\S+/issue/)?([A-Za-z][A-Za-z0-9]*-[0-9]+)").captures[0].string] | first // null | if . then ascii_upcase else . end);
  def slice: ((.title + " " + .body) | [match("(?i)slice\\s*([0-9]+)").captures[0].string | tonumber] | first // null);
  def migs: [.files[] | select(test("(^|/)migrations/")) | (split("/") | last | capture("^(?<m>[0-9]+)").m // empty)] | unique;
  . as $all
  # dependency edges {from, to, why_from}: from goes first
  | ([range(0; $all | length) as $i | range(0; $all | length) as $j | select($i != $j) | $all[$i] as $a | $all[$j] as $b
      | (if $a.issue != "" and $b.issue != "" and (($blocks[$a.issue] // []) | index($b.issue)) != null then "blocks \($b.issue)"
         elif ($a | series) != null and ($a | series) == ($b | series) and ([($a | slice // $a.number), ($b | slice // $b.number)] | .[0] < .[1])
           then "Part of \($a | series), slice \($a | slice // $a.number)"
         elif $a.head != "" and $b.base == $a.head then "base of #\($b.number)"
         elif ($b.body | test("(?im)^\\s*depends on\\s+" + ($a.url | gsub("[.]"; "\\."))) ) then "\($b | ref) uses its contract"
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
  | ($ready | map(. as $x | {key: (.i | tostring), value: [$ready[] | select(.i != $x.i and ((([.files[]] - ([.files[]] - $x.files)) | length) > 0 or (((. | migs) - ((. | migs) - ($x | migs))) | length) > 0)) | .i]}) | from_entries) as $ov
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
      | {n: ($k + 1), url: $x.url, pr: pr_cell($x.url), issue: issue_cell($x.issue; $x.issue_url),
         why: ($dependents // $needs // (if ($ov[$x.i | tostring] | length) > 0 then "fewest rebases" else "oldest first" end)),
         after: (if ($renum | length) > 0 then "renumber migration after \($renum | join(", "))"
                 elif ($rebase | length) > 0 then "rebase after \($rebase | join(", "))" else "—" end)}],
     not_ready: [$nodes[] | select((.missing | length) > 0 or (.waits | length) > 0 or .cycle != null)
      | {url, pr: pr_cell(.url), missing: (.missing + (.waits | map("waits for " + .)) + (if .cycle != null then ["dependency cycle with \(.cycle)"] else [] end))}],
     notes: $notes}' <<<"$all"
