#!/usr/bin/env bash
# install.sh: symlink the skill into harness dirs, idempotent, and uninstall.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL="$HERE/../bin/install.sh"
REPO="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/h1" "$TMP/h2"
export FILO_SKILL_DIRS="$TMP/h1:$TMP/h2:$TMP/absent"

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }

out="$("$INSTALL")"
assert "$out" "DONE linked=2 skipped=0"
[ -L "$TMP/h1/filo" ] || { echo "  h1 not linked"; exit 1; }
[ -L "$TMP/h2/filo" ] || { echo "  h2 not linked"; exit 1; }
assert "$(readlink -f "$TMP/h1/filo")" "$REPO"
[ -e "$TMP/absent" ] && { echo "  absent dir should not be created"; exit 1; }

# idempotent
assert "$("$INSTALL")" "DONE linked=0 skipped=2"

# does not clobber a foreign entry
mkdir -p "$TMP/h3"
ln -s /tmp "$TMP/h3/filo"
FILO_SKILL_DIRS="$TMP/h3" "$INSTALL" >/dev/null 2>&1 || true
assert "$(readlink "$TMP/h3/filo")" "/tmp"

# uninstall removes only ours
assert "$("$INSTALL" --uninstall)" "DONE removed=2 skipped=0"
[ -L "$TMP/h1/filo" ] && { echo "  h1 not removed"; exit 1; }
[ -L "$TMP/h2/filo" ] && { echo "  h2 not removed"; exit 1; }

echo "  install ok"
