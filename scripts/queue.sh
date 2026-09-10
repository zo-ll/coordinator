#!/usr/bin/env bash
# Ping queue: ordered, de-duplicated, single-consumer.
#
#   queue.sh enqueue <slug> <line>     -> ENQUEUED <slug> <file> | DUP <slug>
#   queue.sh list                      -> one "<seq> <slug> <file>" line per pending event, in order
#   queue.sh pending                   -> exit 0 if any pending, else 1
#   queue.sh pop-batch <batchfile>     -> claim all pending into <batchfile>, in order
#   queue.sh ack                       -> move claimed events to done/
#   queue.sh nack                      -> return claimed events to the queue
#
# Layout under $COORD_ROOT/queue:
#   *.ping            pending events, named <seq>.<slug>.ping (seq sorts in arrival order)
#   .inflight/        events claimed by the consumer, awaiting ack
#   .done/            acknowledged events
#   .seen/<slug>      de-dup marker, created at enqueue
#   .seq, .seq.lock   ordered sequence counter (flock-guarded)
set -euo pipefail

COORD_ROOT="${COORD_ROOT:-/tmp/coordinator}"
Q="$COORD_ROOT/queue"
INFLIGHT="$Q/.inflight"
DONE="$Q/.done"
SEEN="$Q/.seen"

mkdir -p "$Q" "$INFLIGHT" "$DONE" "$SEEN"

next_seq() {
  local n
  exec 9>"$Q/.seq.lock"
  flock 9
  n=$(( $(cat "$Q/.seq" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$n" > "$Q/.seq"
  flock -u 9
  printf '%s' "$n"
}

cmd="${1:-}"
[ $# -gt 0 ] && shift

case "$cmd" in
  enqueue)
    slug="${1:?slug}"
    line="${2:?line}"
    if [ -e "$SEEN/$slug" ]; then
      printf 'DUP %s\n' "$slug"
      exit 0
    fi
    seq="$(next_seq)"
    f="$(printf '%012d' "$seq").$slug.ping"
    tmp="$Q/.tmp.$$.$RANDOM"
    printf '%s\n' "$line" > "$tmp"
    mv -T -- "$tmp" "$Q/$f"
    : > "$SEEN/$slug"
    printf 'ENQUEUED %s %s\n' "$slug" "$f"
    ;;

  list)
    shopt -s nullglob
    for f in "$Q"/*.ping; do
      b="$(basename "$f" .ping)"
      printf '%s %s %s\n' "${b%%.*}" "${b#*.}" "$f"
    done
    ;;

  pending)
    shopt -s nullglob
    for f in "$Q"/*.ping; do
      [ -e "$f" ] && exit 0
    done
    exit 1
    ;;

  pop-batch)
    batch="${1:?batchfile}"
    shopt -s nullglob
    n=0
    : > "$batch"
    for f in "$Q"/*.ping; do
      b="$(basename "$f" .ping)"
      slug="${b#*.}"
      line="$(head -n1 "$f")"
      printf 'EVENT %s %s\n' "$slug" "$line" >> "$batch"
      mv -T -- "$f" "$INFLIGHT/$b.ping"
      n=$(( n + 1 ))
    done
    printf 'POP n=%s batch=%s\n' "$n" "$batch"
    [ "$n" -gt 0 ]
    ;;

  ack)
    shopt -s nullglob
    for f in "$INFLIGHT"/*.ping; do
      mv -T -- "$f" "$DONE/$(basename "$f")"
    done
    ;;

  nack)
    shopt -s nullglob
    for f in "$INFLIGHT"/*.ping; do
      mv -T -- "$f" "$Q/$(basename "$f")"
    done
    ;;

  *)
    echo "usage: queue.sh enqueue|list|pending|pop-batch|ack|nack" >&2
    exit 2
    ;;
esac
