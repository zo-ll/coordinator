#!/usr/bin/env bash
# relay.sh: one batch per wave, config-driven resume, ack on success.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELAY="$HERE/../scripts/relay.sh"
QUEUE="$HERE/../scripts/queue.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export COORD_ROOT="$TMP/coord"
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

# __SERVER__ placeholder substitution from COORD_OPENCODE_SERVER (opencode attach wake)
# isolated root + own log: --once only exits after processing a wave
cat > "$TMP/server-resume" <<'EOF'
#!/usr/bin/env bash
printf 'RAW:%s\n' "$*" >> "$SERVER_LOG"
EOF
chmod +x "$TMP/server-resume"
export SERVER_LOG="$TMP/server.log"
export COORD_ROOT="$TMP/root2"
"$QUEUE" enqueue srv 'DONE srv: done' >/dev/null
COORD_RESUME="$TMP/server-resume|--attach|__SERVER__|__SESSION__|__BATCH__" \
  COORD_OPENCODE_SERVER="http://127.0.0.1:45111" "$RELAY" --once --interval 0.2
server_line="$(cat "$TMP/server.log")"
case "$server_line" in
  *"--attach http://127.0.0.1:45111"*) ;;
  *) echo "  __SERVER__ not substituted: $server_line"; exit 1 ;;
esac
export COORD_ROOT="$TMP/coord"

# --- lean brief wake + coalescing: related events route as ONE wake session ---
export BRIEF_COUNT="$TMP/brief-count"
cat > "$TMP/brief-resume" <<'EOF'
#!/usr/bin/env bash
n=$(cat "$BRIEF_COUNT" 2>/dev/null || echo 0); echo $((n + 1)) > "$BRIEF_COUNT"
printf '%s\n' "$*" >> "$RELAY_LOG"
EOF
chmod +x "$TMP/brief-resume"
export COORD_ROOT="$TMP/root4"
mkdir -p "$TMP/.coordinator"
printf 'a\tdispatched\t-\ta\t1\t\t\t\t\t\t\t\n' > "$TMP/.coordinator/ledger.tsv"
"$QUEUE" enqueue lean2 'DONE b: done' >/dev/null
"$QUEUE" enqueue lean1 'DONE a: done — one' >/dev/null
: > "$RELAY_LOG"; rm -f "$BRIEF_COUNT"
COORD_RESUME="$TMP/brief-resume|__BATCH__" RELAY_BRIEF=1 RELAY_DRAIN=1 "$RELAY" --once --interval 0.2
assert "$(cat "$BRIEF_COUNT")" "1"
assert "$(grep -c 'EVENT lean' "$RELAY_LOG")" "2"
grep -q 'COORDINATOR WAKE' "$RELAY_LOG" || { echo "  no brief header in wake"; exit 1; }
grep -q 'state.sh resolve' "$RELAY_LOG" || { echo "  routing rules missing from brief"; exit 1; }
export COORD_ROOT="$TMP/coord"

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
batch="${batch%% —*}"
[ -f "$batch" ] || { echo "  batch file missing: $batch"; exit 1; }
assert "$(grep -c '^EVENT ' "$batch")" "20"

# acknowledged: nothing pending, everything in done
assert "$("$QUEUE" list | wc -l)" "0"
assert "$(ls "$COORD_ROOT/queue/.done" | wc -l)" "20"

# the headless coordinator's narration is captured for the dashboard:
# relay.sh writes the wake marker + wake command output to turn.log
assert "$(grep -c '^=== turn ' "$COORD_ROOT/turn.log")" "1"
assert "$(grep -c 'WAKE batch=' "$COORD_ROOT/turn.log")" "1"

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
out="$("$QUEUE" enqueue str1 'DONE str1: done')"
ping="${out##* }"
mv "$COORD_ROOT/queue/$ping" "$COORD_ROOT/queue/.inflight/"
assert "$("$QUEUE" depth)" "QUEUE pending=0 inflight=1 done=26"
"$RELAY" --once --interval 0.2
assert "$("$QUEUE" depth)" "QUEUE pending=0 inflight=0 done=27"

echo "  relay ok"

# codex rollout-style session id (timestamped/rollout-prefixed) must normalize
# to the bare uuid the queue wake expects
cat > "$TMP/id-resume" <<'IDEOF'
#!/usr/bin/env bash
printf 'ID:%s\n' "$*" >> "$RELAY_LOG"
IDEOF
chmod +x "$TMP/id-resume"
export COORD_ROOT="$TMP/root3"
"$QUEUE" enqueue srv3 'DONE srv3: done' >/dev/null
COORD_RESUME="$TMP/id-resume|__SESSION__|__BATCH__" \
  COORD_SESSION="rollout-2026-09-14T17-12-11-01a0a079-caa2-7b03-a986-0a47f70e7c12" \
  "$RELAY" --once --interval 0.2
id_line="$(tail -1 "$RELAY_LOG")"
case "$id_line" in
  *"01a0a079-caa2-7b03-a986-0a47f70e7c12"*) ;;
  *) echo "  session not normalized: $id_line"; exit 1 ;;
esac
case "$id_line" in
  *"2026-09-14T17-12-11-"*) echo "  timestamp still in session: $id_line"; exit 1 ;;
esac
export COORD_ROOT="$TMP/coord"

echo "  session-id normalization ok"
