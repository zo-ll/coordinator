#!/usr/bin/env bash
# watch.sh <root> [<root> ...]  [--interval N]
# Live plain-terminal dashboard: one compact block per harness root.
#
# Per root (newline-squashed so it reads at a glance):
#   --- <root> ---
#   STATUS relay=<pid> alive=<0|1>   QUEUE pending=.. inflight=.. done=..
#   STALE <alarm-or-none>            HEALTH <ok-or-alarm>
#   slice:state slice:state ...      (ledger, inline)
#   <last progress line>
#
# Ctrl-C stops watching; workers keep running. `scripts/status.sh --watch`
# is the verbose snapshot variant; this is the glanceable one.
set -uo pipefail
# No set -e: a dashboard loop must survive transient glitches (empty logs,
# SIGPIPE from early-close heads). Fragile pipelines are guarded individually.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
interval=3
roots=()
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) interval="$2"; shift 2 ;;
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
  printf '%s — coordinator status (Ctrl-C stops watching; workers keep running)\n' "$(date '+%H:%M:%S')"
  for root in "${roots[@]}"; do
    [ -d "$root" ] || { echo "--- $root (missing)"; continue; }
    echo "--- $root ---"
    env COORD_ROOT="$root" "$HERE/status.sh" 2>/dev/null \
      | grep -E 'STATUS|QUEUE|STALE|HEALTH' | head -4 || true
    ledger="$(dirname "$root")/tinyproj/.coordinator/ledger.tsv"
    [ -f "$ledger" ] || ledger="$(dirname "$root")/ledger.tsv"        # internal-root layout (opencode)
    [ -f "$ledger" ] || ledger="$(dirname "$(dirname "$root")")/tinyproj/.coordinator/ledger.tsv"
    if [ -f "$ledger" ]; then
      awk -F'\t' '{printf "  %s:%s ", $1, $2}' "$ledger" 2>/dev/null || true
      echo
    fi
    tail -1 "$root/progress.log" 2>/dev/null | tr -d '\0' | cut -c1-110 || true
  done
  sleep "$interval"
done