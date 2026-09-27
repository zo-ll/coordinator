#!/usr/bin/env bash
# The event log: gapless seq under concurrent writers, a torn final line
# ignored on read and repaired by the next append, one source of truth for
# both the queue and the ledger.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Q="$HERE/../scripts/queue.sh"
STATE="$HERE/../scripts/state.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export COORD_ROOT="$TMP/coord"
export COORD_EVENTS="$TMP/events.jsonl"

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }
seqs() { sed -E 's/^\{"seq":([0-9]+),.*/\1/' "$COORD_EVENTS" | paste -sd' ' -; }

# queue and ledger writes interleave in one log, seq gapless
"$STATE" add s1 "one" >/dev/null
"$Q" enqueue p1 'DONE p1: done' >/dev/null
"$STATE" ready >/dev/null
assert "$(seqs)" "1 2 3"

# concurrent writers of both kinds: every seq exactly once, in file order
for i in $(seq 1 15); do
  "$Q" enqueue "c$i" "DONE c$i: done" >/dev/null &
  "$STATE" add "u$i" "unit $i" >/dev/null &
done
wait
assert "$(seqs)" "$(seq 1 33 | paste -sd' ' -)"
assert "$("$Q" depth)" "QUEUE pending=16 inflight=0 done=0"
assert "$("$STATE" list | wc -l)" "16"

# a torn final line (crash mid-write) is invisible to readers...
printf '{"seq":34,"ts":"x","type":"enqu' >> "$COORD_EVENTS"
assert "$("$Q" depth)" "QUEUE pending=16 inflight=0 done=0"
# ...and cut off by the next append, which takes seq 34
"$Q" enqueue after 'DONE after: done' >/dev/null
assert "$(tail -n1 "$COORD_EVENTS" | grep -c '"slug":"after"')" "1"
assert "$(seqs | tr ' ' '\n' | tail -n1)" "34"
if grep -q '"type":"enqu"\|"enqu$' "$COORD_EVENTS"; then echo "  torn line survived"; exit 1; fi

echo "  events ok"
