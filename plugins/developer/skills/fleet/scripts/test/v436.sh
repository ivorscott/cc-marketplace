#!/usr/bin/env bash
# 4.3.6 cases (DEV-1262): an escalation that is the owner's is parked, stays open and reaches them until they answer.
# Sourced by run.sh (ok/eq/check, $SCRIPTS, $T, $REG) after v435.sh.

v436_state() { # v436_state <name>: a fresh state root with one lead
  export FLEET_STATE_DIR="$T/v436-$1" FLEET_REGISTRY="$T/v436-$1/fleet.json" FLEET_INBOX="$T/v436-$1/escalations.jsonl" FLEET_WORKTREES="$T/v436-$1/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; rm -f "$AS"/*; gcfg
  "$REG" add '{"name":"pk-a/lead","team":"pk-a","tier":"Lead","status":"Working","herdr_ref":"pk-a-lead","pane":"p1","issue":"DEV-1"}' >/dev/null; echo working >"$AS/pk-a-lead"
}

v436_parked() {
  v436_state parked; export FLEET_NOW=2026-11-27T10:00:00Z
  local q id out
  q="may I merge the PR to main myself? $(printf 'x%.0s' $(seq 1 150))"
  "$REG" escalate pk-a/lead P1 "which database?" "use postgres" sqlite >/dev/null 2>&1
  id="$("$REG" escalations --open | jq -r '.[0].id')"
  eq "v436 decide: a decided item is resolved at once and not parked" "$("$SCRIPTS/decide.sh" pk-a "$id" 2>&1 | grep -c '^Decided '):$("$REG" escalations --open | jq length)" "1:0"
  "$REG" escalate pk-a/lead P1 "$q" yes no >/dev/null 2>&1
  id="$("$REG" escalations --open | jq -r '.[0].id')"; : >"$HERDR_LOG"
  out="$("$SCRIPTS/decide.sh" pk-a "$id" 2>&1)"
  eq "v436 decide: a parked item prints its full question, the recommendation and how to answer" \
    "$(printf '%s' "$out" | grep -c "^Parked pk-a/lead $id P1: $q\. Recommended: yes\. Needs you: fleet resolve pk-a/lead $id --note"):$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1:1"
  eq "v436 decide: it stays open and marked parked, with one push and the lead told to carry on" \
    "$("$REG" escalations --open | jq -r '[.[] | select(.parked == true and .resolved_at == null)] | length'):$(grep -c '^notification show' "$HERDR_LOG"):$(grep -c 'carry on with the rest of the work' "$HERDR_LOG")" "1:1:1"
  : >"$HERDR_LOG"
  eq "v436 decide: a second decide is a no-op (no second push, no second park)" \
    "$("$SCRIPTS/decide.sh" pk-a "$id" 2>&1 | grep -c '^Already parked '):$(grep -c '^notification show' "$HERDR_LOG"):$("$REG" escalations --open | jq length)" "1:0:1"
  local st; st="$("$SCRIPTS/fleet" status 2>/dev/null)"
  eq "v436 status: the team's Needs you cell and Waiting on you carry the full question and the recommendation" \
    "$(printf '%s' "$st" | grep -c "parked: $q (rec: yes)"):$(printf '%s' "$st" | grep -c '^Waiting on you: .*parked: .* (rec: yes)')" "2:1"
  eq "v436 report: the morning report lists it with the full question" \
    "$(TZ=UTC "$SCRIPTS/metrics.sh" --morning 2>/dev/null | awk '/^## Needs your eyes/ {on = 1; next} /^## / {on = 0} on' | grep -c "parked for you (pk-a/lead $id): $q")" 1
  # P2 parks like P0 and P1
  "$REG" escalate pk-a/lead P2 "rotate the deploy key?" yes no >/dev/null 2>&1
  local id2; id2="$("$REG" escalations --open | jq -r '[.[] | select(.parked != true)][0].id')"
  "$SCRIPTS/decide.sh" pk-a "$id2" >/dev/null 2>&1
  eq "v436 status: a parked P2 is listed under Waiting on you too" "$("$SCRIPTS/fleet" status 2>/dev/null | grep '^Waiting on you:' | grep -c 'rotate the deploy key')" 1
  # retire keeps it, status still shows it, resolve closes it
  "$REG" retire pk-a --outcome Shipped >/dev/null
  eq "v436 retire: a parked item survives the team's retire, still open and still shown" \
    "$("$REG" escalations --open | jq length):$("$SCRIPTS/fleet" status 2>/dev/null | grep -c '^Waiting on you:')" "2:1"
  eq "v436 retire: next/archive leave a row with an open parked item" "$("$REG" escalations --open --parked | jq length)" 2
  "$REG" resolve pk-a/lead "$id" --note "owner said no" >/dev/null 2>&1
  "$REG" resolve pk-a/lead "$id2" --note "owner said yes" >/dev/null 2>&1
  eq "v436 resolve: it closes the parked items, gone from status and the report, escalation_resolved logged" \
    "$("$REG" escalations --open | jq length):$("$SCRIPTS/fleet" status 2>/dev/null | grep -c 'Waiting on you'):$(TZ=UTC "$SCRIPTS/metrics.sh" --morning 2>/dev/null | grep -c "parked for you (pk-a/lead $id)"):$(grep -c 'escalation_resolved' "$FLEET_STATE_DIR/events.jsonl")" "0:0:0:3"
  unset FLEET_NOW
}

v436_next() { # a team's next issue closes the open items but leaves a parked one
  v436_state next
  "$REG" escalate pk-a/lead P1 "which db?" a b >/dev/null 2>&1
  "$REG" escalate pk-a/lead P1 "may I merge it?" --human yes no >/dev/null 2>&1
  local id; id="$("$REG" escalations --open | jq -r '[.[] | select(.message == "may I merge it?")][0].id')"
  "$REG" park-esc pk-a "$id" >/dev/null
  eq "v436 registry: park-esc marks the open item parked, with parked_at, still open" "$("$REG" escalations --open | jq -r '[.[] | select(.id == "'"$id"'")][0] | [.parked, (.parked_at | type), .resolved_at] | @csv')" 'true,"string",'
  eq "v436 registry: an agent may not park-esc" "$(FLEET_ROLE=builder "$REG" park-esc pk-a "$id" 2>&1 | grep -c "Orchestrator's")" 1
  eq "v436 registry: --parked lists only the parked items" "$("$REG" escalations --open --parked | jq length)" 1
}

v436_remind() { # tick raises parked_reminder after parked_remind_hours, once per window, not after resolve
  v436_state remind
  "$REG" escalate pk-a/lead P1 "may I merge it?" --human yes no >/dev/null 2>&1
  local id; id="$("$REG" escalations --open | jq -r '.[0].id')"
  FLEET_NOW=2026-11-27T10:00:00Z "$REG" park-esc pk-a "$id" >/dev/null
  n() { FLEET_NOW="$1" "$SCRIPTS/tick.sh" 2>/dev/null | jq -rs '[.[] | arrays | .[] | select(.type == "parked_reminder")] | length'; }
  eq "v436 tick: no reminder before the interval" "$(n 2026-11-27T10:00:00Z)" 0
  eq "v436 tick: and none just under 6 hours" "$(n 2026-11-27T10:00:00Z)" 0
  eq "v436 tick: one reminder once the interval has passed since parked_at" "$(n 2099-01-01T10:00:00Z)" 1
  eq "v436 tick: none twice in the window" "$(n 2099-01-01T11:00:00Z)" 0
  eq "v436 tick: again after another interval" "$(n 2099-01-01T17:00:01Z)" 1
  eq "v436 tick: the reminder renders as a Still parked line" "$(FLEET_NOW=2099-01-02T00:00:02Z "$SCRIPTS/tick.sh" 2>/dev/null >/dev/null; jq -r '.parked_reminded | keys | length' "$FLEET_STATE_DIR/tick.state.json")" 1
  "$REG" resolve pk-a/lead "$id" --note ok >/dev/null
  eq "v436 tick: none after resolve, and the state key is pruned" "$(n 2099-02-01T00:00:00Z):$(jq -r '(.parked_reminded // {}) | length' "$FLEET_STATE_DIR/tick.state.json")" "0:0"
}

v436_text() {
  local f="$SCRIPTS/../templates/build.json" l="$SCRIPTS/../../../agents/lead.md" r="$SCRIPTS/run.sh"
  eq "v436 text: the lead brief and lead.md name --human and never ask only in the pane" \
    "$(jq -r '.. | strings' "$f" | grep -c 'never ask only in the pane'):$(grep -c 'never ask only in the pane' "$l"):$(grep -c -- '--human' "$l")" "1:1:1"
  eq "v436 text: the run rules tell the Orchestrator to relay the Parked line" "$(grep -c 'you relay decide.s Parked line' "$r")" 1
  eq "v436 text: the worker rules carry the same sentence" "$(grep -c 'never ask only in the pane' "$SCRIPTS/common.sh")" 1
  eq "v436 text: the plugin and the marketplace are at 4.3.6" "$(jq -r .version "$SCRIPTS/../../../.claude-plugin/plugin.json"):$(jq -r '.plugins[] | select(.name == "developer") | .version' "$SCRIPTS/../../../../../.claude-plugin/marketplace.json")" "4.3.6:4.3.6"
}

v436_smoke() { v436_parked; v436_next; v436_remind; v436_text; }
v436_full() { v436_smoke; }
