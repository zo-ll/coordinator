#!/usr/bin/env bash
# watch.sh <root> [<root> ...]  [--interval N]
# Live plain-terminal dashboard for detached coordinator runs.
#
# This is the answer to "what is happening?" on ANY harness — especially the
# headless-turn ones (claude, opencode) whose coordinator reacts invisibly in
# a resumed session. For each COORD_ROOT it shows, live:
#   - the status snapshot (relay liveness, queue depth, STALE, slices)
#   - the coordinator's captured turn log (relay.sh writes headless turns to
#     $COORD_ROOT/turn.log; older relays fall back to relay.log)
#   - the newest worker/critic role log tail
#
# Ctrl-C stops watching; processes keep running. `scripts/status.sh --watch`
# is the summary-only variant.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
interval=3
tail_n=6
roots=()
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) interval="$2"; shift 2 ;;
    --tail)     tail_n="$2";  shift 2 ;;
    -*) echo "watch.sh: unknown arg: $1" >&2; exit 2 ;;
    *) roots+=("$1"); shift ;;
  esac
done
[ "${#roots[@]}" -gt 0 ] || {
  echo "watch.sh: give one or more COORD_ROOT dirs, e.g." >&2
  echo "  watch.sh /tmp/sandbox/codex/root /tmp/sandbox/opencode/tinyproj/.coordinator/root" >&2
  exit 2
}

while :; do
  clear
  printf '%s — coordinator dashboard (Ctrl-C stops watching; workers keep running)\n' "$(date '+%H:%M:%S')"
  for root in "${roots[@]}"; do
    [ -d "$root" ] || { echo "── $root ──  (missing)"; continue; }
    echo "── $root ──"
    env COORD_ROOT="$root" "$HERE/status.sh" 2>/dev/null | head -8
    turn="$root/turn.log"; [ -f "$turn" ] || turn="$root/relay.log"
    if [ -f "$turn" ]; then
      echo "  coordinator voice:"
      tail -n "$tail_n" "$turn" | grep -v '^$' | tail -n "$tail_n" | sed 's/^/    /'
    fi
    newest="$(ls -t "$root"/log/worker.*.log "$root"/log/critic.*.log 2>/dev/null | head -1)"
    if [ -n "$newest" ]; then
      echo "  $(basename "$newest"):"
      tail -n 3 "$newest" | grep -v '^\[COORD\]' | sed 's/^/    /'
    fi
  done
  sleep "$interval"
done