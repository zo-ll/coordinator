#!/usr/bin/env bash
# status.sh: composes ledger + queue depth + live pids + role log tails.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS="$HERE/../scripts/status.sh"
STATE="$HERE/../scripts/state.sh"
QUEUE="$HERE/../scripts/queue.sh"
TMP="$(mktemp -d)"

export COORD_ROOT="$TMP/coord"
export COORD_EVENTS="$TMP/repo/.coordinator/events.jsonl"
export COORD_DASHBOARD="$TMP/repo/COORDINATION.md"

# a live process to stand in for a dispatched worker
sleep 30 &
worker_pid=$!
trap 'kill "$worker_pid" 2>/dev/null || true; rm -rf "$TMP"' EXIT

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }

"$STATE" add s1 "first slice" >/dev/null
"$STATE" ready >/dev/null
"$STATE" dispatch s1 "$worker_pid" /wt/1 coord/1-s1 1 >/dev/null
"$STATE" add s2 "second slice" >/dev/null

"$QUEUE" enqueue e1 'DONE s1: done' >/dev/null
mkdir -p "$COORD_ROOT/log"
printf 'starting\nworking on it\n' > "$COORD_ROOT/log/worker.s1.log"
printf '%s\n' "$worker_pid" > "$COORD_ROOT/relay.pid"

out="$("$STATUS")"

assert "$(printf '%s\n' "$out" | sed -n 1p)" "STATUS relay=$worker_pid alive=1"
assert "$(printf '%s\n' "$out" | sed -n 2p)" "QUEUE pending=1 inflight=0 done=0"
assert "$(printf '%s\n' "$out" | grep '^SLICE s1 ')" \
  "SLICE s1 dispatched pid=$worker_pid alive=1 verdict=- goal=first slice"
assert "$(printf '%s\n' "$out" | grep '^SLICE s2 ')" \
  "SLICE s2 todo pid=- alive=0 verdict=- goal=second slice"
assert "$(printf '%s\n' "$out" | grep '^LOG s1 worker ')" "LOG s1 worker working on it"

# no live process: dead worker, no log tail
kill "$worker_pid"; wait "$worker_pid" 2>/dev/null || true
printf '999999\n' > "$COORD_ROOT/relay.pid"
out="$("$STATUS")"
assert "$(printf '%s\n' "$out" | sed -n 1p)" "STATUS relay=999999 alive=0"
assert "$(printf '%s\n' "$out" | grep '^SLICE s1 ')" \
  "SLICE s1 dispatched pid=$worker_pid alive=0 verdict=- goal=first slice"
if printf '%s\n' "$out" | grep -q '^LOG s1 '; then echo "  logged a dead role"; exit 1; fi

echo "  status ok"
