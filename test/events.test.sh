#!/usr/bin/env bash
# The event log: gapless seq under concurrent writers, a torn final line
# ignored on read and repaired by the next append, refusals never recorded.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
seqs() { sed -E 's/^\{"seq":([0-9]+),.*/\1/' "$COORD_EVENTS" | paste -sd' ' -; }

for i in $(seq 1 15); do
  "$COORD" unit add "u$i" --kind chore --goal "unit $i" >/dev/null &
  "$COORD" msg - "note $i" >/dev/null &
done
wait
assert "$(seqs)" "$(seq 1 30 | paste -sd' ' -)"
assert "$("$COORD" unit next | wc -w | tr -d ' ')" "15"

# a refused event is never written
refuses "id already exists" "$COORD" unit add u1 --kind chore --goal again
assert "$(wc -l < "$COORD_EVENTS" | tr -d ' ')" "30"

# a torn final line (crash mid-write) is invisible to readers...
printf '{"seq":31,"ts":"x","type":"unit_ad' >> "$COORD_EVENTS"
assert "$("$COORD" unit next | wc -w | tr -d ' ')" "15"
# ...and cut off by the next append, which takes seq 31
"$COORD" unit add late --kind chore --goal late >/dev/null
assert "$(seqs | tr ' ' '\n' | tail -n1)" "31"
tail -n1 "$COORD_EVENTS" | grep -q '"unit":"late"' || { echo "  append did not land cleanly"; exit 1; }
if grep -q 'unit_ad"\|unit_ad$' "$COORD_EVENTS"; then echo "  torn line survived"; exit 1; fi

echo "  events ok"
