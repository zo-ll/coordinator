#!/usr/bin/env bash
# User decisions and unit control: approve, reject, msg, block (stops the
# live launch), reopen (next round), drop.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"

# to passed through the fake worker and critic
"$COORD" unit add a --kind feature --goal one >/dev/null
"$COORD" dispatch a --role worker --brief "$TMP/brief" >/dev/null
wait_for is_state a built
"$COORD" dispatch a --role critic >/dev/null
wait_for is_state a passed

refuses "REFUSED b approved: unknown unit" "$COORD" approve b
assert "$("$COORD" reject a "not like this")" "REJECTED a"
assert "$(state_of a)" "handback"
refuses "cannot approve from handback" "$COORD" approve a
assert "$("$COORD" msg a "use the new API")" "MSG a"
assert "$("$COORD" msg - "status please")" "MSG -"
refuses "<text> is required" "$COORD" msg a

# block stops the live launch; reopen continues at the next round
export FAKE_WORKER=sleep
"$COORD" dispatch a --role worker --brief "$TMP/brief" >/dev/null
pid="$("$COORD" status | awk '$2=="a" {print $7}' | cut -d= -f2)"
kill -0 "$pid"
refuses "--reason is required" "$COORD" block a
assert "$("$COORD" block a --reason "waiting on API")" "BLOCKED a"
wait_for bash -c "! kill -0 $pid 2>/dev/null"
assert "$("$COORD" reopen a --reason "API landed")" "REOPENED a"
export FAKE_WORKER=exit
has "$("$COORD" dispatch a --role worker --brief "$TMP/brief")" "round=3"
assert "$("$COORD" drop a --reason "superseded")" "DROPPED a"
refuses "dropped not allowed from dropped" "$COORD" drop a --reason again

# the user's decisions wake the coordinator
has "$("$COORD" log a)" "rejected a not like this"
has "$("$COORD" log)" "msg - status please"

echo "  decide ok"
