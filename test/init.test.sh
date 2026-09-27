#!/usr/bin/env bash
# coord init: detect + plan + apply + start in one verb; stops at ASK for an
# unconfigured repo, never re-plans a configured one.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

export COORD_HOME="$TMP/coord" COORD_ENV_CONF="$TMP/coord/env.conf" COORD_KNOWN=codex
unset COORD_EVENTS COORD_CONFIG PI_SESSION_ID COORD_SESSION
mkdir -p "$TMP/bin" "$TMP/repo"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/codex"; chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
cd "$TMP/repo"

# unconfigured: the proposal and the question, nothing started
out="$("$COORD" init)"
has "$out" "DETECT "
has "$out" $'\nASK\n'
has "$out" "NEXT: ASK THE USER to accept or change these"
[ ! -f .coordinator/config.conf ] || { echo "  config written without an answer"; exit 1; }
[ ! -f .coordinator/session ] || { echo "  started without an answer"; exit 1; }

# answered: config written, run started
out="$("$COORD" init --answers "autonomy=auto-merge" --session s1 --harness codex)"
has "$out" "OK config="
has "$out" "SESSION s1 source=user harness=codex"
has "$out" "RELAY pid="
assert "$("$COORD" cfg get .coordinator/config.conf autonomy)" "auto-merge"
kill "${out##*RELAY pid=}" 2>/dev/null || true

# configured: no question, the existing config is kept
out="$("$COORD" init --session s2 --harness codex)"
hasnt "$out" "ASK"
has "$out" "SESSION s2"
assert "$("$COORD" cfg get .coordinator/config.conf autonomy)" "auto-merge"
kill "${out##*RELAY pid=}" 2>/dev/null || true

echo "  init ok"
