#!/usr/bin/env bash
# The event log: gapless seq under concurrent writers, a torn final line
# ignored on read and repaired by the next append, refusals never recorded.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
seqs() { sed -E 's/^seq=([0-9]+)\t.*/\1/' "$FILO_EVENTS" | paste -sd' ' -; }

for i in $(seq 1 15); do
  "$FILO" unit add "u$i" --kind chore --goal "unit $i" >/dev/null &
  "$FILO" msg - "note $i" >/dev/null &
done
wait
assert "$(seqs)" "$(seq 1 30 | paste -sd' ' -)"
assert "$("$FILO" unit next | wc -w | tr -d ' ')" "15"

# a refused event is never written
refuses "id already exists" "$FILO" unit add u1 --kind chore --goal again
assert "$(wc -l < "$FILO_EVENTS" | tr -d ' ')" "30"

# a torn final line (crash mid-write) is invisible to readers...
# (complete-looking fields, but no terminator: it was cut mid-write)
printf 'seq=31\tts=x\ttype=unit_added\tunit=ghost\tkind=chore' >> "$FILO_EVENTS"
assert "$("$FILO" unit next | wc -w | tr -d ' ')" "15"
# ...and cut off by the next append, which takes seq 31
"$FILO" unit add late --kind chore --goal late >/dev/null
assert "$(seqs | tr ' ' '\n' | tail -n1)" "31"
tail -n1 "$FILO_EVENTS" | grep -q $'\tunit=late\t' || { echo "  append did not land cleanly"; exit 1; }
if grep -q 'unit=ghost' "$FILO_EVENTS"; then echo "  torn line survived"; exit 1; fi

echo "  events ok"
