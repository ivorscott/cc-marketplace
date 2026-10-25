#!/usr/bin/env bash
# slim: the fleet's panel style for herdr (styles/slim.toml), offered once (SKILL.md routes A and G).
#
#   slim.sh on | off | status
#
# on      backs herdr's config up (config.toml.fleet-bak.<time>), then writes styles/slim.toml between the markers
#         "# fleet slim:begin (developer <version>)" and "# fleet slim:end" (in place of an older block, else at the
#         end), installs herdr's Claude integration when it is not current, and reloads herdr's config. A reload that
#         fails puts the backup back (exit 1). A hand-written style outside the markers that declares a table slim
#         declares ([ui], [ui.sidebar.agents], [ui.sidebar.spaces]; TOML forbids a table twice) or sets one of its
#         keys is replaced: those tables (each up to the next table header) and lines go, and the reply names them.
# off     removes the marker block (backup first), keeps everything else and the integration, and reloads.
# status  one line: "Slim: on|off|conflict. herdr Claude integration: current|missing. Offer: due|done." (conflict:
#         off, and on would replace a hand-written style)
# on and off record the choice (registry.sh pref slim), so the offer is made once: it is due only while nothing is
# recorded and slim or the integration is missing. Outside the markers only the conflicting lines are ever edited. The
# Orchestrator's only: it refuses an agent (FLEET_ROLE set), and no agent's allow list has it.
# Config: ~/.config/herdr/config.toml (FLEET_HERDR_CONFIG overrides it, only with FLEET_TEST=1).
# Command: Turn the fleet's panel style for herdr on or off, or say if it is on · e.g. fleet slim status
set -euo pipefail
. "$(dirname "$0")/common.sh"
[ -z "${FLEET_ROLE:-}" ] || die "slim.sh is the Orchestrator's: an agent never changes herdr's config"
require_herdr
cfg="$HOME/.config/herdr/config.toml"
[ "${FLEET_TEST:-}" != 1 ] || cfg="${FLEET_HERDR_CONFIG:-$cfg}"
style="$FLEET_SKILL_DIR/styles/slim.toml"
begin="# fleet slim:begin"; end="# fleet slim:end"
[ -f "$style" ] || die "the slim style is missing: $style"

outside() { [ -f "$cfg" ] || return 0; awk -v b="$begin" -v e="$end" 'index($0, b) == 1 { inb = 1; next } index($0, e) == 1 { inb = 0; next } !inb' "$cfg"; }
has_block() { [ -f "$cfg" ] && grep -q "^$begin" "$cfg"; }
# conflicts: the lines outside the markers that declare a table slim declares, or set one of its keys (also as a
# dotted or inline ui key).
conflicts() {
  outside | grep -E '^[[:space:]]*(\[[[:space:]]*ui([[:space:]]*\.[[:space:]]*sidebar[[:space:]]*\.[[:space:]]*(agents|spaces))?[[:space:]]*\]|ui[[:space:]]*[=.]|(sidebar_width|status_indicators|agent_panel_sort)[[:space:]]*=)' || true
}
# without_conflicts: the config with those tables (from the header to the next one) and lines left out, the
# fleet's block kept.
without_conflicts() {
  awk -v b="$begin" -v e="$end" '
    index($0, b) == 1 { inb = 1 }
    inb { print; if (index($0, e) == 1) inb = 0; next }
    /^[[:space:]]*\[/ { drop = ($0 ~ /^[[:space:]]*\[[[:space:]]*ui([[:space:]]*\.[[:space:]]*sidebar[[:space:]]*\.[[:space:]]*(agents|spaces))?[[:space:]]*\][[:space:]]*(#.*)?$/) }
    drop { next }
    /^[[:space:]]*(ui[[:space:]]*[=.]|(sidebar_width|status_indicators|agent_panel_sort)[[:space:]]*=)/ { next }
    { print }' "$cfg"
}
backup() { [ -f "$cfg" ] || return 0; local b; b="$cfg.fleet-bak.$(date -u +%Y%m%dT%H%M%SZ)"; cp -p "$cfg" "$b" && printf '%s' "$b"; }
# write_cfg <with block: true|false>: the config with the fleet's block (in its old place, else at the end) or without.
write_cfg() {
  local tmp blk; tmp="$(mktemp "${cfg}.XXXXXX")"; blk="$(mktemp "${cfg}.blk.XXXXXX")"
  { printf '%s (developer %s)\n' "$begin" "$(plugin_version)"; cat "$style"; printf '%s\n' "$end"; } >"$blk"
  [ -f "$cfg" ] || : >"$cfg"
  awk -v b="$begin" -v e="$end" -v blk="$blk" -v with="$1" '
    index($0, b) == 1 { inb = 1; if (with == "true" && !done) { while ((getline l < blk) > 0) print l; done = 1 } next }
    index($0, e) == 1 { inb = 0; next }
    !inb { print; n++ }
    END { if (with == "true" && !done) { if (n > 0) print ""; while ((getline l < blk) > 0) print l } }' "$cfg" >"$tmp"
  mv "$tmp" "$cfg"; rm -f "$blk"
}
# reload_or_restore <backup>: herdr reads its config again; when it cannot, the backup goes back (or the new file
# goes, when there was none) and slim exits 1.
reload_or_restore() {
  hd server reload-config >/dev/null 2>&1 && return 0
  if [ -n "$1" ]; then cp -p "$1" "$cfg"; else rm -f "$cfg"; fi
  die "herdr did not reload its config, so the config was put back as it was" "Look at herdr's config, then run fleet slim again"
}

case "${1:-}" in
  on)
    c="$(conflicts)"
    mkdir -p "$(dirname "$cfg")"; b="$(backup)"
    # A hand-written style is replaced (the backup keeps it): its tables and keys go, then the block is written.
    replaced=""
    if [ -n "$c" ]; then
      replaced="$(printf '%s\n' "$c" | sed -E 's/^[[:space:]]*//; s/[[:space:]]*(=.*|#.*)$//' | awk '!seen[$0]++' | paste -sd, - | sed 's/,/, /g')"
      tmp="$(mktemp "${cfg}.XXXXXX")"; without_conflicts >"$tmp" && mv "$tmp" "$cfg"
    fi
    write_cfg true
    herdr_integration_ok || hd integration install claude >/dev/null 2>&1 || warn "could not install herdr's Claude integration (herdr integration install claude)"
    reload_or_restore "$b"
    "$FLEET_SCRIPTS/registry.sh" pref slim on >/dev/null
    render_line slim state=on backup="$b" replaced="$replaced" ;;
  off)
    b=""
    if has_block; then b="$(backup)"; write_cfg false; reload_or_restore "$b"; fi
    "$FLEET_SCRIPTS/registry.sh" pref slim off >/dev/null
    render_line slim state=off backup="$b" ;;
  status)
    s=off; ! has_block || s=on
    [ "$s" = on ] || [ -z "$(conflicts)" ] || s=conflict
    i=missing; ! herdr_integration_ok || i=current
    o="done"
    if [ -z "$("$FLEET_SCRIPTS/registry.sh" pref slim 2>/dev/null)" ] && { [ "$s" != on ] || [ "$i" != current ]; }; then o=due; fi
    render_line slim_status slim="$s" integration="$i" offer="$o" ;;
  *) die "usage: slim.sh on | off | status" "Run fleet help slim" ;;
esac
