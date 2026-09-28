#!/usr/bin/env bash
# install.sh: the skill in every installed harness and the filo command on the
# PATH, stale links repaired, foreign ones kept, idempotent, and uninstall.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$HERE/../bin/install.sh"
REPO="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }
has() { case "$1" in *"$2"*) ;; *) echo "  expected '$2' in: $1"; exit 1 ;; esac; }
ours() { [ "$(readlink -f "$1")" = "$(readlink -f "$2")" ] || { echo "  $1 is not linked to $2"; exit 1; }; }

# a machine: claude has its home dir, codex only its command, goose neither
export HOME="$TMP/home"
mkdir -p "$HOME/.claude" "$TMP/fakebin"
printf '#!/bin/sh\n' > "$TMP/fakebin/codex"; chmod +x "$TMP/fakebin/codex"
# a PATH of only the tools needed, so this machine's own commands (a /usr/bin/pi,
# a /usr/bin/goose) can't count as harnesses
for t in bash sh env dirname readlink grep mkdir ln rm cat chmod touch rmdir head sed awk tr cut sort; do
  ln -s "$(command -v "$t")" "$TMP/fakebin/$t"
done
export PATH="$TMP/fakebin"
unset FILO_SKILL_DIRS FILO_BIN_DIR

out="$("$INSTALL" 2>"$TMP/err")"
assert "$out" "DONE skills=2 cli=$HOME/.local/bin/filo skipped=0"
ours "$HOME/.claude/skills/filo" "$REPO"
ours "$HOME/.codex/skills/filo" "$REPO"                      # skills dir created for an installed command
[ ! -e "$HOME/.config/goose" ] || { echo "  goose is not installed"; exit 1; }
ours "$HOME/.local/bin/filo" "$REPO/bin/filo"
has "$(cat "$TMP/err")" "$HOME/.local/bin is not on your PATH"
has "$(PATH="$HOME/.local/bin:$PATH" filo help | head -n1)" "filo: the coordinator engine"

# idempotent, and says so
out="$(PATH="$HOME/.local/bin:$PATH" "$INSTALL" 2>"$TMP/err")"
assert "$out" "DONE skills=2 cli=$HOME/.local/bin/filo skipped=0"
assert "$(cat "$TMP/err")" "nothing to change: filo is already set up"

# a link left by a moved checkout, or by a deleted one, is repaired
rm "$HOME/.claude/skills/filo"; ln -s "$TMP/old-checkout" "$HOME/.claude/skills/filo"   # deleted
mkdir -p "$TMP/moved/bin"; printf -- '---\nname: filo\n---\n' > "$TMP/moved/SKILL.md"; touch "$TMP/moved/bin/filo"
rm "$HOME/.local/bin/filo"; ln -s "$TMP/moved/bin/filo" "$HOME/.local/bin/filo"          # another checkout
"$INSTALL" >/dev/null 2>"$TMP/err"
ours "$HOME/.claude/skills/filo" "$REPO"; ours "$HOME/.local/bin/filo" "$REPO/bin/filo"
has "$(cat "$TMP/err")" "replaced: $HOME/.claude/skills/filo"

# a harness whose skills dir can't be made (a dangling link) is skipped, not fatal
mkdir -p "$HOME/.agents"; ln -s "$TMP/gone" "$HOME/.agents/skills"
out="$("$INSTALL" 2>"$TMP/err")"
assert "$out" "DONE skills=2 cli=$HOME/.local/bin/filo skipped=1"
has "$(cat "$TMP/err")" "SKIP (cannot create): $HOME/.agents/skills"
rm "$HOME/.agents/skills"; rmdir "$HOME/.agents"

# a filo link to something that isn't a filo checkout is someone else's: kept by
# install and by uninstall
mkdir -p "$TMP/theirs"; rm "$HOME/.claude/skills/filo"; ln -s "$TMP/theirs" "$HOME/.claude/skills/filo"
assert "$("$INSTALL" 2>/dev/null)" "DONE skills=1 cli=$HOME/.local/bin/filo skipped=1"
assert "$("$INSTALL" --uninstall 2>/dev/null)" "DONE removed=2 skipped=1"
assert "$(readlink "$HOME/.claude/skills/filo")" "$TMP/theirs"
rm "$HOME/.claude/skills/filo"; "$INSTALL" >/dev/null 2>&1

# anything else named filo is left alone and reported
rm "$HOME/.codex/skills/filo"; mkdir "$HOME/.codex/skills/filo"                          # someone's own skill
rm "$HOME/.local/bin/filo"; printf '#!/bin/sh\n' > "$HOME/.local/bin/filo"               # another program
out="$("$INSTALL" 2>"$TMP/err")"
assert "$out" "DONE skills=1 cli=skipped skipped=2"
has "$(cat "$TMP/err")" "SKIP (exists, not ours): $HOME/.codex/skills/filo"
[ -d "$HOME/.codex/skills/filo" ] && [ ! -L "$HOME/.local/bin/filo" ] || { echo "  a foreign filo was touched"; exit 1; }
rmdir "$HOME/.codex/skills/filo"; rm "$HOME/.local/bin/filo"

# a dir it can't write to is skipped, not fatal (FILO_BIN_DIR=/usr/local/bin without sudo)
mkdir -p "$TMP/ro"; chmod 555 "$TMP/ro"
out="$(FILO_BIN_DIR="$TMP/ro" "$INSTALL" 2>"$TMP/err")"
assert "$out" "DONE skills=2 cli=skipped skipped=1"
has "$(cat "$TMP/err")" "SKIP (cannot link): $TMP/ro/filo"
case "$(cat "$TMP/err")" in *"not on your PATH"*) echo "  PATH hint for a dir with no filo"; exit 1 ;; esac
chmod 755 "$TMP/ro"

# FILO_BIN_DIR picks the command's dir
out="$(FILO_BIN_DIR="$TMP/mybin" "$INSTALL" 2>/dev/null)"
has "$out" "cli=$TMP/mybin/filo"; ours "$TMP/mybin/filo" "$REPO/bin/filo"

# uninstall removes only ours: the skill links and both command links it made
"$INSTALL" >/dev/null 2>&1
assert "$("$INSTALL" --uninstall 2>/dev/null)" "DONE removed=3 skipped=0"
assert "$(FILO_BIN_DIR="$TMP/mybin" "$INSTALL" --uninstall 2>/dev/null)" "DONE removed=1 skipped=0"
[ ! -e "$HOME/.claude/skills/filo" ] && [ ! -e "$HOME/.local/bin/filo" ] && [ ! -e "$TMP/mybin/filo" ] \
  || { echo "  uninstall left links"; exit 1; }

# FILO_SKILL_DIRS replaces the harness list; a dir whose parent is missing is skipped
mkdir -p "$TMP/h1"
out="$(FILO_SKILL_DIRS="$TMP/h1/skills:$TMP/absent/skills" FILO_BIN_DIR="$TMP/bin2" "$INSTALL" 2>/dev/null)"
assert "$out" "DONE skills=1 cli=$TMP/bin2/filo skipped=0"
ours "$TMP/h1/skills/filo" "$REPO"; [ ! -e "$TMP/absent" ] || { echo "  absent dir created"; exit 1; }

echo "  install ok"
