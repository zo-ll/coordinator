#!/usr/bin/env bash
# coord detect: current-harness sentinel, PATH scan, spawnable filtering.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
coord_detect() { "$COORD" detect "$@"; }
coord_cfg() { "$COORD" cfg "$@"; }


export COORD_HOME="$TMP/coord"
export COORD_ENV_CONF="$TMP/coord/env.conf"
export OPENCODE=1
export COORD_KNOWN="codex"
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/codex"
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH"


out="$(coord_detect)"
case "$out" in DETECT\ *) ;; *) echo "  unexpected output: $out"; exit 1 ;; esac

assert "$(coord_cfg get "$COORD_ENV_CONF" current)" "opencode"
assert "$(coord_cfg get "$COORD_ENV_CONF" current_source)" "env"
assert "$(coord_cfg get "$COORD_ENV_CONF" installed)" "codex"
assert "$(coord_cfg get "$COORD_ENV_CONF" spawnable)" "codex"
assert "$(coord_cfg get "$COORD_ENV_CONF" harness.codex.bin)" "$TMP/bin/codex"
[ -n "$(coord_cfg get "$COORD_ENV_CONF" harness.codex.resume)" ] || { echo "  missing resume recipe"; exit 1; }
has "$(coord_cfg get "$COORD_ENV_CONF" harness.codex.exec)" "|-m|__MODEL__|"

# nested harnesses: the nearest ancestor wins over leaked env sentinels
mkdir -p "$TMP/nest"; ln -sf "$(command -v bash)" "$TMP/nest/codex"
out="$(CLAUDECODE=1 "$TMP/nest/codex" -c '"$COORD" detect; true')"
has "$out" "DETECT current=codex"
assert "$(coord_cfg get "$COORD_ENV_CONF" current_source)" "ancestor"

echo "  detect ok"
