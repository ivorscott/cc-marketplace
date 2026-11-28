#!/usr/bin/env bash
# Decide a lead's escalation on the owner's behalf, the way fleet run does: the recommended option, no human waiting.
#
#   decide.sh                                              the open questions, the open escalations as a table
#   decide.sh <team/lead | team> <escalation id>           decide it with the recommended option, or park what is the human's
#   decide.sh <team/lead | team> <escalation id> --answer "<text>"   the owner's answer: the lead is told, the question is closed
#
# A question never waits for a human. For an open escalation this takes the first option (leads put their recommendation
# first), then: tells the lead the decision (it can be overruled, and the lead says so if it is), resolves the escalation with
# the decision as its note, records the decision on the lead (`registry.sh note ... decision`, which the morning report lists
# under "Decisions taken") and, with Linear writes on, comments it on the team's issue ("[fleet]", so tick does not hand it
# back to the lead). With no options the lead is told to decide inside the issue's scope and note the choice.
# What stays the human's is never decided here: a P0, or a question that touches merging, production, infrastructure applies,
# secrets or branch protection. That part is parked: the lead is told to set it aside and carry on with other work, the
# escalation stays open and is marked parked (`registry.sh park-esc`; retire and next leave it, only `resolve` closes it), so
# status, "Waiting on you" and the morning report show it with its full question until the owner answers, tick reminds
# every parked_remind_hours, and one push goes out. Nothing human-only is ever approved. Prints one line:
# `Decided <name>: <question> → <option>.` or `Parked <name> <id> <sev>: <full question>. Recommended: <option>. Needs you:
# fleet decide <name> <id> --answer "<your answer>".` (a second decide: `Already parked ...`). Orchestrator only.
# Command: Decide a lead's escalation with the recommended option, or park what is the human's · e.g. fleet decide build-api 20261029T100000Z-1
set -euo pipefail
. "$(dirname "$0")/common.sh"
[ -z "${FLEET_ROLE:-}" ] || die "decide is the Orchestrator's; an agent (FLEET_ROLE=$FLEET_ROLE) may not run it"
registry="$FLEET_SCRIPTS/registry.sh"

usage="usage: decide.sh [<team/lead | team> <escalation id> [--answer \"<text>\"]]"
if [ $# = 0 ]; then render_escalations "$("$registry" escalations --open)"; exit 0; fi
who="${1:?$usage}"; id="${2:?$usage}"
if [ "${3:-}" = --answer ]; then
  ans="${4:?--answer needs the answer}"
  esc="$("$registry" escalations --open | jq -c --arg w "$who" --arg i "$id" '[.[] | select((.name == $w or .team == $w or (.name | startswith($w + "/"))) and .id == $i)] | first // empty')"
  [ -n "$esc" ] || die "no open escalation $id for $who" "Run fleet decide"
  name="$(jq -r .name <<<"$esc")"; team="$(jq -r '.team // (.name | split("/")[0])' <<<"$esc")"
  lead="$team/lead"; [ -n "$("$registry" get "$lead" 2>/dev/null | jq -r '.name // ""')" ] || lead="$name"
  "$FLEET_SCRIPTS/tell.sh" "$lead" "The owner answered your question $id: $ans" >/dev/null || die "the answer did not reach $lead; the question stays open" "Run fleet tell $lead, then fleet decide $who $id --answer again"
  "$registry" resolve "$name" "$id" --note "$ans" >/dev/null
  printf 'Answered %s %s: %s\n' "$name" "$id" "$ans"
  exit 0
fi
[ $# = 2 ] || die "$usage"
esc="$("$registry" escalations --open | jq -c --arg w "$who" --arg i "$id" '[.[] | select((.name == $w or .team == $w or (.name | startswith($w + "/"))) and .id == $i)] | first // empty')"
[ -n "$esc" ] || die "no open escalation $id for $who" "Run fleet decide"
name="$(jq -r .name <<<"$esc")"; team="$(jq -r '.team // (.name | split("/")[0])' <<<"$esc")"
sev="$(jq -r '.severity // "P1"' <<<"$esc")"; msg="$(jq -r '.message // ""' <<<"$esc")"
lead="$team/lead"; [ -n "$("$registry" get "$lead" 2>/dev/null | jq -r '.name // ""')" ] || lead="$name"
issue="$("$registry" get "$lead" 2>/dev/null | jq -r '.issue // ""')"
short="${msg:0:120}"

# What stays the human's (house rules): merging, production, infrastructure applies, secrets, branch protection; and any P0.
# It fails safe, parking too much rather than deciding a human-only item. The gate is, in order: (1) the filer marked it
# (`registry.sh escalate ... --human`); (2) it is a P0; (3) a broader backstop over its words, word-bounded, used only because a
# filer can forget the mark. "production-ready" and "tokenizer" are not hits; "merge", "key", "apply", "kubectl" are. A question
# that is not clearly something else is parked when the backstop hits, so a hit is never overruled by an option's wording.
human=false; pushfix=false
[ "$(jq -r '.human // false' <<<"$esc")" != true ] || human=true
[ "$sev" != P0 ] || human=true
text="$(printf '%s %s' "$msg" "$(jq -r '(.options // []) | join(" ")' <<<"$esc")" | sed -E 's/[Pp]roduction[- ](ready|grade|quality)//g')"
# A denied plain push of a fleet/ branch is not a human-only item: the words "force push" in it only name what to avoid, so they
# are dropped before the backstop. It needs fleet/ + push + a denial word, no --human mark and no P0; anything else keeps parking.
if ! $human && printf '%s' "$text" | grep -qiE 'fleet/' && printf '%s' "$text" | grep -qiE '\bpush(es|ed|ing)?\b' &&
  printf '%s' "$text" | grep -qiE '\b(denied|denies|denial|blocked|refused)\b' && ! printf '%s' "$text" | grep -qiE '\b(main|master)\b'; then
  pushfix=true
  text="$(printf '%s' "$text" | sed -E 's/[Ff]orce[- ][Pp]ush(es|ed)?//g; s/--force(-with-lease)?//g')"
fi
printf '%s' "$text" | grep -qiE '\b(merg(e|es|ed|ing)|prod|production|deploy(ing|ment)?s?|release to|infra|infrastructure|terraform|tofu|kubectl|helm|pulumi|ansible|cloudformation|apply|applies|secrets?|credentials?|passwords?|passphrase|tokens?|api[ _-]?keys?|keys?|certs?|certificates?|iam|vault|rotate|rotation|branch[ -]protection|protected branch|force[ -]push|required (checks|reviews)|gh pr ready|close the (pr|issue))\b' && human=true

if $human; then
  if [ "$(jq -r '.parked // false' <<<"$esc")" = true ]; then # a second wake never re-parks or re-pushes
    printf 'Already parked %s %s. Needs you: fleet decide %s %s --answer "<your answer>".\n' "$name" "$id" "$name" "$id"
    exit 0
  fi
  prec="$(jq -r '(.options // [])[0] // "none"' <<<"$esc")"
  "$registry" park-esc "$name" "$id" >/dev/null
  "$FLEET_SCRIPTS/tell.sh" "$lead" "Decision (taken for the owner, who keeps this one): set that part aside and carry on with the rest of the work; do not wait. It stays open for the owner. Question was: $short" >/dev/null 2>&1 ||
    warn "could not tell $lead; the escalation is parked anyway"
  line="$(printf 'Parked %s %s %s: %s. Recommended: %s. Needs you: fleet decide %s %s --answer "<your answer>".' "$name" "$id" "$sev" "$msg" "$prec" "$name" "$id")"
  notify "Fleet needs you" "$(render_line alert cause="$name parked $sev $id: ${msg:0:200}. Recommended: ${prec:0:80}" next="fleet decide $name $id --answer \"<your answer>\"")" request alert || true
  printf '%s\n' "$line"
  exit 0
fi

rec="$(jq -r '(.options // [])[0] // ""' <<<"$esc")"
if $pushfix; then # never take an option that forces a push (--force, -f, force-with-lease, force push, +refspec): the first one that does not
  rec="$(jq -r '[(.options // [])[] | select(test("(^|[[:space:]])-f([[:space:]]|$)|--force|force[- ]?(with[- ]?lease|push)|(^|[[:space:]])\\+[A-Za-z]"; "i") | not)][0] // ""' <<<"$esc")"
fi
if [ -n "$rec" ]; then
  text="Decision (taken for the owner, who can overrule it on the issue): $rec. Question was: $short. Carry on."
  note="$short → $rec"
elif $pushfix; then
  text="Decision (taken for the owner): push without force (plain \`git push -u origin <branch>\`), or merge origin/main and push plainly; do not retry the denied push another way. Question was: $short. Carry on."
  rec="push without force, or merge origin/main and push plainly"; note="$short → $rec"
else
  text="Decision (taken for the owner): no option was given, so decide inside the issue's scope, note the choice in your summary, and carry on. Question was: $short."
  rec="decide inside the issue's scope"; note="$short → $rec"
fi
"$FLEET_SCRIPTS/tell.sh" "$lead" "$text" >/dev/null 2>&1 || warn "could not tell $lead; the decision is recorded anyway"
"$registry" note "$lead" decision "$note" >/dev/null
"$registry" resolve "$name" "$id" --note "$rec" >/dev/null
if [ -n "$issue" ] && "$FLEET_SCRIPTS/linear.sh" has-key >/dev/null 2>&1 && [ "$(linear_writes)" != off ]; then
  "$FLEET_SCRIPTS/linear.sh" comment "$issue" "[fleet] Decision taken on the owner's behalf: $short → $rec. Reply on this issue to overrule it." >/dev/null 2>&1 ||
    warn "could not comment the decision on $issue"
fi
printf 'Decided %s: %s → %s.\n' "$name" "$short" "$rec"
