#!/usr/bin/env bash
# cfg.sh: literal values, overwrite, empty value, prefix keys, unset.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/../scripts/cfg.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
F="$TMP/c.conf"

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }

"$CFG" set "$F" a.b 1
assert "$("$CFG" get "$F" a.b)" "1"

# values with spaces and '=' are literal
"$CFG" set "$F" c "hello = world"
assert "$("$CFG" get "$F" c)" "hello = world"

# overwrite in place, no duplicate lines
"$CFG" set "$F" a.b 2
assert "$("$CFG" get "$F" a.b)" "2"
assert "$(grep -c '^a\.b=' "$F")" "1"

# empty value is legal
"$CFG" set "$F" e ""
assert "$("$CFG" get "$F" e)" ""

# keys and prefix
assert "$("$CFG" keys "$F" | sort | tr '\n' ',')" "a.b,c,e,"
assert "$("$CFG" keys "$F" a.)" "a.b"

# absent key exits 1
if "$CFG" get "$F" missing >/dev/null 2>&1; then echo "  expected absent key to fail"; exit 1; fi

# unset
"$CFG" unset "$F" a.b
if "$CFG" get "$F" a.b >/dev/null 2>&1; then echo "  unset failed"; exit 1; fi

echo "  cfg ok"
