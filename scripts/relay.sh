#!/usr/bin/env bash
# Serial queue consumer: the only thing that turns workers' pings into a
# coordinator turn. No daemon framework, no tmux, no polling of a live session.
#
#   relay.sh [--once] [--interval N]
#
# Loop: wait for the queue to be non-empty; claim every pending event, in order,
# into one batch file; resume the coordinator with a one-line pointer to it; wait
# for the turn to exit; ack the batch. One turn at a time.
#
# The resume command is config data (never eval'd):
#   $COORD_CONFIG (default <cwd>/.coordinator/config.conf) keys:
#     relay.resume   '|'-separated argv template with __SESSION__ and __BATCH__
#     relay.session  session id/name to resume
# Overrides: COORD_RESUME, COORD_SESSION.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COORD_ROOT="${COORD_ROOT:-/tmp/coordinator}"
QUEUE="$HERE/queue.sh"

once=0
interval="${RELAY_INTERVAL:-1}"
while [ $# -gt 0 ]; do
  case "$1" in
    --once)     once=1; shift ;;
    --interval) interval="$2"; shift 2 ;;
    *) echo "relay.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

cfg_get() { "$HERE/cfg.sh" get "$1" "$2" 2>/dev/null || true; }

resume_recipe() {
  [ -n "${COORD_RESUME:-}" ] && { printf '%s' "$COORD_RESUME"; return 0; }
  local file="${COORD_CONFIG:-$PWD/.coordinator/config.conf}"
  local v; v="$(cfg_get "$file" relay.resume)"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  local envconf="${COORD_ENV_CONF:-${COORD_HOME:-$HOME/.coordinator}/env.conf}"
  local cur; cur="$(cfg_get "$envconf" current)"
  [ -n "$cur" ] && cfg_get "$envconf" "harness.$cur.resume"
}

session_id() {
  [ -n "${COORD_SESSION:-}" ] && { printf '%s' "$COORD_SESSION"; return 0; }
  local file="${COORD_CONFIG:-$PWD/.coordinator/config.conf}"
  local v; v="$(cfg_get "$file" relay.session)"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  local dir; dir="$(dirname "$file")"
  [ -f "$dir/session" ] && { cat "$dir/session"; return 0; }
  [ -f "$PWD/.coordinator/session" ] && cat "$PWD/.coordinator/session"
}

resume() { # pointer
  local pointer="$1" recipe session i argv
  recipe="$(resume_recipe)"
  [ -n "$recipe" ] || {
    echo "relay: no relay.resume recipe (set COORD_RESUME, config, or env.conf)" >&2
    return 1
  }
  session="$(session_id)"
  IFS='|' read -r -a argv <<< "$recipe"
  for i in "${!argv[@]}"; do
    argv[$i]="${argv[$i]//__BATCH__/$pointer}"
    argv[$i]="${argv[$i]//__SESSION__/$session}"
  done
  "${argv[@]}"
}

batchdir="$COORD_ROOT/batch"
mkdir -p "$batchdir"

while :; do
  if "$QUEUE" pending; then
    batch="$batchdir/$(date +%s%N).$$.txt"
    if "$QUEUE" pop-batch "$batch" >/dev/null; then
      if resume "WAKE batch=$batch"; then
        "$QUEUE" ack
      else
        echo "relay: resume failed, returning batch to queue" >&2
        "$QUEUE" nack
      fi
      if [ "$once" = 1 ]; then exit 0; fi
    fi
  else
    sleep "$interval"
  fi
done
