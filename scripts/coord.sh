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

# repo hygiene: workers use `git add -A`, so keep finish markers out of the
# index from the start. Ensure .gitignore ignores .scratch/ and commit it on
# main (worktrees inherit it) with the user's identity — the first commit the
# coordinator authors in the run.
gi="$repo/.gitignore"
if ! grep -qx '.scratch/' "$gi" 2>/dev/null; then
  printf '.scratch/\n' >> "$gi"
  if git -C "$repo" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    uemail="$(git -C "$repo" config user.email || echo coord@local)"
    uname="$(git -C "$repo" config user.name || echo coordinator)"
    git -C "$repo" add .gitignore
    git -C "$repo" -c user.email="$uemail" -c user.name="$uname" commit -q -m "[coord] ignore .scratch markers"
  fi
fi

if [ "$start_relay" = 1 ]; then
  mkdir -p "$COORD_ROOT"
  COORD_SESSION="$session" setsid "$HERE/relay.sh" >>"$COORD_ROOT/relay.log" 2>&1 &
  pid="$!"
  printf '%s\n' "$pid" > "$COORD_ROOT/relay.pid"
  printf 'RELAY pid=%s\n' "$pid"
fi
