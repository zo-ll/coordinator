#!/usr/bin/env bash
# filo cfg: literal values, overwrite, empty value, prefix keys, unset.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
filo_cfg() { "$FILO" cfg "$@"; }

F="$TMP/c.conf"


filo_cfg set "$F" a.b 1
assert "$(filo_cfg get "$F" a.b)" "1"

# values with spaces and '=' are literal
filo_cfg set "$F" c "hello = world"
assert "$(filo_cfg get "$F" c)" "hello = world"

# overwrite in place, no duplicate lines
filo_cfg set "$F" a.b 2
assert "$(filo_cfg get "$F" a.b)" "2"
assert "$(grep -c '^a\.b=' "$F")" "1"

# empty value is legal
filo_cfg set "$F" e ""
assert "$(filo_cfg get "$F" e)" ""

# keys and prefix
assert "$(filo_cfg keys "$F" | sort | tr '\n' ',')" "a.b,c,e,"
assert "$(filo_cfg keys "$F" a.)" "a.b"

# absent key exits 1
if filo_cfg get "$F" missing >/dev/null 2>&1; then echo "  expected absent key to fail"; exit 1; fi

# unset
filo_cfg unset "$F" a.b
if filo_cfg get "$F" a.b >/dev/null 2>&1; then echo "  unset failed"; exit 1; fi

echo "  cfg ok"
