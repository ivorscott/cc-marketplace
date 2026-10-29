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
  eq "v420 redact: a visibility gh cannot read counts as public" "$(GH_VIS= rr | paste -sd' ' -)" "Redact check main..feat: 1 matches. rc=1"
  gcfg 'public_repos = ["acme/app"]'
  eq "v420 redact: public_repos wins over what gh says" "$(GH_VIS=PRIVATE rr | paste -sd' ' -)" "Redact check main..feat: 1 matches. rc=1"
  gcfg 'private_repos = ["acme/app"]'
  eq "v420 redact: private_repos is read before gh is asked" "$(GH_VIS= rr | paste -sd' ' -)" "Redact check main..feat: skipped (private repo). rc=0"
  gcfg
  rm -rf "$S/private"
  eq "v420 redact: a public repo with no terms file is still exit 2, never clean" "$(GH_VIS=PUBLIC rr | tail -1)" "rc=2"
  eq "v420 redact: a private repo needs no terms file" "$(GH_VIS=PRIVATE rr | tail -1)" "rc=0"
}

v420_smoke() { # the critical cases, CI
  v420_redact_gate
}
v420_full() { # every case
  v420_smoke
}
