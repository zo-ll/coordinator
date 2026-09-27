#!/usr/bin/env bash
# relay.sh: one batch per wave, config-driven resume, ack on success.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY="$HERE/../scripts/relay.sh"
QUEUE="$HERE/../scripts/queue.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export COORD_ROOT="$TMP/coord"
export COORD_EVENTS="$TMP/events.jsonl"
export COORD_SESSION="sess-1"
export RELAY_LOG="$TMP/resume.log"
: > "$RELAY_LOG"

cat > "$TMP/fake-resume" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RELAY_LOG"
EOF
chmod +x "$TMP/fake-resume"
export COORD_RESUME="$TMP/fake-resume|__SESSION__|__BATCH__"

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }

# a wave already queued before the relay starts -> exactly one batch
for i in $(seq 1 20); do
  "$QUEUE" enqueue "t$i" "DONE t$i: done — x" >/dev/null
done

"$RELAY" --once --interval 0.2

assert "$(wc -l < "$RELAY_LOG" | tr -d ' ')" "1"
line="$(cat "$RELAY_LOG")"
case "$line" in
  *"sess-1"*) ;;
  *) echo "  session not passed: $line"; exit 1 ;;
esac
batch="${line##*WAKE batch=}"
[ -f "$batch" ] || { echo "  batch file missing: $batch"; exit 1; }
assert "$(grep -c '^EVENT ' "$batch")" "20"

# acknowledged: nothing pending, everything in done
assert "$("$QUEUE" list | wc -l)" "0"
assert "$("$QUEUE" depth)" "QUEUE pending=0 inflight=0 done=20"

# --- permanent failure: bounded retries, loud give-up, events kept in .inflight
cat > "$TMP/fail-resume" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/fail-resume"
export COORD_RESUME="$TMP/fail-resume"

"$QUEUE" enqueue f1 'DONE f1: done' >/dev/null
"$QUEUE" enqueue f2 'DONE f2: done' >/dev/null
if "$RELAY" --once --max-attempts 3 --backoff 0 >/dev/null 2>"$TMP/err"; then
  echo "  relay should have given up"; exit 1
fi
grep -q 'attempt 1/3' "$TMP/err" || { echo "  no backoff retry:"; cat "$TMP/err"; exit 1; }
grep -q 'returned the events to the queue and stopped' "$TMP/err" || { echo "  no give-up line:"; cat "$TMP/err"; exit 1; }
assert "$("$QUEUE" depth)" "QUEUE pending=2 inflight=0 done=20"
[ ! -e "$COORD_ROOT/relay.pid" ] || { echo "  pid not cleaned on exit"; exit 1; }

# --- transient failure: retried until it succeeds, then acked
: > "$RELAY_LOG"
cat > "$TMP/flaky-resume" <<EOF
#!/usr/bin/env bash
n=\$(cat "$TMP/count" 2>/dev/null || echo 0)
n=\$((n + 1)); echo \$n > "$TMP/count"
[ \$n -ge 2 ] || exit 1
printf '%s\n' "\$*" >> "$RELAY_LOG"
EOF
chmod +x "$TMP/flaky-resume"
export COORD_RESUME="$TMP/flaky-resume"
rm -f "$TMP/count"

"$QUEUE" enqueue tx1 'DONE t1: done' >/dev/null
"$QUEUE" enqueue tx2 'DONE t2: done' >/dev/null
"$RELAY" --once --max-attempts 5 --backoff 0
assert "$(wc -l < "$RELAY_LOG" | tr -d ' ')" "1"
assert "$("$QUEUE" depth)" "QUEUE pending=0 inflight=0 done=24"

# --- a second relay refuses to run while one holds the lock
"$QUEUE" enqueue u1 'DONE u1: done' >/dev/null
"$QUEUE" enqueue u2 'DONE u2: done' >/dev/null
exec 9>"$COORD_ROOT/relay.lock"
flock -n 9 || { echo "  test lock failed"; exit 1; }
if "$RELAY" --once >/dev/null 2>"$TMP/err"; then
  echo "  second relay should have refused"; exit 1
fi
grep -q 'another relay already holds' "$TMP/err" || { echo "  no refusal line:"; cat "$TMP/err"; exit 1; }
assert "$("$QUEUE" depth)" "QUEUE pending=2 inflight=0 done=24"
exec 9>&-

# --- requeue the give-up leftovers (f1/f2 in .inflight) with queue.sh nack
"$QUEUE" nack
assert "$("$QUEUE" depth)" "QUEUE pending=2 inflight=0 done=24"

# released lock lets a fresh relay run again; it drains everything
"$RELAY" --once --interval 0.2
assert "$("$QUEUE" depth)" "QUEUE pending=0 inflight=0 done=26"

# --- a crash-stranded batch in .inflight is reclaimed at relay startup ---
export COORD_RESUME="$TMP/fake-resume|__SESSION__|__BATCH__"
"$QUEUE" enqueue str1 'DONE str1: done' >/dev/null
"$QUEUE" pop-batch "$TMP/crashed-batch" >/dev/null   # claimed, never acked
assert "$("$QUEUE" depth)" "QUEUE pending=0 inflight=1 done=26"
"$RELAY" --once --interval 0.2
assert "$("$QUEUE" depth)" "QUEUE pending=0 inflight=0 done=27"

# --- liveness: a dispatched pid that exited without finishing -> DIED event
export COORD_STANDING="$TMP/standing.md"
STATE="$HERE/../scripts/state.sh"
bash -c 'exit 0' & dead=$!; wait "$dead"
sleep 30 & live=$!
bash -c 'exit 0' & fin=$!; wait "$fin"
"$STATE" add d1 "dies" >/dev/null;  "$STATE" dispatch d1 "$dead" /wt d1 d1 >/dev/null
"$STATE" add d2 "runs" >/dev/null;  "$STATE" dispatch d2 "$live" /wt d2 d2 >/dev/null
"$STATE" add d3 "finished" >/dev/null; "$STATE" dispatch d3 "$fin" /wt d3 d3 >/dev/null
"$QUEUE" enqueue d3 'DONE d3: done' >/dev/null
printf '1. keep it small\n' > "$COORD_STANDING"
: > "$RELAY_LOG"

"$RELAY" --once --interval 0.2
"$STATE" drop d2 >/dev/null; kill "$live" 2>/dev/null || true
batch="$(sed 's/.*WAKE batch=//' "$RELAY_LOG")"
grep -q "^EVENT d1.died.$dead DIED d1: pid $dead exited without finish.sh" "$batch" || {
  echo "  no DIED for d1:"; cat "$batch"; exit 1; }
grep -q 'd2' "$batch" && { echo "  live d2 reported:"; cat "$batch"; exit 1; }
grep -q 'DIED d3' "$batch" && { echo "  finished d3 reported dead"; exit 1; }
# standing orders ride on every batch
grep -q '^1. keep it small$' "$batch" || { echo "  standing orders missing:"; cat "$batch"; exit 1; }

# a DIED is reported once per launch, not once per relay loop
"$QUEUE" enqueue n1 'DONE n1: done' >/dev/null
: > "$RELAY_LOG"
"$RELAY" --once --interval 0.2
batch="$(sed 's/.*WAKE batch=//' "$RELAY_LOG")"
grep -q 'DIED d1' "$batch" && { echo "  DIED re-reported"; exit 1; }
[ "$(grep -c '^EVENT ' "$batch")" = 1 ] || { echo "  unexpected events:"; cat "$batch"; exit 1; }

echo "  relay ok"
