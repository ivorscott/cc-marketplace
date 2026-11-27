#!/usr/bin/env bash
# 4.3.0: work is picked from Todo only. Backlog is parked: a Backlog issue is never bootable and never frees a slot, however
# it is labelled; `fleet candidates` lists it as `parked`. candidates_allow_backlog = true picks from Backlog too, as before.
# Sourced by run.sh after v427.sh (v427_issue, v427_db, v427_cands, v427_dbedit) and v420.sh (v420_state, v420_tick, v420_evn).
# No network: the tracker is linear-stub.sh.
v430_ids() { jq -r --arg k "$1" '[.[$k][] | .id + ":" + .reason] | sort | join(",")'; }

v430_parked() { # Backlog is parked by default, whatever its labels, and says why
  v420_state parked; export FLEET_NOW=2026-10-29T10:00:00Z
  "$REG" add '{"name":"pk-a/lead","team":"pk-a","tier":"Lead","status":"Working","herdr_ref":"pk-a-lead","pane":"p1","issue":"DEV-1"}' >/dev/null
  v427_db "[$(v427_issue DEV-20 Todo '["R1"]'),$(v427_issue DEV-21 Backlog '["R1"]' '{"priority":1}'),$(v427_issue DEV-22 Backlog '[]'),
    $(v427_issue DEV-23 Backlog '["R1"]' '{"blocked_by":["DEV-20"]}'),$(v427_issue DEV-24 Todo '["R1"]' '{"blocked_by":["DEV-21"]}')]"
  eq "v430 parked: an urgent, role-labelled, unblocked Backlog issue is not bootable" "$(v427_cands | v430_ids bootable)" "DEV-20:ready"
  eq "v430 parked: it is skipped as parked; a Backlog issue with no role or a blocker keeps that reason" \
    "$(v427_cands | v430_ids skipped)" "DEV-1:no-role,DEV-21:parked,DEV-22:no-role,DEV-23:blocked,DEV-24:blocked"
  : >"$LINEAR_LOG"
  eq "v430 parked: the plain form lists Todo work only" "$("$SCRIPTS/linear.sh" candidates | jq -r 'sort | join(",")')" "DEV-20"
  eq "v430 parked: and reads Backlog not at all (one query)" "$(tr '\n' ',' <"$LINEAR_LOG")" "query Candidates,"
  : >"$LINEAR_LOG"; v427_cands >/dev/null
  eq "v430 parked: --detail asks for Backlog in a query of its own" "$(tr '\n' ',' <"$LINEAR_LOG")" "query Candidates,query Parked,"
  eq "v430 parked: the command names it on the skipped line" "$("$SCRIPTS/candidates.sh" 2>&1 | tail -n 1)" \
    "skipped: DEV-1 no-role, DEV-21 parked, DEV-22 no-role, DEV-23 blocked, DEV-24 blocked"
  v427_dbedit '.issues |= map(if .identifier == "DEV-21" then .state.name = "Todo" else . end)'
  eq "v430 parked: moved to Todo it is bootable, and what it blocked still waits for it" "$(v427_cands | v430_ids bootable)" "DEV-20:ready,DEV-21:ready"
  v420_nolinear; unset FLEET_NOW
}

v430_only_backlog() { # with nothing in Todo the fleet has nothing to boot
  v420_state onlybacklog; export FLEET_NOW=2026-10-29T10:00:00Z
  v427_db "[$(v427_issue DEV-30 Backlog '["R1"]'),$(v427_issue DEV-31 Backlog '["R1"]')]"
  eq "v430 only backlog: nothing is bootable" "$("$SCRIPTS/candidates.sh" 2>&1 | head -n 1)" "Nothing bootable."
  eq "v430 only backlog: and both issues are named as parked" "$("$SCRIPTS/candidates.sh" 2>&1 | tail -n 1)" "skipped: DEV-1 no-role, DEV-30 parked, DEV-31 parked"
  v420_nolinear; unset FLEET_NOW
}

v430_allow_backlog() { # candidates_allow_backlog = true is the behaviour before 4.3.0
  v420_state allowbacklog; export FLEET_NOW=2026-10-29T10:00:00Z
  v427_db "[$(v427_issue DEV-20 Todo '["R1"]'),$(v427_issue DEV-21 Backlog '["R1"]'),$(v427_issue DEV-22 Backlog '[]')]"
  gcfg 'linear_writes = "on"' 'candidates_allow_backlog = true'
  : >"$LINEAR_LOG"
  eq "v430 allow backlog: a Backlog issue is ready again" "$(v427_cands | v430_ids bootable)" "DEV-20:ready,DEV-21:ready"
  eq "v430 allow backlog: nothing is parked, and one query reads it all" "$(v427_cands | v430_ids skipped):$(sort -u "$LINEAR_LOG" | tr '\n' ',')" "DEV-1:no-role,DEV-22:no-role:query Candidates,"
  eq "v430 allow backlog: the plain form has it too" "$("$SCRIPTS/linear.sh" candidates | jq -r 'sort | join(",")')" "DEV-20,DEV-21"
  gcfg 'linear_writes = "on"' 'candidates_allow_backlog = false'
  eq "v430 allow backlog: false is the default" "$(v427_cands | v430_ids bootable)" "DEV-20:ready"
  v420_nolinear; unset FLEET_NOW
}

v430_slot_free() { # Backlog work never wakes the Orchestrator for a free slot; Todo work does
  v420_state parkedslot; export DF_GB=100
  "$REG" add '{"name":"orchestrator","team":"orchestrator","tier":"Orchestrator","status":"Working","herdr_ref":"o9","pane":"po9"}' >/dev/null
  "$REG" add '{"name":"ps-a/lead","team":"ps-a","tier":"Lead","status":"Working","herdr_ref":"ps-a-lead","pane":"p1","issue":"DEV-1"}' >/dev/null; echo working >"$AS/ps-a-lead"
  "$REG" set orchestrator target_teams=3 >/dev/null
  v427_db "[$(v427_issue DEV-40 Backlog '["R1"]' '{"priority":1}')]"
  local ev
  ev="$(v420_tick 2026-10-29T10:00:00Z)"; eq "v430 slot_free: a free slot with only Backlog work is silent" "$(v420_evn "$ev" slot_free)" 0
  v427_dbedit '.issues |= map(if .identifier == "DEV-40" then .state.name = "Todo" else . end)'
  ev="$(v420_tick 2026-10-29T10:11:00Z)"; eq "v430 slot_free: the same issue in Todo announces" "$(v420_evn "$ev" slot_free)" 1
  v420_nolinear; unset DF_GB
}

v430_docs() { # the rule is written where the Orchestrator and the user read it
  local sk="$SCRIPTS/.."
  eq "v430 docs: SKILL.md, the README, the config example and the output reference state the Todo-only rule" \
    "$(grep -c 'Backlog is parked' "$sk/SKILL.md" | tr -d ' '):$(grep -c 'candidates_allow_backlog' "$sk/README.md" "$sk/config.example.toml" "$sk/references/output.md" | cut -d: -f2 | tr '\n' ',')" "1:2,1,1,"
  eq "v430 docs: no doc still calls Backlog bootable" "$(grep -rn 'Todo or Backlog\|Todo, Backlog' "$sk/SKILL.md" "$sk/README.md" "$sk/references" "$SCRIPTS"/*.sh | wc -l | tr -d ' ')" 0
}

v430_smoke() { # the critical cases, CI (V430_ONLY="name name" runs just those, to debug one)
  local f
  for f in v430_parked v430_only_backlog v430_allow_backlog v430_slot_free v430_docs; do
    case " ${V430_ONLY:-$f} " in *" $f "*) "$f" ;; esac
  done
}
v430_full() { v430_smoke; }
