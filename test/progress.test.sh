#!/usr/bin/env bash
# Real CLI boundaries: stdout stays parseable, failures survive detached logs,
# concurrent records remain whole, and a terminal watcher survives bad health.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../scripts"
TMP="$(mktemp -d)"
watcher=""
trap 'if [ -n "$watcher" ]; then kill "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT
export COORD_ROOT="$TMP/root"
export COORD_LEDGER="$TMP/ledger.tsv"
export COORD_MARKERS="$TMP/markers"

# A validation failure is visible both on stderr and in the durable timeline.
if "$S/spawn.sh" --role worker --prompt "$TMP/missing" --worktree "$TMP" --slice s1 >"$TMP/out" 2>"$TMP/err"; then
  echo '  missing brief should fail'; exit 1
fi
[ ! -s "$TMP/out" ]
grep -q '^\[COORD\] START .*step=spawn ' "$TMP/err"
grep -q '^\[COORD\] FAIL .*step=spawn .*exit=1' "$TMP/err"
grep -q '^\[COORD\] FAIL .*step=spawn ' "$COORD_ROOT/progress.log"

# No finish marker is distinct from successful process exit.
if bash "$S/run-role.sh" worker s1 s1 true >"$TMP/out" 2>"$TMP/err"; then
  echo '  missing completion marker should fail'; exit 1
fi
grep -q 'harness exited without completion marker' "$COORD_ROOT/progress.log"
if bash "$S/run-role.sh" worker s1 s1 bash -c 'exit 7' 2>"$TMP/err"; then
  echo '  failing harness should fail'; exit 1
else
  [ "$?" -eq 7 ]
fi
grep -q 'FAIL .*step=role .*exit=7' "$COORD_ROOT/progress.log"

# Mechanical completion logs publication, preserving the original stdout.
out="$("$S/finish.sh" --event s1 --role worker --result done --head - 2>"$TMP/err")"
[ "$out" = 'FINISH s1 task=s1 round=1' ]
grep -q 'completion marker written' "$COORD_ROOT/progress.log"
grep -q 'ENQUEUED s1 .*completion published' "$COORD_ROOT/progress.log"
bash "$S/run-role.sh" worker s1 s1 true 2>"$TMP/err"
grep -q 'OK .*step=role .*completion marker verified' "$COORD_ROOT/progress.log"
"$S/finish.sh" --event s1 --role worker --result done --head - >"$TMP/out" 2>"$TMP/err"
grep -q 'WARN .*duplicate event=s1 suppressed' "$TMP/err"

# Concurrent writers publish complete records to the same log.
pids=()
for i in {1..12}; do
  "$S/finish.sh" --event "p$i" --role worker --result done --head - >"$TMP/out.$i" 2>"$TMP/err.$i" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
[ "$(grep -c 'OK .*step=finish .*ENQUEUED p' "$COORD_ROOT/progress.log")" -eq 12 ]
if grep -v '^\[COORD\] \(START\|OK\|WAIT\|WARN\|FAIL\) .* pid=[0-9]* step=' "$COORD_ROOT/progress.log"; then
  echo '  interleaved or malformed progress record'; exit 1
fi

# A detached relay error remains visible after more than 12 later messages.
COORD_SESSION=test COORD_RESUME=false "$S/relay.sh" --once --max-attempts 1 >"$TMP/relay.log" 2>&1 && exit 1
for i in {13..16}; do
  "$S/finish.sh" --event "p$i" --role worker --result done --head - >/dev/null 2>&1
done
"$S/status.sh" >"$TMP/status" && exit 1
grep -q '^LAST-FAIL .*step=relay ' "$TMP/status"
grep -q '^!!! FAIL relay:' "$TMP/status"

"$S/status.sh" --watch --interval 1 >"$TMP/watch" 2>&1 &
watcher=$!
for _ in {1..50}; do grep -q '^!!! FAIL health check:' "$TMP/watch" && break; sleep 0.1; done
grep -q '^WATCH root=' "$TMP/watch"
grep -q '^!!! FAIL health check:' "$TMP/watch"
kill -0 "$watcher"
kill "$watcher"; wait "$watcher"
watcher=""
echo '  progress ok'
