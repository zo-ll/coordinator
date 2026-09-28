#!/usr/bin/env bash
# libexec/detect.sh (filo init's first step): current-harness sentinel, PATH
# scan, spawnable filtering.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
filo_detect() { "$ROOT/libexec/detect.sh" "$@"; }
filo_cfg() { "$FILO" cfg "$@"; }


export FILO_HOME="$TMP/filo"
export FILO_ENV_CONF="$TMP/filo/env.conf"
export OPENCODE=1
export FILO_KNOWN="codex"
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/codex"
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH"


out="$(filo_detect)"
case "$out" in DETECT\ *) ;; *) echo "  unexpected output: $out"; exit 1 ;; esac

assert "$(filo_cfg get "$FILO_ENV_CONF" current)" "opencode"
has "$out" "installed=codex spawnable=codex source=env"
assert "$(filo_cfg get "$FILO_ENV_CONF" spawnable)" "codex"
assert "$(filo_cfg get "$FILO_ENV_CONF" harness.codex.bin)" "$TMP/bin/codex"
[ -n "$(filo_cfg get "$FILO_ENV_CONF" harness.codex.resume)" ] || { echo "  missing resume recipe"; exit 1; }
has "$(filo_cfg get "$FILO_ENV_CONF" harness.codex.exec)" "|-m|__MODEL__|"

# nested harnesses: the nearest ancestor wins over leaked env sentinels
mkdir -p "$TMP/nest"; ln -sf "$(command -v bash)" "$TMP/nest/codex"
out="$(CLAUDECODE=1 "$TMP/nest/codex" -c "\"$ROOT/libexec/detect.sh\"; true")"
has "$out" "DETECT current=codex"; has "$out" "source=ancestor"

echo "  detect ok"
