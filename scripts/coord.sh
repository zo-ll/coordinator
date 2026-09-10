#!/usr/bin/env bash
# Start a coordinated run: pin the session id, record it, and start the relay.
#
#   coord.sh [--harness H] [--session ID] [--no-relay]
#     -> SESSION <id> harness=<h> repo=<repo>   [+ RELAY pid=<pid>]
#
# The coordinator identity is the current harness; the launcher only records the
# session id the relay will resume and starts the relay detached.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/cfg.sh"
COORD_HOME="${COORD_HOME:-$HOME/.coordinator}"
ENV_CONF="${COORD_ENV_CONF:-$COORD_HOME/env.conf}"
COORD_ROOT="${COORD_ROOT:-/tmp/coordinator}"
repo="${COORD_REPO:-$PWD}"

harness=""
session=""
start_relay=1
while [ $# -gt 0 ]; do
  case "$1" in
    --harness)  harness="$2"; shift 2 ;;
    --session)  session="$2"; shift 2 ;;
    --no-relay) start_relay=0; shift ;;
    *) echo "coord.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$harness" ] || harness="$("$CFG" get "$ENV_CONF" current 2>/dev/null || true)"
[ -n "$harness" ] || { echo "coord: no current harness (run detect.sh first)" >&2; exit 1; }

if [ -z "$session" ]; then
  if [ -r /proc/sys/kernel/random/uuid ]; then
    session="$(cat /proc/sys/kernel/random/uuid)"
  else
    session="coord-$(date +%s)-$$"
  fi
fi

mkdir -p "$repo/.coordinator"
printf '%s\n' "$session" > "$repo/.coordinator/session"

printf 'SESSION %s harness=%s repo=%s\n' "$session" "$harness" "$repo"

if [ "$start_relay" = 1 ]; then
  mkdir -p "$COORD_ROOT"
  if [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
    # Run the relay in a visible window so the coordinator's resumed turns show.
    rcmd="COORD_SESSION=$(printf '%q' "$session") $(printf '%q' "$HERE/relay.sh")"
    if tmux new-window -d -n coord-relay -c "$repo" "$rcmd" 2>/dev/null; then
      printf 'RELAY window=coord-relay session=%s\n' "$session"
    else
      COORD_SESSION="$session" setsid "$HERE/relay.sh" >>"$COORD_ROOT/relay.log" 2>&1 &
      pid="$!"
      printf '%s\n' "$pid" > "$COORD_ROOT/relay.pid"
      printf 'RELAY pid=%s\n' "$pid"
    fi
  else
    COORD_SESSION="$session" setsid "$HERE/relay.sh" >>"$COORD_ROOT/relay.log" 2>&1 &
    pid="$!"
    printf '%s\n' "$pid" > "$COORD_ROOT/relay.pid"
    printf 'RELAY pid=%s\n' "$pid"
  fi
fi
