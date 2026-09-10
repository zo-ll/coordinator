#!/usr/bin/env bash
# detect.sh: current-harness sentinel, PATH scan, spawnable filtering.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="$HERE/../scripts/detect.sh"
CFG="$HERE/../scripts/cfg.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export COORD_HOME="$TMP/coord"
export COORD_ENV_CONF="$TMP/coord/env.conf"
export OPENCODE=1
export COORD_KNOWN="codex"
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/codex"
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH"

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }

out="$("$DETECT")"
case "$out" in DETECT\ *) ;; *) echo "  unexpected output: $out"; exit 1 ;; esac

assert "$("$CFG" get "$COORD_ENV_CONF" current)" "opencode"
assert "$("$CFG" get "$COORD_ENV_CONF" current_source)" "env"
assert "$("$CFG" get "$COORD_ENV_CONF" installed)" "codex"
assert "$("$CFG" get "$COORD_ENV_CONF" spawnable)" "codex"
assert "$("$CFG" get "$COORD_ENV_CONF" harness.codex.bin)" "$TMP/bin/codex"
[ -n "$("$CFG" get "$COORD_ENV_CONF" harness.codex.resume)" ] || { echo "  missing resume recipe"; exit 1; }

echo "  detect ok"
