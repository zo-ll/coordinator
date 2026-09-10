#!/usr/bin/env bash
# Queue: ordering, de-dup, concurrency, batching.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
Q="$HERE/../scripts/queue.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export COORD_ROOT="$TMP/coord"

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }

# enqueue + order
assert "$("$Q" enqueue a 'DONE a: done — one')" "ENQUEUED a 000000000001.a.ping"
assert "$("$Q" enqueue b 'DONE b: done — two')" "ENQUEUED b 000000000002.b.ping"

# de-dup: retry of the same slug is a no-op
assert "$("$Q" enqueue a 'DONE a: done — changed')" "DUP a"
assert "$("$Q" list | wc -l)" "2"

# a new round is a new slug: delivered
assert "$("$Q" enqueue a.r2 'DONE a: done — round 2')" "ENQUEUED a.r2 000000000003.a.r2.ping"

# concurrent enqueue: no lost, no double, unique seq
for i in $(seq 1 20); do
  "$Q" enqueue "c$i" "DONE c$i: done — x" >/dev/null &
done
wait
assert "$("$Q" list | wc -l)" "23"
assert "$("$Q" list | awk '{print $2}' | sort -u | wc -l)" "23"

# pending / pop-batch claim all in order, then ack to done
assert "$("$Q" pending && echo yes)" "yes"
batch="$TMP/batch"
"$Q" pop-batch "$batch" >/dev/null
assert "$("$Q" list | wc -l)" "0"
assert "$(grep -c '^EVENT ' "$batch")" "23"
assert "$(head -n1 "$batch")" "EVENT a DONE a: done — one"
"$Q" ack
assert "$(ls "$COORD_ROOT/queue/.done" | wc -l)" "23"
if "$Q" pending; then echo "  queue should be empty"; exit 1; fi

echo "  queue ok"
