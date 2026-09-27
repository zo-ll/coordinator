#!/usr/bin/env bash
# coord cfg: literal values, overwrite, empty value, prefix keys, unset.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
coord_cfg() { "$COORD" cfg "$@"; }

F="$TMP/c.conf"


coord_cfg set "$F" a.b 1
assert "$(coord_cfg get "$F" a.b)" "1"

# values with spaces and '=' are literal
coord_cfg set "$F" c "hello = world"
assert "$(coord_cfg get "$F" c)" "hello = world"

# overwrite in place, no duplicate lines
coord_cfg set "$F" a.b 2
assert "$(coord_cfg get "$F" a.b)" "2"
assert "$(grep -c '^a\.b=' "$F")" "1"

# empty value is legal
coord_cfg set "$F" e ""
assert "$(coord_cfg get "$F" e)" ""

# keys and prefix
assert "$(coord_cfg keys "$F" | sort | tr '\n' ',')" "a.b,c,e,"
assert "$(coord_cfg keys "$F" a.)" "a.b"

# absent key exits 1
if coord_cfg get "$F" missing >/dev/null 2>&1; then echo "  expected absent key to fail"; exit 1; fi

# unset
coord_cfg unset "$F" a.b
if coord_cfg get "$F" a.b >/dev/null 2>&1; then echo "  unset failed"; exit 1; fi

echo "  cfg ok"
