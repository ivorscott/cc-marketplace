#!/usr/bin/env bash
# 4.2.0: the cases for fleet run and its parts. Sourced by run.sh, which gives it the helpers (ok, eq, check, REG,
# SCRIPTS, the herdr shim, gcfg, rfix, rterms). v420_smoke runs the critical subset (CI), v420_full every case. Each
# case builds its own state root under $T/v420-<name>; generic names only.
v420_state() { # v420_state <name>: a fresh state root, no herdr agent state, no config
  export FLEET_STATE_DIR="$T/v420-$1" FLEET_REGISTRY="$T/v420-$1/fleet.json" FLEET_INBOX="$T/v420-$1/escalations.jsonl" FLEET_WORKTREES="$T/v420-$1/worktrees"
  rm -rf "$FLEET_STATE_DIR"; mkdir -p "$FLEET_STATE_DIR"; rm -f "$AS"/*; gcfg
}

v420_redact_gate() { # the redact check gates only public repos
  v420_state redact
  local R="$T/v420-redact-repo" S="$T/v420-redact-terms" out rc
  rfix "$R"; rterms "$S"; git -C "$R" remote add origin https://github.com/acme/app.git
  printf '#!/usr/bin/env bash\ncase "$*" in "repo view acme/app"*) [ -n "${GH_VIS:-}" ] || exit 1; echo "$GH_VIS" ;; *) exit 1 ;; esac\n' >"$T/v420-gh"; chmod +x "$T/v420-gh"
  rr() { (cd "$R" && FLEET_GH="$T/v420-gh" FLEET_STATE_DIR="$S" "$SCRIPTS/redact-check.sh" --range main..feat 2>/dev/null); echo "rc=$?"; }
  eq "v420 redact: a public repo is checked" "$(GH_VIS=PUBLIC rr | paste -sd' ' -)" "Redact check main..feat: 1 matches. rc=1"
  eq "v420 redact: a private repo is skipped, exit 0, even with a match in the range" "$(GH_VIS=PRIVATE rr | paste -sd' ' -)" "Redact check main..feat: skipped (private repo). rc=0"
  eq "v420 redact: an internal repo is skipped too" "$(GH_VIS=INTERNAL rr | paste -sd' ' -)" "Redact check main..feat: skipped (private repo). rc=0"
  eq "v420 redact: a visibility gh cannot read counts as public" "$(GH_VIS='' rr | paste -sd' ' -)" "Redact check main..feat: 1 matches. rc=1"
  gcfg 'public_repos = ["acme/app"]'
  eq "v420 redact: public_repos wins over what gh says" "$(GH_VIS=PRIVATE rr | paste -sd' ' -)" "Redact check main..feat: 1 matches. rc=1"
  gcfg 'private_repos = ["acme/app"]'
  eq "v420 redact: private_repos is read before gh is asked" "$(GH_VIS='' rr | paste -sd' ' -)" "Redact check main..feat: skipped (private repo). rc=0"
  gcfg
  rm -rf "$S/private"
  eq "v420 redact: a public repo with no terms file is still exit 2, never clean" "$(GH_VIS=PUBLIC rr | tail -1)" "rc=2"
  eq "v420 redact: a private repo needs no terms file" "$(GH_VIS=PRIVATE rr | tail -1)" "rc=0"
}

v420_run_init() { # fleet run init writes the [run] profile; a re-run shows the saved answers as defaults
  v420_state init
  local C="$FLEET_CONFIG_DIR/config.toml" out rc
  printf '# my notes\nmax_teams = 5\nlabel_prefix = "fleet:"\n\n[context_window]\n"claude-opus-5-5" = 200000\n' >"$C"
  out="$("$SCRIPTS/run.sh" init </dev/null 2>&1)"; rc=$?
  eq "v420 run init: without a terminal it refuses and lists the questions, writing nothing" \
    "$rc:$(printf '%s' "$out" | grep -c 'Teams to keep running'):$(grep -c '^\[run\]' "$C")" "1:1:0"
  printf '2\nparent DEV-9\n\n\nallow\n\n20\n\n07:30\n17:00\n' >"$T/v420-answers"
  out="$(FLEET_RUN_ANSWERS="$T/v420-answers" "$SCRIPTS/run.sh" init 2>&1)"; rc=$?
  eq "v420 run init: scripted answers are saved to [run], and the reply says so" "$rc:$(printf '%s' "$out" | tail -1)" "0:Run profile saved: 2 teams (2 can run), installs allow. Written to $C."
  eq "v420 run init: the profile holds the answers and the defaults" \
    "$(bash -c '. "$1/common.sh"; printf "%s|%s|%s|%s|%s|%s" "$(run_int teams 0)" "$(run_str work x)" "$(run_str order x)" "$(run_int merge_push_mins 0)" "$(run_str report_at x)" "$(run_str stop x)"' _ "$SCRIPTS")" \
    "2|parent:DEV-9|critical-path|20|07:30|17:00"
  eq "v420 run init: max_teams follows the team count, installs is allowed, and the rest of the file is as it was" \
    "$(grep -c '^max_teams = 2$' "$C"):$(grep -c '^max_teams = 5' "$C"):$(grep -c '^installs = "allow"$' "$C"):$(grep -c '^# my notes$' "$C"):$(grep -c '^label_prefix = "fleet:"$' "$C"):$(grep -c '^"claude-opus-5-5" = 200000$' "$C")" "1:0:1:1:1:1"
  eq "v420 run init: the top-level keys sit above the first table" "$(awk '/^\[/ {t = 1} !t && /^(max_teams|installs)/ {n++} END {print n}' "$C")" 2
  eq "v420 run show: prints the saved answers" "$("$SCRIPTS/run.sh" show | sed -n '1,2p;9,10p' | paste -sd, -)" "teams: 2,work: parent DEV-9,report_at: 07:30,stop: 17:00"
  printf '\n\n\n\n\n\n\n\n\n\n' >"$T/v420-answers"; cp "$C" "$T/v420-before"
  FLEET_RUN_ANSWERS="$T/v420-answers" "$SCRIPTS/run.sh" init >"$T/v420-out" 2>&1
  eq "v420 run init: a re-run shows the saved answers as the defaults, and Enter keeps them" "$(grep -c 'Teams to keep running \[2\]' "$T/v420-out"):$(grep -c 'Morning report time (local, HH:MM) \[07:30\]' "$T/v420-out"):$(cmp -s "$C" "$T/v420-before" && echo same)" "1:1:same"
  printf 'x\n' >"$T/v420-answers"; FLEET_RUN_ANSWERS="$T/v420-answers" "$SCRIPTS/run.sh" init >/dev/null 2>&1
  eq "v420 run init: an answer that is not one is refused, and the profile stays" "$?:$(cmp -s "$C" "$T/v420-before" && echo same)" "1:same"
  printf '3\nanything\ncritical-path\nwhole-first\nask\n10\n15\n10\n08:00\nnever\n' >"$T/v420-answers"
  FLEET_RUN_ANSWERS="$T/v420-answers" "$SCRIPTS/run.sh" init >/dev/null 2>&1
  eq "v420 run init: choosing ask removes installs from the top level" "$(grep -c '^installs' "$C")" 0
  out="$(bash -c '. "$1/common.sh"; config_warn_unknown' _ "$SCRIPTS" 2>&1)"
  eq "v420 run init: every key it writes is listed in config.example.toml (no unknown-key warning)" "$out" ""
  printf '[run]\nbogus = 1\n' >>"$C"
  eq "v420 run init: an unknown key in [run] is warned about" "$(bash -c '. "$1/common.sh"; config_warn_unknown' _ "$SCRIPTS" 2>&1 | grep -c "unknown key 'bogus' in \[run\]")" 1
  gcfg
}

v420_run_collide() { # a [run] key never answers a top-level reader, and an allowed install passes the guard
  v420_state collide
  local C="$FLEET_CONFIG_DIR/config.toml" BGH="$SCRIPTS/../../../hooks/fleet-bash-guard.sh"
  printf 'max_teams = 4\n\n[run]\nmax_teams = 9\nmachines = 3\novernight = true\nlabel_prefix = "x:"\n' >"$C"
  eq "v420 config: the top-level readers ignore the same keys inside [run]" \
    "$(bash -c '. "$1/common.sh"; printf "%s|%s|%s|%s" "$(cfg_int max_teams 0)" "$(cfg_int machines 1)" "$(cfg_bool overnight false)" "$(cfg_str label_prefix d)"' _ "$SCRIPTS")" "4|1|false|d"
  gcfg
  guard() { jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | FLEET_STATE_DIR="$FLEET_STATE_DIR" FLEET_ROLE=worker FLEET_TEAM=build-ft "$BGH" | jq -r '.hookSpecificOutput.permissionDecision // empty'; }
  eq "v420 installs: before init, a named install is denied" "$(guard 'npm install left-pad')" deny
  printf '3\nanything\ncritical-path\nwhole-first\nallow\n10\n15\n10\n08:00\nnever\n' >"$T/v420-answers"
  FLEET_RUN_ANSWERS="$T/v420-answers" "$SCRIPTS/run.sh" init >/dev/null 2>&1
  eq "v420 installs: after init chose allow, the same install passes the guard" "$(guard 'npm install left-pad'):x" ":x"
  gcfg
}

v420_smoke() { # the critical cases, CI
  v420_redact_gate
  v420_run_init
  v420_run_collide
}
v420_full() { # every case
  v420_smoke
}
