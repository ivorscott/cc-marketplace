#!/usr/bin/env bash
# 4.2.16 (DEV-1106): layered fleet rules (house, company layer, repo) and `fleet rules check`. Sourced by run.sh after v4215.sh,
# whose helpers it uses (ok, eq, check, gcfg, v413_state, v413_agent, REG, SCRIPTS, T). Fake repos in a temp dir; generic names only.
v4216_repo() { # v4216_repo <name> [<fleet-rules text>]: a fake repo dir under $T, with a .claude/fleet-rules.md when text is given
  local d="$T/v4216/$1"; rm -rf "$d"; mkdir -p "$d/.claude"
  [ $# -lt 2 ] || printf '%s\n' "$2" >"$d/.claude/fleet-rules.md"
  printf '%s' "$d"
}
v4216_rc() { "$SCRIPTS/rules.sh" "$@" >/dev/null 2>&1; echo $?; } # the exit status alone

v4216_check() {
  local R="$SCRIPTS/../rules" out d eth
  gcfg
  eq "v4216 check: a repo with only its own rules passes" "$(v4216_rc "$(v4216_repo clean '## Statechart-first

A change that adds an entity with states also adds its chart, in the same PR, and the tester fails the PR without it.')")" 0
  eq "v4216 check: a repo with no rules file passes" "$(v4216_rc "$(v4216_repo nofile)")" 0
  eth="$(awk '/^## Section A/ { p = 1 } /^## Section B/ { p = 0 } p' "$R/company.md" | sed 's/ *(prevents [^)]*)//')"
  d="$(v4216_repo dup "$eth")"; out="$("$SCRIPTS/rules.sh" "$d" 2>&1)"
  eq "v4216 check: a repeated block exits 1" "$(v4216_rc "$d")" 1
  eq "v4216 check: and the finding names the block" "$(printf '%s\n' "$out" | grep -c 'repeats company.md "Section A"')" 1
  d="$(v4216_repo redef '## Section B

- Our own way of filing that has nothing in common with the central text at all.')"; out="$("$SCRIPTS/rules.sh" "$d" 2>&1 || true)"
  eq "v4216 check: a central title with a different body is a redefinition" "$(printf '%s\n' "$out" | grep -c 'redefines company.md "Section B"')" 1
  eq "v4216 check: lines under 20 characters are ignored" "$(v4216_rc "$(v4216_repo short '## Local

- Be kind.
- Run make.')")" 0
  d="$(v4216_repo big "## Local

$(awk 'BEGIN { for (i = 0; i < 400; i++) printf "- repo line number %d says something only this repo needs to hear\n", i }')")"
  eq "v4216 check: a repo file past the 8 KB budget exits 1" "$(v4216_rc "$d"):$("$SCRIPTS/rules.sh" "$d" 2>&1 | grep -c 'over the budget')" "1:1"
  eq "v4216 check: a bad directory exits 2" "$(v4216_rc "$T/v4216/nosuch")" 2
  local S="$T/v4216-skill"; rm -rf "$S"; mkdir -p "$S"; cp -R "$SCRIPTS/.." "$S/fleet" 2>/dev/null; rm -f "$S/fleet/rules/house.md"
  eq "v4216 check: a missing house.md exits 2" "$("$S/fleet/scripts/rules.sh" "$(v4216_repo any)" >/dev/null 2>&1; echo $?)" 2
  eq "v4216 check: --line prints the one boot line" "$("$SCRIPTS/rules.sh" --line "$(v4216_repo line)" | grep -cE '^Rules [0-9.]+ KB of 8.0 KB, check ok$')" 1
  eq "v4216 check: --line counts the findings" "$("$SCRIPTS/rules.sh" --line "$(v4216_repo dup2 "$eth")" | grep -cE '^Rules check: [0-9]+ findings \(fleet rules check ')" 1
  gcfg 'company_rules = "none"'
  eq "v4216 check: company_rules none drops the layer, so the repeat is not one" "$(v4216_rc "$(v4216_repo dup3 "$eth")")" 0
  gcfg
}

v4216_layers() {
  local hr own
  v413_state lay; v413_agent n1/lead Lead Working
  own="$(v4216_repo lay '## Local

- A repo line of its own, about twenty characters or more.')"
  "$REG" set n1/lead repo="$own" >/dev/null
  hr() { bash -c '. "$1/common.sh"; house_rules n1/lead' _ "$SCRIPTS"; }
  gcfg
  eq "v4216 layers: house, then the company layer, then the repo file" \
    "$(hr | grep -nE '^(House rules \(fleet\)|Company rules|Repository rules \()' | cut -d: -f2 | cut -c1-12 | tr '\n' '|')" "House rules |Company rule|Repository r|"
  gcfg 'company_rules = "none"'
  eq "v4216 layers: company_rules none drops the layer and keeps the other two" \
    "$(hr | grep -cE '^Company rules'):$(hr | grep -cE '^House rules \(fleet\)'):$(hr | grep -cE '^Repository rules \(')" "0:1:1"
  gcfg 'installs = "allow"'
  eq "v4216 layers: installs allow still rewrites the install rule after the trim" \
    "$(hr | grep -c 'Install what the work needs yourself. List each install in your report (what, where, why)'):$(hr | grep -c '^- Installing is allowed only when')" "1:0"
  gcfg
}

v4216_size() {
  eq "v4216 size: house.md stays at most 3.5 KB" "$([ "$(wc -c <"$SCRIPTS/../rules/house.md")" -le 3500 ] && echo ok)" ok
  eq "v4216 size: the rules an agent gets with no repo file stay under the 8 KB budget" \
    "$(bash -c '. "$1/common.sh"; echo $(( $(rules_bytes house) + $(rules_bytes layer) + $(rules_bytes contract) ))' _ "$SCRIPTS" | awk '$1 < 8192 { print "ok" }')" ok
  eq "v4216 size: the build lead brief holds the rules moved out of house.md" \
    "$(jq -r '.lead.brief' "$SCRIPTS/../templates/build.json" | grep -c 'Review rounds:.*One PR per coupled feature:.*Test sizing:')" 1
}

v4216_smoke() { v4216_size; v4216_check; v4216_layers; }
v4216_full() { v4216_smoke; }
