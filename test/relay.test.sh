#!/usr/bin/env bash
# coord relay: one batch per wave, bounded retries, one relay per run,
# redelivery after a crash, dead launches, the retry cap, and timeboxes.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
fake_resume
brief "$TMP/brief"
status_line() { "$COORD" status | head -n1; }
last_batch() { sed 's/.*WAKE batch=//' "$RELAY_LOG" | tail -n1; }

# --- N workers finish at once: every finish once, one resume for all ---
for i in $(seq 1 10); do "$COORD" unit add "c$i" --kind feature --goal "unit $i" >/dev/null; done
for i in $(seq 1 10); do "$COORD" dispatch "c$i" --role worker --brief "$TMP/brief" >/dev/null & done
wait
wait_for bash -c '[ "$("$COORD" status | grep -c " built ")" = 10 ]'
printf '1. keep it small\n' > "$REPO/.coordinator/standing.md"
"$COORD" relay --once --interval 0.1
assert "$(wc -l < "$RELAY_LOG" | tr -d ' ')" "1"
has "$(cat "$RELAY_LOG")" "sess-1 WAKE batch="
batch="$(last_batch)"
assert "$(grep -c '^EVENT [0-9]* c[0-9]* finished c[0-9]*.r1.worker done — did it$' "$batch")" "10"
grep -qx '1. keep it small' "$batch" || { echo "  standing orders missing"; exit 1; }
has "$(status_line)" "undelivered=0 inflight=0"

# --- permanent failure: bounded retries, loud give-up, events returned ---
cat > "$TMP/bin/fail-resume" <<'F'
#!/usr/bin/env bash
exit 1
F
chmod +x "$TMP/bin/fail-resume"
"$COORD" msg - "hello" >/dev/null
if COORD_RESUME=fail-resume "$COORD" relay --once --max-attempts 3 --backoff 0 >/dev/null 2>"$TMP/err"; then
  echo "  relay should have given up"; exit 1
fi
grep -q 'attempt 1/3' "$TMP/err" || { echo "  no retry line:"; cat "$TMP/err"; exit 1; }
grep -q 'returned the events and stopped' "$TMP/err" || { echo "  no give-up line:"; cat "$TMP/err"; exit 1; }
has "$(status_line)" "undelivered=1 inflight=0"

# --- transient failure: retried, then acked ---
cat > "$TMP/bin/flaky-resume" <<F
#!/usr/bin/env bash
n=\$(cat "$TMP/count" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > "$TMP/count"
[ \$n -ge 2 ] || exit 1
printf '%s\n' "\$*" >> "$RELAY_LOG"
F
chmod +x "$TMP/bin/flaky-resume"
COORD_RESUME="flaky-resume|__BATCH__" "$COORD" relay --once --max-attempts 5 --backoff 0 2>/dev/null
has "$(status_line)" "undelivered=0 inflight=0"
has "$(cat "$(last_batch)")" "- msg hello"

# --- a second relay refuses while one holds the lock ---
"$COORD" msg - "two" >/dev/null
exec 9>"$REPO/.coordinator/relay.lock"
flock -n 9
refuses "another relay already holds" "$COORD" relay --once
exec 9>&-

# --- a relay killed mid-turn leaves the batch claimed; the next redelivers it ---
cat > "$TMP/bin/crash-resume" <<'F'
#!/usr/bin/env bash
kill -9 "$(cat "$REPO/.coordinator/relay.pid")"
F
chmod +x "$TMP/bin/crash-resume"
( COORD_RESUME=crash-resume "$COORD" relay --once; true ) 2>/dev/null || true
has "$(status_line)" "undelivered=0 inflight=1"
: > "$RELAY_LOG"
"$COORD" relay --once --interval 0.1
has "$(status_line)" "undelivered=0 inflight=0"
has "$(cat "$(last_batch)")" "- msg two"

# --- a launch that exits without finishing -> died; twice in a round -> blocked ---
export FAKE_WORKER=exit
"$COORD" unit add d1 --kind feature --goal dies >/dev/null
"$COORD" dispatch d1 --role worker --brief "$TMP/brief" >/dev/null
"$COORD" relay --once --interval 0.1
has "$(cat "$(last_batch)")" "d1 died d1.r1.worker pid="
assert "$(state_of d1)" "stalled"
has "$("$COORD" dispatch d1 --role worker)" "round=1"   # same round, brief reused
"$COORD" relay --once --interval 0.1
b="$(cat "$(last_batch)")"
has "$b" "d1 died d1.r1.worker"
has "$b" "d1 blocked died 2 times in round 1"
assert "$(state_of d1)" "blocked"

# --- a launch past its timebox is killed with its group and reported ---
export FAKE_WORKER=sleep
{ cat "$TMP/brief"; echo "TIMEBOX: 1s"; } > "$TMP/quick"
"$COORD" unit add t1 --kind feature --goal slow >/dev/null
"$COORD" dispatch t1 --role worker --brief "$TMP/quick" >/dev/null
pid="$("$COORD" status | awk '$2=="t1" {print $7}' | cut -d= -f2)"
kill -0 "$pid"
"$COORD" relay --once --interval 0.2
has "$(cat "$(last_batch)")" "t1 died t1.r1.worker pid=$pid timeout"
kill -0 "$pid" 2>/dev/null && { echo "  timed-out launch still alive"; exit 1; }
assert "$(state_of t1)" "stalled"

# --- --detach restarts this run's relay once, and only once ---
echo "sess-1" > "$REPO/.coordinator/session"
out="$("$COORD" relay --detach)"
has "$out" "RELAY pid="
pid="${out##*pid=}"
kill -0 "$pid"
has "$("$COORD" relay --detach)" "RELAY pid=$pid (already running)"
kill "$pid"

echo "  relay ok"
