#!/usr/bin/env bash
# PreToolUse hook (Bash) for /fleet agents. Inert unless FLEET_ROLE is set (only in panes /fleet booted):
# the Orchestrator and the user's own sessions are not fleet agents and are never restricted.
#
#   Every fleet agent: a command that names the Linear key (the file linear_api_key or the variable
#   LINEAR_API_KEY) is denied, and so is one that reaches the key's directory in any form:
#   ~/.config/fleet, $HOME/.config/fleet, ${XDG_CONFIG_HOME}/fleet, $FLEET_CONFIG_DIR, the absolute path
#   (as written or resolved), a glob whose fixed part is that directory or above it (~/.config/*,
#   ~/.config/fl*, quoted or not; not one in the body of a heredoc that a plain cat or tee writes to a file), `cd`
#   into it or into its parent, and a recursive tool (grep -r, rg, find, ...) pointed
#   at a directory above it (~, $HOME, ~/.config).
#   `herdr pane run|send-text|send-keys` to any pane is denied (it types into someone else's shell).
#   `herdr agent prompt|send-keys|read` is allowed only to an agent of the agent's own team: the target must
#   be the herdr name of a row of FLEET_TEAM in the registry ($FLEET_STATE_DIR/fleet.json), exactly; prompt
#   and send-keys only for leads: a worker cannot drive anyone. A target that cannot be read off the command
#   (a variable, a substitution) is denied, and so is any target when the registry cannot be read.
#
#   Every fleet agent also: package installers are denied (brew/npm/pnpm/yarn/pip/go/gem/cargo/apt install of
#   a named package) unless config.toml has installs = "allow"; installs from a lockfile pass (npm ci, bundle
#   install, go mod download, pip install -r). `gh pr merge` is denied, a git push with --force or -f (or a
#   +refspec) is denied (--force-with-lease is the way), and so is a push to the default branch.
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
# There is no size cap: the scan is one pass over the words, however many there are.
# A recursive tool is looked for in EVERY word of the command, in one pass: no command-position parsing, so timeout,
# sudo -u me, xargs -0, nice, env -i, if, !, { } and the like need nothing special. Newlines and the shell's separators
# become a ";" word. A word's NAME is lower-cased once (one tr, so the tokens line up 1:1) and matched without regard
# to case, anywhere: GREP, Find, /opt/x/RG. A word with a path counts only under a bin or sbin directory (tested on
# the lower-cased word, so /USR/BIN/GREP counts). A tool seen stays pending until the next separator, and each later
# word is checked against its flags, exactly as written (ls -r is not ls -R): one pass, no rescanning. Three copies are
# scanned and any one denies: (1) quoted strings with a space in them blanked (`git commit -m "Find it" ~` is prose),
# the quote marks of a single-word string dropped (`"grep" -r x ~`); (2) the command as written, so an odd quote pairing
# (awk -F'"' ...; grep -r x ~; echo "done") never hides a tool; (3) the command with quotes, backslashes, backticks and
# $( ) deleted, not blanked or split (\grep -r x ~, $(which grep) -r x ~, watch "grep -r x ~"), where only lower-case
# tool names count (as at 5abc448; copies 1 and 2 catch the other cases). Conservative on purpose (`echo Tree ~`
# is denied; agents quote their prose).
re_grep='^-[a-zA-Z]*[rR]'; re_ls='^-[a-zA-Z]*R'; re_cp='^-[a-zA-Z]*[rRa]'
scan_recursive() { # scan_recursive <text> <fold: 1 = any case, 0 = lower case only>: sets recursive=true on a hit
  local nq lq n i w l tool pg=false pl=false pc=false pw=""
  local -a ow lw
  nq="$(printf '%s' "$1" | tr '\n' ';' | sed -E 's/[;&|(){}<>`]/ ; /g')"
  lq="$(printf '%s' "$nq" | LC_ALL=C tr ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz)"
  set -f; read -r -a ow <<<"$nq"; read -r -a lw <<<"$lq"; set +f
  n="${#lw[@]}"
  i=0
  while [ "$i" -lt "$n" ]; do
    w="${ow[$i]}"; l="${lw[$i]}"; i=$((i + 1))
    # The word as the shell would see it: wrapping quote marks and leading backslashes dropped (\grep, "grep", \Find).
    case "$l" in \"?*\" | \'?*\') l="${l#?}"; l="${l%?}" ;; esac # a word wrapped in quotes; a lone quote mark is prose
    l="${l#"${l%%[!\\]*}"}"
    if [ "$w" = ";" ]; then pg=false; pl=false; pc=false; pw=""; continue; fi
    if $pg && { [[ $w =~ $re_grep ]] || [ "$w" = --recursive ] || [ "$w" = --dereference-recursive ] || { [ "$pw" = -d ] && [ "$w" = recurse ]; }; }; then recursive=true; return 0; fi
    if $pl && [[ $w =~ $re_ls ]]; then recursive=true; return 0; fi
    if $pc && [[ $w =~ $re_cp ]]; then recursive=true; return 0; fi
    pw="$w"
    tool="${l##*/}"
    case "$l" in */*) case "$l" in */bin/* | */sbin/*) ;; *) continue ;; esac ;; esac
    [ "$2" = 1 ] || [ "${w##*/}" = "$tool" ] || continue # fold = 0: lower-case names only
    case "$tool" in
      rg | ag | ack | find | fd | tar | zip | rsync | du | tree | gfind | gtar) recursive=true; return 0 ;;
      grep | egrep | fgrep | zgrep | ggrep) pg=true ;;
      ls | gls) pl=true ;;
      cp | gcp) pc=true ;;
    esac
  done
}
blanked="$(printf '%s' "$cmd" | sed -E "s/\"([^\" ]*)\"/\1/g; s/'([^' ]*)'/\1/g; s/\"[^\"]*\"/ /g; s/'[^']*'/ /g")"
flat3="$(printf '%s' "$cmd" | tr -d "\"'\\\\\`\$()")"
scan_recursive "$blanked" 1
$recursive || scan_recursive "$cmd" 1
$recursive || scan_recursive "$flat3" 0
# word_path <word>: sets WP to the absolute path the word names (~, $HOME and $XDG_CONFIG_HOME spelled out, also after a
# VAR=), or to nothing for a relative one. No subshell: it runs once per word.
word_path() {
  WP="$1"
  case "$WP" in
    "~") WP="$home" ;; "~/"*) WP="$home/${WP#"~/"}" ;;
    '$HOME' | '${HOME}') WP="$home" ;; '$HOME/'*) WP="$home/${WP#'$HOME/'}" ;; '${HOME}/'*) WP="$home/${WP#'${HOME}/'}" ;;
    '$XDG_CONFIG_HOME' | '${XDG_CONFIG_HOME}') WP="$xdg" ;; '$XDG_CONFIG_HOME/'*) WP="$xdg/${WP#'$XDG_CONFIG_HOME/'}" ;; '${XDG_CONFIG_HOME}/'*) WP="$xdg/${WP#'${XDG_CONFIG_HOME}/'}" ;;
    *=/* | *=~*) WP="${WP#*=}"; case "$WP" in "~") WP="$home" ;; "~/"*) WP="$home/${WP#"~/"}" ;; esac ;;
  esac
  case "$WP" in /*) ;; *) WP="" ;; esac
}
prev=""
set -f # the words are looked at, never expanded: ~/.config/* stays a pattern
for w in $(printf '%s' "$flat" | tr ';&|()<>' '       '); do
  word_path "$w"; t="$WP"
  [ -n "$t" ] || { prev="$w"; continue; }
  n="$(lexnorm "$t")"
  # The key's directory itself, or anything inside it.
  case "$n/" in "$(lexnorm "$kdir")/"* | "$kreal/"*) deny "fleet bash guard: $w is the Linear key's directory; only the Orchestrator reads it." ;; esac
  # cd into the parent of the key's directory (then a relative path reaches it).
  case "$prev" in cd | pushd) [ "$n" != "$(lexnorm "$(dirname "$kdir")")" ] && [ "$n" != "$(dirname "$kreal")" ] || deny "fleet bash guard: cd $w puts the Linear key's directory one step away; only the Orchestrator reads it." ;; esac
  # A recursive tool over a directory above it.
  if $recursive && at_or_above "$n"; then deny "fleet bash guard: a recursive command over $w would read the Linear key's directory; name a narrower path."; fi
  prev="$w"
done
# A glob that can reach it, read on the command flattened as for the other rules (quotes and backslashes deleted):
# quoted text counts, since bash -c, sh -c, eval, an interpreter or a shell reading stdin expands it. One body is left
# out: that of a heredoc on a line whose command is cat or tee and that neither pipes on nor sits in $(...), `...` or a
# process substitution, the write-a-file shape (cat > ident.ts <<'EOF' with a JS regex such as /[A-Za-z]{3,}/ in it).
# The lines after <<WORD, <<'WORD' or <<-WORD up to WORD go. A body fed to anything else is still read.
globtext="$(printf '%s\n' "$cmd" | awk '
  inb { t = $0; if (strip) sub(/^\t+/, "", t); if (t == word) inb = 0; next }
  { print
    if ($0 ~ /^[[:space:]]*([^[:space:]]*\/)?(cat|tee)[[:space:]]/ && $0 !~ /[|`]|\$\(|[<>]\(/ &&
      match($0, /(^|[^<])<<-?[[:space:]]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/)) {
      m = substr($0, RSTART, RLENGTH); sub(/^[^<]*<</, "", m); strip = (m ~ /^-/); sub(/^-?[[:space:]]*/, "", m); gsub(/["\047]/, "", m)
      word = m; inb = 1 } }' | tr -d "\"'\\\\")"
for w in $(printf '%s' "$globtext" | tr ';&|()<>' '       '); do
  case "$w" in *[*?[{]*) ;; *) continue ;; esac
  word_path "$w"; t="$WP"
  [ -n "$t" ] || continue
  fixed="${t%%[*?[{]*}"; fixed="${fixed%/*}"; [ -n "$fixed" ] || fixed=/
  if at_or_above "$fixed"; then deny "fleet bash guard: $w can reach the Linear key's directory; name a narrower path."; fi
done
set +f

# --- installers, merges and pushes (every fleet agent) ---------------------------------------------------------
# Matched on the command position of each simple command (split on ; & | ( ) and newlines), after leading
# VAR=value words and sudo/command/env. `installs = "allow"` in config.toml turns the installer rule off.
installs=deny
cfg="${FLEET_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/fleet}/config.toml"
if [ -f "$cfg" ] && sed -n 's/^[[:space:]]*installs[[:space:]]*=[[:space:]]*"\([a-z]*\)".*/\1/p' "$cfg" | head -1 | grep -qx allow; then installs=allow; fi

default_branches() { # main, master and whatever origin/HEAD points at
  printf 'main\nmaster\n'
  git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##'
}
is_default_branch() { default_branches | grep -Fxq -- "$1"; }

check_install() { # check_install <words...>: deny a package installer unless it installs from a lockfile
  [ "$installs" = allow ] && return 0
  local tool="${1##*/}" sub="${2:-}" a pkgs=0 lock=0 skip=1
  case "$tool" in python | python3 | python3.*) if [ "$sub" = -m ] && [ "${3:-}" = pip ]; then shift 2; tool=pip; sub="${2:-}"; else return 0; fi ;; esac
  case "$tool $sub" in
    "brew install" | "brew reinstall" | "go install" | "gem install" | "cargo install" | "apt install" | "apt-get install" | "yarn add" | "pnpm add" | "npm add")
      deny "fleet bash guard: $tool $sub installs software; say what is needed in your report and let the owner run it (config installs = \"allow\" lifts this)." ;;
    "npm i" | "npm install" | "pnpm install" | "pnpm i" | "yarn install")
      set -- "${@:3}"
      while [ $# -gt 0 ]; do
        case "$1" in --prefix | --workspace | -w | --registry | --cwd | --dir | -C) shift 2; continue ;; -*) ;; *) pkgs=1 ;; esac
        shift
      done
      [ "$pkgs" = 0 ] || deny "fleet bash guard: $tool $sub <package> adds a dependency; install from the lockfile (npm ci) or report the need." ;;
    "pip install" | "pip3 install")
      for a in "${@:3}"; do case "$a" in -r | --requirement | -r* | --requirement=*) lock=1 ;; esac; done
      [ "$lock" = 1 ] || deny "fleet bash guard: $tool install <package> installs software; use -r with a lockfile or report the need." ;;
  esac
}

check_git_push() { # check_git_push <words after "git push">
  local a force=0 lease=0 refs=0 cur ref
  for a in "$@"; do
    case "$a" in
      --force-with-lease | --force-with-lease=* | --force-if-includes) lease=1 ;;
      --force | -f) force=1 ;;
      --*) ;;
      -*f*) force=1 ;;
      -*) ;;
    esac
  done
  [ "$force" = 0 ] || deny "fleet bash guard: a bare force push can overwrite work; use git push --force-with-lease origin <branch>."
  local pos=0
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    pos=$((pos + 1)); [ "$pos" -ge 2 ] || continue
    refs=1; ref="${a#+}"
    [ "$ref" = "$a" ] || deny "fleet bash guard: a +refspec forces the push; use --force-with-lease."
    ref="${ref##*:}"; ref="${ref#refs/heads/}"
    if is_default_branch "$ref"; then deny "fleet bash guard: agents never push to the default branch ($ref); push your fleet/<slug> branch."; fi
    [ "$ref" != HEAD ] || { cur="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"; [ -z "$cur" ] || ! is_default_branch "$cur" || deny "fleet bash guard: HEAD is the default branch ($cur); agents never push to it."; }
  done
  if [ "$refs" = 0 ]; then # a bare `git push`: pushes the current branch
    cur="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
    [ -z "$cur" ] || ! is_default_branch "$cur" || deny "fleet bash guard: you are on the default branch ($cur); agents never push to it."
  fi
  : "$lease"
}

# ln: no link or hard link whose operand ends in node_modules, .venv or vendor (an install is run in the worktree itself).
check_ln() {
  local a b
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    b="${a%"${a##*[!/]}"}"; b="${b##*/}"
    case "$b" in
      node_modules | .venv | vendor) deny "fleet bash guard: link nothing to another checkout's node_modules/.venv/vendor; run npm ci (or the lockfile install) in your own worktree." ;;
    esac
  done
}

while IFS= read -r seg; do
  read -r -a w <<<"$seg" # quotes were turned into spaces once, below (${seg//...} is quadratic on bash 3.2)
  i=0
  while [ "$i" -lt "${#w[@]}" ]; do
    case "${w[$i]}" in *=* | sudo | command | env | exec | nohup | time) i=$((i + 1)) ;; *) break ;; esac
  done
  [ "$i" -lt "${#w[@]}" ] || continue
  # Only git, gh and the installers are checked here: any other command word is skipped before its words are copied,
  # so a long echo or a long quoted body costs one pass (the key's directory was already checked above).
  case "${w[$i]##*/}" in ln | git | gh | brew | go | gem | cargo | apt | apt-get | yarn | pnpm | npm | pip | pip3 | python | python3 | python3.*) ;; *) continue ;; esac
  # Redirections are not arguments: drop 2>, >/dev/null, 2>&1's leftover and the word after a bare > or <.
  # One awk pass (no rest+=, which is quadratic on bash 3.2).
  read -r -a rest <<<"$(printf '%s\n' "${w[@]:$i}" | awk 'skip { skip = 0; next } /^[0-9]*[<>]/ { if ($0 ~ /[<>]$/) skip = 1; next } { printf "%s ", $0 }')"
  [ "${#rest[@]}" -gt 0 ] || continue
  case "${rest[0]##*/}" in
    git)
      j=1; while [ "$j" -lt "${#rest[@]}" ]; do # git's own options before the subcommand
        case "${rest[$j]}" in -C | -c | --git-dir | --work-tree) j=$((j + 2)) ;; -*) j=$((j + 1)) ;; *) break ;; esac
      done
      if [ "${rest[$j]:-}" = push ]; then check_git_push "${rest[@]:$((j + 1))}"; fi ;;
    gh)
      if [ "${rest[1]:-}" = pr ] && [ "${rest[2]:-}" = merge ]; then
        deny "fleet bash guard: agents never merge a PR; the merger (config merger, default a human) does."
      fi ;;
    ln) check_ln "${rest[@]:1}" ;;
    *) check_install "${rest[@]}" ;;
  esac
done < <(printf '%s\n' "$cmd" | awk -v sq="'" '
  # ; & | ( ) inside a quoted string do not end a command: blank them before the split.
  # One pass, printed as it goes (no string rebuilt per character).
  { n = length($0); for (i = 1; i <= n; i++) { c = substr($0, i, 1)
      if (q == "") { if (c == "\"" || c == sq) q = c }
      else if (c == q) q = ""
      else if (c == ";" || c == "&" || c == "|" || c == "(" || c == ")") c = " "
      printf "%s", c }
    printf "\n" }' | tr ";&|()\"'\`" '\n\n\n\n\n   ')



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
