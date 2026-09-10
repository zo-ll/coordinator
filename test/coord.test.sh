#!/usr/bin/env bash
# coord.sh: records the session id and starts/kills the relay.
set -euo pipefail
unset TMUX   # force the detached relay path

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COORD="$HERE/../scripts/coord.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; [ -n "${relay_pid:-}" ] && kill "$relay_pid" 2>/dev/null || true' EXIT

export COORD_HOME="$TMP/coord"
export COORD_ENV_CONF="$TMP/coord/env.conf"
export COORD_ROOT="$TMP/coord"
export COORD_REPO="$TMP/repo"
mkdir -p "$COORD_HOME" "$COORD_REPO"
printf 'current=codex\nharness.codex.resume=codex|exec|resume|__SESSION__|__BATCH__\n' > "$COORD_ENV_CONF"

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }

out="$("$COORD" --session test-sess --no-relay)"
assert "$out" "SESSION test-sess harness=codex repo=$COORD_REPO"
assert "$(cat "$COORD_REPO/.coordinator/session")" "test-sess"

# starts a detached relay
out="$("$COORD" --session s2)"
case "$out" in *RELAY\ pid=*) ;; *) echo "  relay not started: $out"; exit 1 ;; esac
relay_pid="$(cat "$COORD_ROOT/relay.pid")"
kill -0 "$relay_pid" 2>/dev/null || { echo "  relay pid not alive"; exit 1; }
kill "$relay_pid" 2>/dev/null || true
relay_pid=""

echo "  coord ok"
