#!/usr/bin/env bash
# User decisions and unit control: approve, reject, msg, block (stops the
# live launch), reopen (next round), drop.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"

# to passed through the fake worker and critic
"$FILO" unit add a --kind feature --goal one >/dev/null
"$FILO" dispatch a --role worker --brief "$TMP/brief" >/dev/null
wait_for is_state a built
"$FILO" dispatch a --role critic >/dev/null
wait_for is_state a passed

refuses "REFUSED b approved: unknown unit" "$FILO" approve b
assert "$("$FILO" reject a "not like this")" "REJECTED a"
assert "$(state_of a)" "handback"
refuses "cannot approve from handback" "$FILO" approve a
assert "$("$FILO" msg a "use the new API")" "MSG a"
assert "$("$FILO" msg - "status please")" "MSG -"
refuses "<text> is required" "$FILO" msg a

# block stops the live launch; reopen continues at the next round
export FAKE_WORKER=sleep
"$FILO" dispatch a --role worker --brief "$TMP/brief" >/dev/null
pid="$("$FILO" status | awk '$2=="a" {print $7}' | cut -d= -f2)"
kill -0 "$pid"
refuses "--reason is required" "$FILO" block a
assert "$("$FILO" block a --reason "waiting on API")" "BLOCKED a"
wait_for bash -c "! kill -0 $pid 2>/dev/null"
assert "$("$FILO" reopen a --reason "API landed")" "REOPENED a"
export FAKE_WORKER=exit
has "$("$FILO" dispatch a --role worker --brief "$TMP/brief")" "round=3"
assert "$("$FILO" drop a --reason "superseded" | head -n1)" "DROPPED a"
refuses "dropped not allowed from dropped" "$FILO" drop a --reason again

# the user's decisions wake the coordinator
has "$("$FILO" log a)" "rejected a not like this"
has "$("$FILO" log)" "msg - status please"

echo "  decide ok"
