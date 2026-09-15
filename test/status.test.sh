#!/usr/bin/env bash
# status.sh: composes ledger + queue depth + live pids + role log tails, plus
# the wake-liveness staleness signal (STALE batch=…, SLICE-STALE …).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS="$HERE/../scripts/status.sh"
STATE="$HERE/../scripts/state.sh"
QUEUE="$HERE/../scripts/queue.sh"
TMP="$(mktemp -d)"

worker_pid=""
trap 'kill "$worker_pid" 2>/dev/null || true; rm -rf "$TMP"' EXIT

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }

# Run status without tripping set -e on its intentional nonzero exit.
capture() {
  set +e
  OUT="$("$STATUS" 2>&1)"
  RC=$?
  set -e
}
line() { printf '%s\n' "$OUT" | sed -n "$1p"; }

# --- happy path: ledger + queue + live pid + log tail, nothing stale --------
export COORD_ROOT="$TMP/coord-a"
export COORD_LEDGER="$TMP/repo-a/.coordinator/ledger.tsv"
export COORD_DASHBOARD="$TMP/repo-a/COORDINATION.md"

sleep 30 &
worker_pid=$!

"$STATE" add s1 "first slice" >/dev/null
"$STATE" ready >/dev/null
"$STATE" dispatch s1 "$worker_pid" /wt/1 coord/1-s1 1 >/dev/null
"$STATE" add s2 "second slice" >/dev/null

"$QUEUE" enqueue e1 'DONE s1: done' >/dev/null
mkdir -p "$COORD_ROOT/log"
printf 'starting\nworking on it\n' > "$COORD_ROOT/log/worker.s1.log"
printf '%s\n' "$worker_pid" > "$COORD_ROOT/relay.pid"

capture
assert "$(line 1)" "STATUS relay=$worker_pid alive=1"
assert "$(line 2)" "QUEUE pending=1 inflight=0 done=0"
assert "$(printf '%s\n' "$OUT" | grep '^STALE ')" "STALE none"
assert "$(printf '%s\n' "$OUT" | grep '^SLICE s1 ')" \
  "SLICE s1 dispatched pid=$worker_pid alive=1 verdict=- goal=first slice"
assert "$(printf '%s\n' "$OUT" | grep '^SLICE s2 ')" \
  "SLICE s2 todo pid=- alive=0 verdict=- goal=second slice"
assert "$(printf '%s\n' "$OUT" | grep '^LOG s1 worker ')" "LOG s1 worker working on it"
assert "$RC" "0"

# --- dead worker pid: preserve the last log for diagnosis, nonzero ----------
kill "$worker_pid"; wait "$worker_pid" 2>/dev/null || true
printf '999999\n' > "$COORD_ROOT/relay.pid"
capture
assert "$(line 1)" "STATUS relay=999999 alive=0"
assert "$(printf '%s\n' "$OUT" | grep '^SLICE s1 ')" \
  "SLICE s1 dispatched pid=$worker_pid alive=0 verdict=- goal=first slice"
printf '%s\n' "$OUT" | grep -q '^LOG s1 worker working on it' || { echo '  missing dead role log'; exit 1; }
assert "$(printf '%s\n' "$OUT" | grep '^STALE ')" "STALE none"
assert "$(printf '%s\n' "$OUT" | grep '^SLICE-STALE s1 age=')" "SLICE-STALE s1 age=0"
[ "$RC" -ne 0 ] || { echo "  dead slice should exit nonzero"; exit 1; }

# --- pending ping older than COORD_STALE_MIN: STALE batch, nonzero ----------
export COORD_ROOT="$TMP/coord-b"
export COORD_LEDGER="$TMP/repo-b/.coordinator/ledger.tsv"
export COORD_DASHBOARD="$TMP/repo-b/COORDINATION.md"
enq="$("$QUEUE" enqueue old 'DONE old: done')"
old="$COORD_ROOT/queue/${enq##* }"
touch -d '-1 hour' "$old"
capture
assert "$(printf '%s\n' "$OUT" | grep -c '^STALE batch=')" "1"
stale_line="$(printf '%s\n' "$OUT" | grep '^STALE batch=')"
case "$stale_line" in
  "STALE batch=$old age="*) ;;
  *) echo "  bad stale line: '$stale_line'"; exit 1 ;;
esac
age="${stale_line##*age=}"
[ "$age" -ge 60 ] || { echo "  stale age too small: $age"; exit 1; }
[ "$RC" -ne 0 ] || { echo "  stale pending should exit nonzero"; exit 1; }

# --- crash-stranded .inflight ping is stale too -----------------------------
newq="$("$QUEUE" enqueue stranded 'DONE stranded: done')"
sf="$COORD_ROOT/queue/${newq##* }"
mv "$sf" "$COORD_ROOT/queue/.inflight/"
touch -d '-1 hour' "$COORD_ROOT/queue/.inflight/$(basename "$sf")"
capture
printf '%s\n' "$OUT" | grep -q "^STALE batch=$COORD_ROOT/queue/.inflight/" || {
  echo "  inflight ping not reported stale"; exit 1; }
[ "$RC" -ne 0 ] || { echo "  stale inflight should exit nonzero"; exit 1; }

# --- fresh pending ping: immediately report the missing relay ---------------
export COORD_ROOT="$TMP/coord-c"
export COORD_LEDGER="$TMP/repo-c/.coordinator/ledger.tsv"
export COORD_DASHBOARD="$TMP/repo-c/COORDINATION.md"
"$QUEUE" enqueue fresh 'DONE fresh: done' >/dev/null
capture
assert "$(printf '%s\n' "$OUT" | grep '^STALE ')" "STALE none"
assert "$RC" "1"
printf '%s\n' "$OUT" | grep -q '^!!! FAIL relay:'

# --- dead relay + fresh pending: fail without waiting for the stale timeout -
printf '999999\n' > "$COORD_ROOT/relay.pid"
capture
assert "$(line 1)" "STATUS relay=999999 alive=0"
assert "$(printf '%s\n' "$OUT" | grep '^STALE ')" "STALE none"
assert "$RC" "1"

# --- live pid but stale worktree marker: SLICE-STALE, nonzero ---------------
export COORD_ROOT="$TMP/coord-d"
export COORD_LEDGER="$TMP/repo-d/.coordinator/ledger.tsv"
export COORD_DASHBOARD="$TMP/repo-d/COORDINATION.md"
wt="$TMP/wt-d"
mkdir -p "$wt/.scratch/status"
printf 'done\n' > "$wt/.scratch/status/s1.done"
touch -d '-1 hour' "$wt/.scratch/status/s1.done"
sleep 30 &
worker_pid=$!
"$STATE" add s1 "slow slice" >/dev/null
"$STATE" ready >/dev/null
"$STATE" dispatch s1 "$worker_pid" "$wt" coord/1-s1 1 >/dev/null
capture
assert "$(printf '%s\n' "$OUT" | grep '^SLICE s1 ')" \
  "SLICE s1 dispatched pid=$worker_pid alive=1 verdict=- goal=slow slice"
assert "$(printf '%s\n' "$OUT" | grep '^STALE ')" "STALE none"
stale_line="$(printf '%s\n' "$OUT" | grep '^SLICE-STALE s1 ')"
case "$stale_line" in
  "SLICE-STALE s1 age="*) ;;
  *) echo "  bad slice stale line: '$stale_line'"; exit 1 ;;
esac
sage="${stale_line##*age=}"
[ "$sage" -ge 60 ] || { echo "  slice stale age too small: $sage"; exit 1; }
[ "$RC" -ne 0 ] || { echo "  stale slice should exit nonzero"; exit 1; }
kill "$worker_pid" 2>/dev/null || true; wait "$worker_pid" 2>/dev/null || true

# A real supervised worker can finish before the next coordinator turn.
# That is WAIT, not a dead-process alarm. A nonzero exit is still a FAIL.
export COORD_ROOT="$TMP/coord-e"
export COORD_LEDGER="$TMP/repo-e/.coordinator/ledger.tsv"
export COORD_DASHBOARD="$TMP/repo-e/COORDINATION.md"
export COORD_MARKERS="$TMP/wt-e/.scratch/status"
mkdir -p "$COORD_ROOT" "$COORD_MARKERS"
printf '%s\n' "$$" > "$COORD_ROOT/relay.pid"
: > "$COORD_MARKERS/s1.done"
bash "$HERE/../scripts/run-role.sh" worker s1 s1 true >"$TMP/role" 2>&1 &
worker_pid=$!
"$STATE" add s1 'finished process' >/dev/null
"$STATE" dispatch s1 "$worker_pid" "$TMP/wt-e" coord/s1 s1 >/dev/null
wait "$worker_pid"
capture
assert "$RC" 0
printf '%s\n' "$OUT" | grep -q '^WAIT slice=s1 process completed;'

bash "$HERE/../scripts/run-role.sh" worker s1 s1 false >"$TMP/role" 2>&1 &
worker_pid=$!
"$STATE" dispatch s1 "$worker_pid" "$TMP/wt-e" coord/s1 s1 >/dev/null
wait "$worker_pid" && exit 1
capture
assert "$RC" 1
printf '%s\n' "$OUT" | grep -q '^!!! FAIL slice=s1 supervised process failed;'
worker_pid=""

echo "  status ok"
