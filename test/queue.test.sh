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
assert "$("$Q" depth)" "QUEUE pending=23 inflight=0 done=0"
batch="$TMP/batch"
"$Q" pop-batch "$batch" >/dev/null
assert "$("$Q" depth)" "QUEUE pending=0 inflight=23 done=0"
assert "$("$Q" list | wc -l)" "0"
assert "$(grep -c '^EVENT ' "$batch")" "23"
assert "$(head -n1 "$batch")" "EVENT a DONE a: done — one"
"$Q" ack
assert "$("$Q" depth)" "QUEUE pending=0 inflight=0 done=23"
assert "$(ls "$COORD_ROOT/queue/.done" | wc -l)" "23"

# concurrent retries of the SAME slug publish exactly once (atomic enqueue)
for i in $(seq 1 10); do
  "$Q" enqueue dupme 'DONE dupme: done' >/dev/null &
done
wait
assert "$("$Q" list | wc -l)" "1"
assert "$("$Q" list | awk '{print $2}')" "dupme"
assert "$("$Q" enqueue dupme 'DONE dupme: done')" "DUP dupme"
"$Q" pop-batch "$TMP/batch2" >/dev/null
"$Q" ack
assert "$("$Q" depth)" "QUEUE pending=0 inflight=0 done=24"

# explicit de-dup key: same event slug stays quiet only for the same key,
# so a new round or changed head still notifies the coordinator
assert "$("$Q" enqueue e 'DONE e: done — r1 a' 'e.r1.aaaa')" "ENQUEUED e 000000000025.e.ping"
assert "$("$Q" enqueue e 'DONE e: done — r1 b' 'e.r1.aaaa')" "DUP e"
assert "$("$Q" enqueue e 'DONE e: done — r1 c' 'e.r1.bbbb')" "ENQUEUED e 000000000026.e.ping"
assert "$("$Q" enqueue e 'DONE e: done — r2 a' 'e.r2.aaaa')" "ENQUEUED e 000000000027.e.ping"
assert "$("$Q" list | wc -l)" "3"
"$Q" pop-batch "$TMP/batch3" >/dev/null
"$Q" ack
assert "$("$Q" depth)" "QUEUE pending=0 inflight=0 done=27"

if "$Q" pending; then echo "  queue should be empty"; exit 1; fi

# a third argument is optional: no key means de-dup on the slug, as before
export COORD_ROOT="$TMP/coord-default"
assert "$("$Q" enqueue k 'DONE k: done')" "ENQUEUED k 000000000001.k.ping"
assert "$("$Q" enqueue k 'DONE k: done again')" "DUP k"

echo "  queue ok"
