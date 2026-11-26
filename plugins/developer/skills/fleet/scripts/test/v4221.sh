#!/usr/bin/env bash
# 4.2.21 (DEV-1234): fleet run survives /clear. init installs a SessionStart hook (backup, merge, idempotent, validate,
# restore on failure), start repairs it, stop leaves it, init --no-hook removes only its entry; the hook script is silent
# except in the Orchestrator's pane while the run is on. Sourced by run.sh after v420.sh (v420_state, REG, SCRIPTS, eq).
# Every settings file is a temp file (FLEET_CLAUDE_SETTINGS); the real ~/.claude is never read or written. Generic names only.
V4221_HOOK="$SCRIPTS/../../../hooks/fleet-run-resume.sh"

# v4221_hook_env: a fake HOME holding one installed plugin version whose fleet and registry.sh are stubs
v4221_hook_env() {
  local d="$T/v4221-home" s; s="$d/.claude/plugins/cache/cc-marketplace/developer/9.9.9/skills/fleet/scripts"
  rm -rf "$d"; mkdir -p "$s"
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "run status" ] || exit 1\necho "Run: ${STUB_RUN:-running}. Target 1 teams, 0 live. Profile: saved."\n' >"$s/fleet"
  printf '#!/usr/bin/env bash\necho "{\\"pane\\":\\"pane-orch\\"}"\n' >"$s/registry.sh"
  chmod +x "$s/fleet" "$s/registry.sh"; V4221_HOME="$d"
}
v4221_hook() { env -u HERDR_PANE_ID HOME="$V4221_HOME" "$@" bash "$V4221_HOOK" 2>/dev/null; }

v4221_hook_script() {
  v4221_hook_env
  local out
  eq "v4221 hook: silent with no herdr pane" "$(v4221_hook STUB_RUN=running)" ""
  eq "v4221 hook: silent in another pane" "$(v4221_hook HERDR_PANE_ID=pane-other STUB_RUN=running)" ""
  eq "v4221 hook: silent while the run is off" "$(v4221_hook HERDR_PANE_ID=pane-orch "STUB_RUN=not running")" ""
  out="$(v4221_hook HERDR_PANE_ID=pane-orch STUB_RUN=running)"
  eq "v4221 hook: emits SessionStart context in the Orchestrator pane" "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out" 2>/dev/null)" SessionStart
  eq "v4221 hook: the context says to run fleet run start" "$(jq -r '.hookSpecificOutput.additionalContext | contains("fleet run start")' <<<"$out" 2>/dev/null)" true
  eq "v4221 hook: silent when no plugin is installed" "$(rm -rf "$V4221_HOME/.claude/plugins"; v4221_hook HERDR_PANE_ID=pane-orch)" ""
}

v4221_answers() { printf '2\nanything\ncritical-path\nwhole-first\nallow\n10\n15\n10\n08:00\nnever\nno\n' >"$T/v4221-answers"; }
v4221_init() { FLEET_RUN_ANSWERS="$T/v4221-answers" FLEET_NOW=2026-11-26T10:00:00Z "$SCRIPTS/run.sh" init "$@" 2>&1; }
v4221_baks() { local n=0 f; for f in "$1"/settings.json.bak-*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
v4221_n() { jq '[.hooks.SessionStart[]?.hooks[]?.command? // empty | select(contains("fleet-run-resume.sh"))] | length' "$1"; }

v4221_init_hook() {
  v420_state hk; v4221_answers
  local D="$T/v4221-set" S out rc
  S="$D/settings.json"; rm -rf "$D"; mkdir -p "$D"; export FLEET_CLAUDE_SETTINGS="$S"
  printf '{"model":"x","hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"/bin/other-hook"}]}],"Stop":[{"hooks":[{"type":"command","command":"/bin/stop-hook"}]}]}}\n' >"$S"
  out="$(v4221_init)"; rc=$?
  eq "v4221 init: exit 0 and one line saying the hook was added" "$rc:$(grep -c "Added the run's /clear hook" <<<"$out")" "0:1"
  eq "v4221 init: the other SessionStart hook, the Stop hook and other keys are intact" \
    "$(jq -r '[.model, .hooks.Stop[0].hooks[0].command, .hooks.SessionStart[0].hooks[0].command] | join(",")' "$S")" "x,/bin/stop-hook,/bin/other-hook"
  eq "v4221 init: one ^clear\$ entry is added after it, naming the copy next to settings" \
    "$(jq -r '.hooks.SessionStart | length, .[1].matcher, .[1].hooks[0].command' "$S" | paste -sd' ' -)" "2 ^clear\$ $D/hooks/fleet-run-resume.sh"
  eq "v4221 init: the copy is executable and equals the shipped script" "$([ -x "$D/hooks/fleet-run-resume.sh" ] && cmp -s "$D/hooks/fleet-run-resume.sh" "$V4221_HOOK" && echo same)" same
  eq "v4221 init: one dated backup holds the old file" "$(v4221_baks "$D"):$(jq -r '.hooks.SessionStart | length' "$D/settings.json.bak-20261126")" "1:1"
  out="$(v4221_init)"
  eq "v4221 init: a re-run is idempotent (no second entry, no second backup)" "$(v4221_n "$S"):$(v4221_baks "$D"):$(grep -c 'already installed' <<<"$out")" "1:1:1"
  # an existing entry that names the script (the owner's own) counts as equivalent
  printf '{"hooks":{"SessionStart":[{"matcher":"^clear$","hooks":[{"type":"command","command":"%s/own/fleet-run-resume.sh"}]}]}}\n' "$D" >"$S"; mkdir -p "$D/own"; : >"$D/own/fleet-run-resume.sh"
  cp "$S" "$T/v4221-own.orig"; v4221_init >/dev/null
  eq "v4221 init: an existing entry naming fleet-run-resume.sh is left alone" "$(cmp -s "$S" "$T/v4221-own.orig" && echo same)" same
  # a missing settings file is created
  rm -rf "$D"; mkdir -p "$D"; v4221_init >/dev/null
  eq "v4221 init: a missing settings file is created with the entry" "$(v4221_n "$S")" 1
  # invalid JSON is left untouched, init still succeeds
  printf '{ not json' >"$S"; cp "$S" "$T/v4221-bad.orig"; out="$(v4221_init)"; rc=$?
  eq "v4221 init: invalid JSON is left byte-identical, init exits 0 and says so" "$(cmp -s "$S" "$T/v4221-bad.orig" && echo same):$rc:$(grep -c 'not valid settings JSON' <<<"$out")" "same:0:1"
  # a failed write restores the backup: a jq shim whose last call (the validation of the written file) fails
  rm -rf "$D"; mkdir -p "$D" "$T/v4221-bin"; printf '{"hooks":{"SessionStart":[]}}\n' >"$S"; cp "$S" "$T/v4221-w.orig"
  printf '#!/usr/bin/env bash\ncase "$*" in "-e . %s") exit 1 ;; esac\nexec %s "$@"\n' "$S" "$(command -v jq)" >"$T/v4221-bin/jq"; chmod +x "$T/v4221-bin/jq"
  out="$(PATH="$T/v4221-bin:$PATH" v4221_init)"; rc=$?
  eq "v4221 init: a write that fails validation is restored from the backup, with a message" "$(cmp -s "$S" "$T/v4221-w.orig" && echo same):$rc:$(grep -c 'restored it from' <<<"$out")" "same:0:1"
  rm -f "$T/v4221-bin/jq"
  unset FLEET_CLAUDE_SETTINGS
}

v4221_no_hook() {
  v420_state nh; v4221_answers
  local D="$T/v4221-nh" S; S="$D/settings.json"; rm -rf "$D"; mkdir -p "$D"; export FLEET_CLAUDE_SETTINGS="$S"
  printf '{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"/bin/other-hook"}]}]}}\n' >"$S"
  v4221_init >/dev/null
  v4221_init --no-hook >/dev/null
  eq "v4221 init --no-hook: removes only its own entry" "$(v4221_n "$S"):$(jq -r '.hooks.SessionStart | length, .[0].hooks[0].command' "$S" | paste -sd' ' -)" "0:1 /bin/other-hook"
  eq "v4221 init --no-hook: asks nothing and saves nothing (the answers file is not needed)" "$(FLEET_RUN_ANSWERS="$T/none" "$SCRIPTS/run.sh" init --no-hook 2>&1 | grep -c 'not installed')" 1
  unset FLEET_CLAUDE_SETTINGS
}

v4221_start_stop() {
  v420_state ss; v4221_answers; unset HERDR_PANE_ID
  local D="$T/v4221-ss" S out; S="$D/settings.json"; rm -rf "$D"; mkdir -p "$D"; export FLEET_CLAUDE_SETTINGS="$S"
  "$REG" add '{"name":"orchestrator","team":"orchestrator","tier":"Orchestrator","status":"Working","herdr_ref":"om","pane":"pom"}' >/dev/null
  v4221_init >/dev/null
  out="$("$SCRIPTS/run.sh" start </dev/null 2>&1)"
  eq "v4221 start: says nothing about the hook when it is installed" "$(grep -c 'run /clear hook' <<<"$out")" 0
  jq 'del(.hooks)' "$S" >"$S.t" && cat "$S.t" >"$S"; rm -f "$S.t"
  out="$("$SCRIPTS/run.sh" start </dev/null 2>&1)"
  eq "v4221 start: a missing entry is reinstalled with one line" "$(v4221_n "$S"):$(grep -c 'Reinstalled the run /clear hook' <<<"$out")" "1:1"
  rm -f "$D/hooks/fleet-run-resume.sh"
  out="$("$SCRIPTS/run.sh" start </dev/null 2>&1)"
  eq "v4221 start: an entry pointing at a missing script gets the script back, entry kept once" "$([ -x "$D/hooks/fleet-run-resume.sh" ] && echo yes):$(v4221_n "$S"):$(grep -c 'Reinstalled the run /clear hook' <<<"$out")" "yes:1:1"
  "$SCRIPTS/run.sh" stop >/dev/null 2>&1
  eq "v4221 stop: leaves the hook in place" "$(v4221_n "$S"):$([ -x "$D/hooks/fleet-run-resume.sh" ] && echo yes)" "1:yes"
  unset FLEET_CLAUDE_SETTINGS
}

v4221_smoke() { v4221_hook_script; v4221_init_hook; v4221_no_hook; v4221_start_stop; }
v4221_full() { v4221_smoke; }
