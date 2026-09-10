#!/usr/bin/env bash
# invoke.sh: recipe -> argv, __CWD__/__PROMPT__/__MODEL__ expansion.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INVOKE="$HERE/../scripts/invoke.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export COORD_HOME="$TMP/coord"
export COORD_ENV_CONF="$TMP/coord/env.conf"
export COORD_AGENTS="$TMP/no-agents"
mkdir -p "$COORD_HOME"
printf 'harness.h1.exec=h1|-C|__CWD__|-m|__MODEL__|__PROMPT__\n' > "$COORD_ENV_CONF"
printf 'hello world\n' > "$TMP/brief"

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }

# model empty -> the flag (-m) and its value are both dropped
mapfile -d '' -t a < <("$INVOKE" h1 worker "$TMP/brief" /cwd "")
assert "${#a[@]}" "4"
assert "${a[0]}" "h1"
assert "${a[1]}" "-C"
assert "${a[2]}" "/cwd"
assert "${a[3]}" "hello world"

# model set -> flag + value present
mapfile -d '' -t b < <("$INVOKE" h1 worker "$TMP/brief" /cwd big)
assert "${#b[@]}" "6"
assert "${b[3]}" "-m"
assert "${b[4]}" "big"
assert "${b[5]}" "hello world"

echo "  invoke ok"
