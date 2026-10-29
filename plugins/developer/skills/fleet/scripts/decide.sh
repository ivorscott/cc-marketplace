#!/usr/bin/env bash
# Decide a lead's escalation on the owner's behalf, the way fleet run does: the recommended option, no human waiting.
#
#   decide.sh <team/lead | team> <escalation id>
#
# A question never waits for a human. For an open escalation this takes the first option (leads put their recommendation
# first), then: tells the lead the decision (it can be overruled, and the lead says so if it is), resolves the escalation with
# the decision as its note, records the decision on the lead (`registry.sh note ... decision`, which the morning report lists
# under "Decisions taken") and, with Linear writes on, comments it on the team's issue ("[fleet]", so tick does not hand it
# back to the lead). With no options the lead is told to decide inside the issue's scope and note the choice.
# What stays the human's is never decided here: a P0, or a question that touches merging, production, infrastructure applies,
# secrets or branch protection. That part is parked: the lead is told to set it aside and carry on with other work, the
# escalation is resolved as parked, `registry.sh note ... parked` puts it in the morning report's "Needs your eyes", and one
# push goes out. Nothing human-only is ever approved. Prints one line: `Decided <name>: <question> → <option>.` or
# `Parked <name>: <question>. Left for the owner.` Orchestrator only.
# Command: Decide a lead's escalation with the recommended option, or park what is the human's · e.g. fleet decide build-api 20261029T100000Z-1
set -euo pipefail
. "$(dirname "$0")/common.sh"
[ -z "${FLEET_ROLE:-}" ] || die "decide is the Orchestrator's; an agent (FLEET_ROLE=$FLEET_ROLE) may not run it"
registry="$FLEET_SCRIPTS/registry.sh"

usage="usage: decide.sh <team/lead | team> <escalation id>"
who="${1:?$usage}"; id="${2:?$usage}"
esc="$("$registry" escalations --open | jq -c --arg w "$who" --arg i "$id" '[.[] | select((.name == $w or .team == $w or (.name | startswith($w + "/"))) and .id == $i)] | first // empty')"
[ -n "$esc" ] || die "no open escalation $id for $who" "Run fleet escalations --open"
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
human=false
[ "$(jq -r '.human // false' <<<"$esc")" != true ] || human=true
[ "$sev" != P0 ] || human=true
text="$(printf '%s %s' "$msg" "$(jq -r '(.options // []) | join(" ")' <<<"$esc")" | sed -E 's/[Pp]roduction[- ](ready|grade|quality)//g')"
printf '%s' "$text" | grep -qiE '\b(merg(e|es|ed|ing)|prod|production|deploy(ing|ment)?s?|release to|infra|infrastructure|terraform|tofu|kubectl|helm|pulumi|ansible|cloudformation|apply|applies|secrets?|credentials?|passwords?|passphrase|tokens?|api[ _-]?keys?|keys?|certs?|certificates?|iam|vault|rotate|rotation|branch[ -]protection|protected branch|force[ -]push|required (checks|reviews)|gh pr ready|close the (pr|issue))\b' && human=true

if $human; then
  "$registry" note "$lead" parked "$short" >/dev/null
  "$FLEET_SCRIPTS/tell.sh" "$lead" "Decision (taken for the owner, who keeps this one): set that part aside and carry on with the rest of the work; do not wait. It is listed for the owner. Question was: $short" >/dev/null 2>&1 ||
    warn "could not tell $lead; the escalation is parked anyway"
  "$registry" resolve "$name" "$id" --note "parked for the human: $short" >/dev/null
  notify "Fleet needs you" "$(render_line alert cause="$name parked a decision that is yours: ${short:0:80}" next="It is in the morning report; nothing waits")" request alert || true
  printf 'Parked %s: %s. Left for the owner.\n' "$name" "$short"
  exit 0
fi

rec="$(jq -r '(.options // [])[0] // ""' <<<"$esc")"
if [ -n "$rec" ]; then
  text="Decision (taken for the owner, who can overrule it on the issue): $rec. Question was: $short. Carry on."
  note="$short → $rec"
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
