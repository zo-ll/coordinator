#!/usr/bin/env bash
# filo relay: one batch per wave, bounded retries, one relay per run,
# redelivery after a crash, dead launches, the retry cap, and timeboxes.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
fake_resume
brief "$TMP/brief"
status_line() { "$FILO" status | head -n1; }
last_batch() { sed 's/.*WAKE batch=//' "$RELAY_LOG" | tail -n1; }

# --- N workers finish at once: every finish once, one resume for all ---
for i in $(seq 1 10); do "$FILO" unit add "c$i" --kind feature --goal "unit $i" >/dev/null; done
for i in $(seq 1 10); do "$FILO" dispatch "c$i" --role worker --brief "$TMP/brief" >/dev/null & done
wait
wait_for bash -c '[ "$("$FILO" status | grep -c " built ")" = 10 ]'
printf '1. keep it small\n' > "$REPO/.filo/standing.md"
"$FILO" relay --once --interval 0.1
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
"$FILO" msg - "hello" >/dev/null
if FILO_RESUME=fail-resume "$FILO" relay --once --max-attempts 3 --backoff 0 >/dev/null 2>"$TMP/err"; then
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
FILO_RESUME="flaky-resume|__BATCH__" "$FILO" relay --once --max-attempts 5 --backoff 0 2>/dev/null
has "$(status_line)" "undelivered=0 inflight=0"
has "$(cat "$(last_batch)")" "- msg hello"

# --- a second relay refuses while one holds the lock ---
"$FILO" msg - "two" >/dev/null
exec 9>"$REPO/.filo/relay.lock"
flock -n 9
refuses "another relay already holds" "$FILO" relay --once
exec 9>&-

# --- a relay killed mid-turn leaves the batch claimed; the next redelivers it ---
cat > "$TMP/bin/crash-resume" <<'F'
#!/usr/bin/env bash
kill -9 "$(cat "$REPO/.filo/relay.pid")"
F
chmod +x "$TMP/bin/crash-resume"
( FILO_RESUME=crash-resume "$FILO" relay --once; true ) 2>/dev/null || true
has "$(status_line)" "undelivered=0 inflight=1"
: > "$RELAY_LOG"
"$FILO" relay --once --interval 0.1
has "$(status_line)" "undelivered=0 inflight=0"
has "$(cat "$(last_batch)")" "- msg two"

# --- a launch that exits without finishing -> died; twice in a round -> blocked ---
export FAKE_WORKER=exit
"$FILO" unit add d1 --kind feature --goal dies >/dev/null
"$FILO" dispatch d1 --role worker --brief "$TMP/brief" >/dev/null
"$FILO" relay --once --interval 0.1
has "$(cat "$(last_batch)")" "d1 died d1.r1.worker pid="
assert "$(state_of d1)" "stalled"
has "$("$FILO" dispatch d1 --role worker)" "round=1"   # same round, brief reused
"$FILO" relay --once --interval 0.1
b="$(cat "$(last_batch)")"
has "$b" "d1 died d1.r1.worker"
has "$b" "d1 blocked died 2 times in round 1"
assert "$(state_of d1)" "blocked"

# --- a launch past its timebox is killed with its group and reported ---
export FAKE_WORKER=sleep
{ cat "$TMP/brief"; echo "TIMEBOX: 1s"; } > "$TMP/quick"
"$FILO" unit add t1 --kind feature --goal slow >/dev/null
"$FILO" dispatch t1 --role worker --brief "$TMP/quick" >/dev/null
pid="$("$FILO" status | awk '$2=="t1" {print $7}' | cut -d= -f2)"
kill -0 "$pid"
"$FILO" relay --once --interval 0.2
has "$(cat "$(last_batch)")" "t1 died t1.r1.worker pid=$pid timeout"
kill -0 "$pid" 2>/dev/null && { echo "  timed-out launch still alive"; exit 1; }
assert "$(state_of t1)" "stalled"

# --- --stop stops this run's relay, and says so when there is none ---
FAKE_WORKER=exit "$FILO" relay --interval 0.2 >/dev/null 2>&1 &
wait_for test -s "$REPO/.filo/relay.pid"
rp=$(cat "$REPO/.filo/relay.pid")
assert "$("$FILO" relay --stop)" "STOPPED relay pid=$rp"
kill -0 "$rp" 2>/dev/null && { echo "  relay still alive"; exit 1; }
assert "$("$FILO" relay --stop)" "RELAY none running"
# a pidfile left by a killed relay names someone else's process: never theirs to stop
sleep 300 & bystander=$!
echo "$bystander" > "$REPO/.filo/relay.pid"
assert "$("$FILO" relay --stop)" "RELAY none running"
kill -0 "$bystander" || { echo "  --stop killed a bystander"; exit 1; }
kill "$bystander"; rm "$REPO/.filo/relay.pid"
# stop right after a start: never loses the relay (the start waits for its lock)
echo "sess-1" > "$REPO/.filo/session"
for i in 1 2 3 4 5; do
  "$FILO" relay --detach >/dev/null; has "$("$FILO" relay --stop)" "STOPPED relay pid="
done
[ "$("$FILO" relay --stop)" = "RELAY none running" ] || { echo "  a relay survived --stop"; exit 1; }
# a stop during an idle wait or a retry wait is prompt, and starts no new turn
printf '#!/usr/bin/env bash\necho run >> "$TMP/fails"; exit 1\n' > "$TMP/bin/fail-resume"; chmod +x "$TMP/bin/fail-resume"
: > "$TMP/fails"; "$FILO" msg - "retry me" >/dev/null
FILO_RESUME="fail-resume|__BATCH__" TMP="$TMP" "$FILO" relay --interval 0.2 --backoff 20 >/dev/null 2>&1 &
wait_for test -s "$TMP/fails"
assert "$("$FILO" relay --stop)" "STOPPED relay pid=$!"
assert "$(wc -l < "$TMP/fails")" 1                                          # no second attempt
has "$("$FILO" log | tail -n1)" "nacked"                                    # the events wait for the next relay
# stopped during a coordinator turn: the turn finishes and is acked, then the relay leaves
printf '#!/usr/bin/env bash\nsleep 8\n' > "$TMP/bin/slow-resume"; chmod +x "$TMP/bin/slow-resume"
"$FILO" msg - "wake up" >/dev/null
FILO_RESUME="slow-resume|__BATCH__" "$FILO" relay --interval 0.2 >/dev/null 2>&1 &
wait_for bash -c '"$FILO" status | grep -q "inflight=[1-9]"'
rp=$(cat "$REPO/.filo/relay.pid")
assert "$("$FILO" relay --stop)" "STOPPING relay pid=$rp (after the coordinator's turn in flight)"
wait_for bash -c "! kill -0 $rp 2>/dev/null"
has "$("$FILO" status | head -n1)" "inflight=0"
has "$("$FILO" log | tail -n1)" "acked"

# --- --detach restarts this run's relay once, and only once ---
echo "sess-1" > "$REPO/.filo/session"
out="$("$FILO" relay --detach)"
has "$out" "RELAY pid="
pid="${out##*pid=}"
kill -0 "$pid"
has "$("$FILO" relay --detach)" "RELAY pid=$pid (already running)"
kill "$pid"

echo "  relay ok"
