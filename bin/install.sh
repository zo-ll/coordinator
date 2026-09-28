#!/usr/bin/env bash
# install.sh: set filo up on this machine: the skill in every agent harness
# installed here, and the filo command on the PATH.
#
#   bin/install.sh              link this repo as <harness skills dir>/filo,
#                               and bin/filo as $FILO_BIN_DIR/filo (~/.local/bin)
#   bin/install.sh --uninstall  remove those links (only ours)
#
# A harness counts as installed when its home dir exists or its command is on
# the PATH; its skills dir is created if missing. The repo root is the skill,
# so it is linked as a directory: edits and `git pull` stay live. A filo link
# that points at nothing or at a filo checkout (a moved one, or another clone:
# the last install wins) is replaced; anything else named filo is left alone
# and reported. Safe to run again. FILO_SKILL_DIRS (colon-separated
# skills dirs, used when their parent dir exists) replaces the harness list.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${FILO_SKILL_NAME:-filo}"
BIN_DIR="${FILO_BIN_DIR:-$HOME/.local/bin}"

# the harnesses filo knows: skills dir | home dir | command (- for none: a
# name other programs use too, like pi or goose, only counts by its home dir)
HARNESSES=(
  "$HOME/.pi/agent/skills|$HOME/.pi|-"
  "$HOME/.agents/skills|$HOME/.agents|-"
  "$HOME/.claude/skills|$HOME/.claude|claude"
  "$HOME/.codex/skills|$HOME/.codex|codex"
  "$HOME/.config/opencode/skills|$HOME/.config/opencode|opencode"
  "$HOME/.config/crush/skills|$HOME/.config/crush|crush"
  "$HOME/.config/devin/skills|$HOME/.config/devin|devin"
  "$HOME/.config/goose/skills|$HOME/.config/goose|-"
  "$HOME/.codemaker/skills|$HOME/.codemaker|codemaker"
  "$HOME/.codestudio/skills|$HOME/.codestudio|codestudio"
  "$HOME/.commandcode/skills|$HOME/.commandcode|commandcode"
  "$HOME/.astrbot/data/skills|$HOME/.astrbot|astrbot"
)
if [ -n "${FILO_SKILL_DIRS:-}" ]; then
  HARNESSES=()
  IFS=':' read -r -a dirs <<< "$FILO_SKILL_DIRS"
  for d in "${dirs[@]}"; do HARNESSES+=("$d|$(dirname "$d")|-"); done
fi

mode=install
case "${1:-}" in
  --uninstall) mode=uninstall ;;
  "")          ;;
  *) echo "usage: install.sh [--uninstall]" >&2; exit 2 ;;
esac

say() { echo "$*" >&2; }
filo_checkout() { grep -qx "name: $NAME" "$1/SKILL.md" 2>/dev/null; }

# link <path> <target> <up>: make <path> a link to <target>. An existing link
# to a filo checkout (<up> dirs above what it points at), or to nothing, is
# replaced; anything else is left alone. Sets CHANGED, or FOREIGN on a skip.
link() {
  local l=$1 t=$2 up=$3 c i
  [ -L "$l" ] && [ "$(readlink -f "$l")" = "$(readlink -f "$t")" ] && return 0
  if [ -e "$l" ] || [ -L "$l" ]; then
    c=$(readlink -f "$l" 2>/dev/null || true)
    for (( i = 0; i < up; i++ )); do c=$(dirname "$c"); done
    if [ -L "$l" ] && { [ ! -e "$l" ] || filo_checkout "$c"; }; then
      say "replaced: $l (was -> $(readlink "$l"))"; rm -f "$l"
    else
      say "SKIP (exists, not ours): $l"; FOREIGN=$((FOREIGN + 1)); return 0
    fi
  fi
  ln -s "$t" "$l" 2>/dev/null || { say "SKIP (cannot link): $l"; FOREIGN=$((FOREIGN + 1)); return 0; }
  say "linked: $l -> $t"; CHANGED=1
}

# unlink <path> <target>: remove <path> if it is our link to <target>
unlink_ours() {
  local l=$1 t=$2
  if [ -L "$l" ] && [ "$(readlink -f "$l")" = "$(readlink -f "$t")" ]; then
    rm -f "$l"; say "removed: $l"; REMOVED=$((REMOVED + 1))
  elif [ -e "$l" ] || [ -L "$l" ]; then
    say "SKIP (not ours): $l"; FOREIGN=$((FOREIGN + 1))
  fi
}

CHANGED=0 FOREIGN=0 REMOVED=0 skills=0
for h in "${HARNESSES[@]}"; do
  IFS='|' read -r dir home cmd <<< "$h"
  if [ "$mode" = uninstall ]; then unlink_ours "$dir/$NAME" "$REPO"; continue; fi
  [ -d "$dir" ] || [ -d "$home" ] || { [ "$cmd" != - ] && command -v "$cmd" >/dev/null 2>&1; } || continue
  mkdir -p "$dir" 2>/dev/null || { say "SKIP (cannot create): $dir"; FOREIGN=$((FOREIGN + 1)); continue; }
  f=$FOREIGN; link "$dir/$NAME" "$REPO" 0
  [ "$FOREIGN" != "$f" ] || skills=$((skills + 1))
done

if [ "$mode" = uninstall ]; then
  unlink_ours "$BIN_DIR/filo" "$REPO/bin/filo"
  printf 'DONE removed=%s skipped=%s\n' "$REMOVED" "$FOREIGN"
  exit 0
fi

cli=skipped f=$FOREIGN
if mkdir -p "$BIN_DIR" 2>/dev/null; then
  link "$BIN_DIR/filo" "$REPO/bin/filo" 2
  [ "$FOREIGN" != "$f" ] || cli="$BIN_DIR/filo"
else
  say "SKIP (cannot create): $BIN_DIR"; FOREIGN=$((FOREIGN + 1))
fi
case ":$PATH:$cli" in
  *":$BIN_DIR:"*|*skipped) ;;
  *) say "$BIN_DIR is not on your PATH: add this to your shell's rc file: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac
[ "$CHANGED" = 1 ] || say "nothing to change: filo is already set up"
printf 'DONE skills=%s cli=%s skipped=%s\n' "$skills" "$cli" "$FOREIGN"
