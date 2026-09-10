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
assert "$(ls "$COORD_ROOT/queue/.done" | wc -l)" "20"

echo "  relay ok"
