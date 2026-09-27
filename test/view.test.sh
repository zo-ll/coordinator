#!/usr/bin/env bash
# The views: status (units, live launches, delivery, gates), log, done.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"
export FAKE_WORKER=sleep

"$COORD" unit add a --kind feature --goal "first slice" >/dev/null
"$COORD" unit add b --kind chore --goal "second slice" --deps a >/dev/null
"$COORD" dispatch a --role worker --brief "$TMP/brief" >/dev/null
echo "starting" >> "$REPO/.coordinator/log/a.r1.worker.log"
echo "working on it" >> "$REPO/.coordinator/log/a.r1.worker.log"

out="$("$COORD" status)"
assert "$(printf '%s\n' "$out" | sed -n 1p)" "STATUS relay=- alive=0 undelivered=0 inflight=0"
has "$(printf '%s\n' "$out" | grep '^UNIT a ')" "UNIT a working kind=feature round=1 ready=0 pid="
has "$(printf '%s\n' "$out" | grep '^UNIT a ')" "alive=1 goal=first slice"
assert "$(printf '%s\n' "$out" | grep '^UNIT b ')" "UNIT b todo kind=chore round=0 ready=0 pid=- alive=0 goal=second slice"
assert "$(printf '%s\n' "$out" | grep '^LOG ')" "LOG a a.r1.worker working on it"

if out="$("$COORD" done)"; then echo "  done with open units"; exit 1; fi
assert "$out" "OPEN a b"
"$COORD" block a --reason stop >/dev/null
assert "$("$COORD" log a | awk '{print $2}' | paste -sd, -)" "unit_added,dispatched,blocked"
"$COORD" drop a --reason x >/dev/null; "$COORD" drop b --reason x >/dev/null
assert "$("$COORD" done)" "DONE units=2"

echo "  view ok"
