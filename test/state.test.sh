#!/usr/bin/env bash
# state.sh: blockers -> ready, transitions, done, render.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$HERE/../scripts/state.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export COORD_EVENTS="$TMP/repo/.coordinator/events.jsonl"
export COORD_DASHBOARD="$TMP/repo/COORDINATION.md"

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }

"$STATE" add s1 "first slice" >/dev/null
"$STATE" add s2 "second slice" --blockers s1 >/dev/null
assert "$("$STATE" get s1 status)" "todo"

"$STATE" ready >/dev/null
assert "$("$STATE" get s1 status)" "ready"
assert "$("$STATE" get s2 status)" "todo"
assert "$("$STATE" next)" "s1"

"$STATE" dispatch s1 1234 /wt/1 coord/1-s1 1-s1 >/dev/null
assert "$("$STATE" get s1 status)" "dispatched"
assert "$("$STATE" get s1 pid)" "1234"

"$STATE" verdict s1 1 pass abc123 >/dev/null
assert "$("$STATE" get s1 verdict)" "pass"
assert "$("$STATE" get s1 head)" "abc123"
if "$STATE" done; then echo "  done too early"; exit 1; fi

"$STATE" merged s1 m1 >/dev/null
"$STATE" ready >/dev/null
assert "$("$STATE" get s2 status)" "ready"

"$STATE" drop s2 >/dev/null
if ! "$STATE" done; then echo "  should be done after merge+drop"; exit 1; fi

# handback keeps the run open
"$STATE" add s3 "third" >/dev/null
"$STATE" ready >/dev/null
"$STATE" verdict s3 1 handback deadbeef >/dev/null
assert "$("$STATE" get s3 status)" "handback"
if "$STATE" done; then echo "  done with a handback pending"; exit 1; fi

# duplicate id is rejected
if "$STATE" add s1 again >/dev/null 2>&1; then echo "  duplicate id allowed"; exit 1; fi

# render writes the dashboard
"$STATE" render >/dev/null
grep -q '| s1 | merged |' "$COORD_DASHBOARD" || { echo "  render missing s1"; exit 1; }

# one line per slice
assert "$("$STATE" list | wc -l)" "3"

# live: only dispatched/reviewing slices, as "id pid task"
"$STATE" add s4 "fourth" >/dev/null
"$STATE" dispatch s4 999 /wt/4 b4 s4.r2 >/dev/null
assert "$("$STATE" live)" "s4 999 s4.r2"

echo "  state ok"
