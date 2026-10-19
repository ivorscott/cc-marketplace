#!/usr/bin/env bash
# PreToolUse hook (Bash) for /fleet agents. Inert unless FLEET_ROLE is set (only in panes /fleet booted):
# the Orchestrator and the user's own sessions are not fleet agents and are never restricted.
#
#   Every fleet agent: a command that names the Linear key (the file linear_api_key or the variable
#   LINEAR_API_KEY) is denied, and so is one that reaches the key's directory in any form:
#   ~/.config/fleet, $HOME/.config/fleet, ${XDG_CONFIG_HOME}/fleet, $FLEET_CONFIG_DIR, the absolute path
#   (as written or resolved), a glob whose fixed part is that directory or above it (~/.config/*,
#   ~/.config/fl*), `cd` into it or into its parent, and a recursive tool (grep -r, rg, find, ...) pointed
#   at a directory above it (~, $HOME, ~/.config).
#   `herdr pane run|send-text|send-keys` to any pane is denied (it types into someone else's shell).
#   `herdr agent prompt|send-keys|read` is allowed only to an agent of the agent's own team: the target must
#   be the herdr name of a row of FLEET_TEAM in the registry ($FLEET_STATE_DIR/fleet.json), exactly; prompt
#   and send-keys only for leads: a worker cannot drive anyone. A target that cannot be read off the command
#   (a variable, a substitution) is denied, and so is any target when the registry cannot be read.
#
# Command names are matched without regard to case (APFS: /opt/homebrew/bin/HERDR runs herdr, GREP runs grep).
# Deliberate evasion of a lexical guard (eval, variables, aliases, encodings, an interpreter such as python -c)
# is part of the documented residual.
# A guardrail, not a boundary: a command can build the key's name or path at run time, and the key file is
# mode 600 for the user the agents run as, so any same-uid process can read it.
set -u
input="$(cat 2>/dev/null || true)"
[ -n "${FLEET_ROLE:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
[ -n "$cmd" ] || exit 0

deny() { jq -n --arg r "$1" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'; exit 0; }

if printf '%s' "$cmd" | grep -qi 'linear_api_key'; then
  deny "fleet bash guard: the command names the Linear key; only the Orchestrator reads it."
fi


# --- the key's directory ------------------------------------------------------------------------------------
home="${HOME:-/nonexistent}"
xdg="${XDG_CONFIG_HOME:-$home/.config}"
kdir="${FLEET_CONFIG_DIR:-$xdg/fleet}"
kreal="$(cd "$kdir" 2>/dev/null && pwd -P || printf '%s' "$kdir")"
# Every path below is compared in lower case: APFS (macOS) ignores case, so ~/.CONFIG/Fleet is the key's directory.
kreal="$(printf '%s' "$kreal" | LC_ALL=C tr ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz)"
# lexnorm <absolute path>: collapse ".", ".." and repeated slashes, without touching the filesystem.
lexnorm() {
  local acc="" seg IFS=/
  set -f
  for seg in $1; do
    case "$seg" in "" | .) ;; ..) acc="${acc%/*}" ;; *) acc="$acc/$seg" ;; esac
  done
  set +f
  printf '%s\n' "${acc:-/}" | LC_ALL=C tr ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz
}
# at_or_above <dir>: the key's directory is <dir> or lies below it (as written or resolved).
at_or_above() {
  local d; d="$(lexnorm "$1")"
  case "$d" in /) return 0 ;; esac
  case "$(lexnorm "$kdir")/" in "$d"/*) return 0 ;; esac
  case "$kreal/" in "$d"/*) return 0 ;; esac
  return 1
}
flat="$(printf '%s' "$cmd" | tr -d "\"'\\\\")"
case "$flat" in
  *FLEET_CONFIG_DIR*) deny "fleet bash guard: the command reaches the Linear key's directory (\$FLEET_CONFIG_DIR); only the Orchestrator reads it." ;;
esac
if printf '%s' "$flat" | grep -qiE '\.config/+fleet([^a-z0-9_.-]|$)|XDG_CONFIG_HOME[}]?/+fleet([^a-z0-9_.-]|$)'; then
  deny "fleet bash guard: the command reaches the Linear key's directory (.config/fleet); only the Orchestrator reads it."
fi
recursive=false
# A recursive tool is looked for in EVERY word of the command, in one pass: no command-position parsing, so timeout,
# sudo -u me, xargs -0, nice, env -i, if, !, { } and the like need nothing special. Newlines and the shell's separators
# become a ";" word. A word's NAME is lower-cased once (one tr, so the tokens line up 1:1) and matched without regard
# to case, anywhere and unquoted: GREP, Find, /opt/x/RG. A word with a path counts only under a bin or sbin directory.
# A tool's flags are read exactly from the original words (ls -r is not ls -R) in a look-ahead of at most 20 words that
# stops at a separator, so the scan is linear. Over 400 words the command is refused. Two copies are scanned and
# either one denies: (1) quoted strings with a space in them are blanked (`git commit -m "Find it" ~` is prose) and
# the quote marks of a single-word string are dropped (`"grep" -r x ~`); (2) the command as written, so a quote that
# pairs oddly (awk -F'"' ...; grep -r x ~; echo "done") never hides a tool. Being conservative is accepted
# (`echo Tree ~` and `echo grep -r ~` are denied; agents quote their prose).
re_grep='^-[a-zA-Z]*[rR]'; re_ls='^-[a-zA-Z]*R'; re_cp='^-[a-zA-Z]*[rRa]'
scan_recursive() { # scan_recursive <text>: sets recursive=true when a recursive tool is found
  local nq lq n i j w l tool kind
  local -a ow lw
  nq="$(printf '%s' "$1" | tr '\n' ';' | sed -E 's/[;&|(){}<>]/ ; /g')"
  lq="$(printf '%s' "$nq" | LC_ALL=C tr ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz)"
  set -f; read -r -a ow <<<"$nq"; read -r -a lw <<<"$lq"; set +f
  n="${#lw[@]}"
  [ "$n" -le 400 ] || deny "fleet bash guard: command too long for the fleet guard; split it."
  i=0
  while [ "$i" -lt "$n" ]; do
    w="${ow[$i]}"; l="${lw[$i]}"; i=$((i + 1))
    tool="${l##*/}"
    case "$w" in */*) case "$w" in */bin/* | */sbin/*) ;; *) continue ;; esac ;; esac
    kind=""
    case "$tool" in
      rg | ag | ack | find | fd | tar | zip | rsync | du | tree | gfind | gtar) recursive=true; return 0 ;;
      grep | egrep | fgrep | zgrep | ggrep) kind=grep ;;
      ls | gls) kind=ls ;;
      cp | gcp) kind=cp ;;
      *) continue ;;
    esac
    j=$i
    while [ "$j" -lt "$n" ] && [ "$j" -lt $((i + 20)) ] && [ "${ow[$j]}" != ";" ]; do
      w="${ow[$j]}"; j=$((j + 1))
      case "$kind" in
        grep) if [[ $w =~ $re_grep ]] || [ "$w" = --recursive ] || [ "$w" = --dereference-recursive ] || { [ "$w" = -d ] && [ "${ow[$j]:-}" = recurse ]; }; then recursive=true; return 0; fi ;;
        ls) if [[ $w =~ $re_ls ]]; then recursive=true; return 0; fi ;;
        cp) if [[ $w =~ $re_cp ]]; then recursive=true; return 0; fi ;;
      esac
    done
  done
}
blanked="$(printf '%s' "$cmd" | sed -E "s/\"([^\" ]*)\"/\1/g; s/'([^' ]*)'/\1/g; s/\"[^\"]*\"/ /g; s/'[^']*'/ /g")"
scan_recursive "$blanked"
$recursive || scan_recursive "$cmd"
prev=""
set -f # the words are looked at, never expanded: ~/.config/* stays a pattern
for w in $(printf '%s' "$flat" | tr ';&|()<>' '       '); do
  t="$w"
  case "$t" in
    "~") t="$home" ;; "~/"*) t="$home/${t#"~/"}" ;;
    '$HOME' | '${HOME}') t="$home" ;; '$HOME/'*) t="$home/${t#'$HOME/'}" ;; '${HOME}/'*) t="$home/${t#'${HOME}/'}" ;;
    '$XDG_CONFIG_HOME' | '${XDG_CONFIG_HOME}') t="$xdg" ;; '$XDG_CONFIG_HOME/'*) t="$xdg/${t#'$XDG_CONFIG_HOME/'}" ;; '${XDG_CONFIG_HOME}/'*) t="$xdg/${t#'${XDG_CONFIG_HOME}/'}" ;;
    *=/* | *=~*) t="${t#*=}"; case "$t" in "~") t="$home" ;; "~/"*) t="$home/${t#"~/"}" ;; esac ;;
  esac
  case "$t" in /*) ;; *) prev="$w"; continue ;; esac
  fixed="$t"; globbed=false
  case "$t" in *[*?[{]*) globbed=true; fixed="${t%%[*?[{]*}"; fixed="${fixed%/*}"; [ -n "$fixed" ] || fixed=/ ;; esac
  n="$(lexnorm "$t")"
  # The key's directory itself, or anything inside it.
  case "$n/" in "$(lexnorm "$kdir")/"* | "$kreal/"*) deny "fleet bash guard: $w is the Linear key's directory; only the Orchestrator reads it." ;; esac
  # A glob that can reach it.
  if $globbed && at_or_above "$fixed"; then deny "fleet bash guard: $w can reach the Linear key's directory; name a narrower path."; fi
  # cd into the parent of the key's directory (then a relative path reaches it).
  case "$prev" in cd | pushd) [ "$n" != "$(lexnorm "$(dirname "$kdir")")" ] && [ "$n" != "$(dirname "$kreal")" ] || deny "fleet bash guard: cd $w puts the Linear key's directory one step away; only the Orchestrator reads it." ;; esac
  # A recursive tool over a directory above it.
  if $recursive && at_or_above "$n"; then deny "fleet bash guard: a recursive command over $w would read the Linear key's directory; name a narrower path."; fi
  prev="$w"
done
set +f

# --- herdr ---------------------------------------------------------------------------------------------------
shopt -s nocasematch; case "$cmd" in *herdr*) ;; *) exit 0 ;; esac; shopt -u nocasematch
team="${FLEET_TEAM:-}"
reg="${FLEET_STATE_DIR:-${XDG_STATE_HOME:-$home/.local/state}/fleet}/fleet.json"
# The herdr names of the team's agents, one per line, read from the registry; empty when it cannot be read.
mates=""; [ -z "$team" ] || mates="$(jq -r --arg t "$team" '.agents[]? | select(.team == $t and .status != "Retired") | .herdr_ref // empty' "$reg" 2>/dev/null || true)"

# One segment per simple command: split on ; & | ( ) and newlines.
while IFS= read -r seg; do
  read -r -a w <<<"${seg//[\"\'\`]/ }"
  i=0
  while [ "$i" -lt "${#w[@]}" ]; do
    shopt -s nocasematch; case "${w[$i]##*/}" in herdr) hit=true ;; *) hit=false ;; esac; shopt -u nocasematch
    $hit || { i=$((i + 1)); continue; }
    i=$((i + 1))
    while [ "$i" -lt "${#w[@]}" ]; do # herdr's own options before the group
      case "${w[$i]}" in --session | --socket) i=$((i + 2)) ;; --*) i=$((i + 1)) ;; *) break ;; esac
    done
    group="${w[$i]:-}"; sub="${w[$((i + 1))]:-}"; target="${w[$((i + 2))]:-}"
    case "$group $sub" in
      "pane run" | "pane send-text" | "pane send-keys")
        deny "fleet bash guard: herdr $group $sub types into a pane, which fleet agents may not do." ;;
      "pane read")
        deny "fleet bash guard: herdr pane read shows another pane's screen; use herdr agent read on an agent of your own team." ;;
      "agent prompt" | "agent send-keys" | "agent read")
        if [ "$sub" != read ] && [ "${FLEET_ROLE:-}" != lead ]; then
          deny "fleet bash guard: only a lead may herdr agent $sub, and only to its own team."
        fi
        case "$target" in
          "" | -* | *'$'* | *'~'*) deny "fleet bash guard: herdr agent $sub needs a literal agent name of your own team." ;;
        esac
        [ -n "$team" ] || deny "fleet bash guard: no team known for this agent."
        [ -n "$mates" ] || deny "fleet bash guard: cannot read the registry to check $target is of your team (${FLEET_TEAM:-none})."
        printf '%s\n' "$mates" | grep -qxF -- "$target" || deny "fleet bash guard: $target is not an agent of your team (${FLEET_TEAM:-none})." ;;
    esac
  done
done < <(printf '%s\n' "$cmd" | tr ';&|()' '\n\n\n\n\n')
exit 0
