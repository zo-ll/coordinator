#!/usr/bin/env bash
# The views: status (units, live launches, delivery, gates), log, done.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"
export FAKE_WORKER=sleep

"$FILO" unit add a --kind feature --goal "first slice" >/dev/null
"$FILO" unit add b --kind chore --goal "second slice" --deps a >/dev/null
"$FILO" dispatch a --role worker --brief "$TMP/brief" >/dev/null
echo "starting" >> "$REPO/.filo/log/a.r1.worker.log"
echo "working on it" >> "$REPO/.filo/log/a.r1.worker.log"

out="$("$FILO" status)"
assert "$(printf '%s\n' "$out" | sed -n 1p)" "STATUS relay=- alive=0 undelivered=0 inflight=0"
has "$(printf '%s\n' "$out" | grep '^UNIT a ')" "UNIT a working kind=feature round=1 ready=0 pid="
has "$(printf '%s\n' "$out" | grep '^UNIT a ')" "alive=1 goal=first slice"
assert "$(printf '%s\n' "$out" | grep '^UNIT b ')" "UNIT b todo kind=chore round=0 ready=0 pid=- alive=0 goal=second slice"
assert "$(printf '%s\n' "$out" | grep '^LOG ')" "LOG a a.r1.worker working on it"

if out="$("$FILO" done)"; then echo "  done with open units"; exit 1; fi
assert "$out" "OPEN a b"
"$FILO" block a --reason stop >/dev/null
assert "$("$FILO" log a | awk '{print $2}' | paste -sd, -)" "unit_added,dispatched,blocked"
"$FILO" drop a --reason x >/dev/null; "$FILO" drop b --reason x >/dev/null
assert "$("$FILO" done)" "DONE units=2"

echo "  view ok"
