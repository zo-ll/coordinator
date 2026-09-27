#!/usr/bin/env bash
# The next steps a batch ends with: one NEXT per unit from its current
# state, one per unit-less event, then READY and DONE.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
fake_resume
brief "$TMP/brief"
last_batch() { cat "$(sed 's/.*WAKE batch=//' "$RELAY_LOG" | tail -n1)"; }
wave() { wait_for bash -c "[ \"\$(\"\$COORD\" status | head -n1 | sed 's/.*undelivered=\([0-9]*\).*/\1/')\" -ge $1 ]"; "$COORD" relay --once --interval 0.1; }
line() { printf '%s\n' "$1" | grep "^$2" || true; }

# worker done -> critic; partial -> correction brief; a dependent is not ready yet
"$COORD" unit add a --kind feature --goal a >/dev/null
"$COORD" unit add p --kind feature --goal p >/dev/null
"$COORD" unit add z --kind feature --goal z --deps a >/dev/null
"$COORD" dispatch a --role worker --brief "$TMP/brief" >/dev/null
FAKE_WORKER=partial "$COORD" dispatch p --role worker --brief "$TMP/brief" >/dev/null
wave 2
b="$(last_batch)"
assert "$(line "$b" "NEXT a:")" "NEXT a: coord dispatch a --role critic"
assert "$(line "$b" "NEXT p:")" "NEXT p: write a correction: coord brief p, fill in its CORRECTION from the reason above, then: coord dispatch p --role worker"
assert "$(line "$b" READY)" ""

# critic pass -> ask the user (never a bare approve); approved -> merge
"$COORD" dispatch a --role critic >/dev/null
wave 1
assert "$(line "$(last_batch)" "NEXT a:")" "NEXT a: ASK THE USER to approve a round 1 (an approval of an earlier round does not carry over); on yes: coord approve a && coord merge a"
"$COORD" approve a >/dev/null
wave 1
assert "$(line "$(last_batch)" "NEXT a:")" "NEXT a: coord merge a"
out="$("$COORD" merge a)"
has "$out" "READY z: for each, coord brief"   # merge prints what it made ready

# a redelivered event gets the hint for now, not for then; merge made z ready
"$COORD" msg a "late note" >/dev/null
wave 1
b="$(last_batch)"
assert "$(line "$b" "NEXT a:")" "NEXT a: nothing (merged)"
assert "$(line "$b" READY)" "READY z: for each, coord brief <id>, fill in the file it prints, then: coord dispatch <id> --role worker"

# under auto-merge a clean pass merges itself, and the merge wakes the coordinator
printf 'autonomy=auto-merge\n' >> "$REPO/.coordinator/config.conf"
"$COORD" dispatch z --role worker --brief "$TMP/brief" >/dev/null; wave 1
"$COORD" dispatch z --role critic >/dev/null
wait_for is_state z merged
wave 1
has "$(last_batch)" "z merged sha="
assert "$(line "$(last_batch)" "NEXT z:")" "NEXT z: nothing (merged)"

# a pass with notes asks the user, showing the notes
"$COORD" unit add n1 --kind chore --goal n1 >/dev/null
"$COORD" dispatch n1 --role worker --brief "$TMP/brief" >/dev/null; wave 1
FAKE_CRITIC=notepass "$COORD" dispatch n1 --role critic >/dev/null; wave 1
has "$(line "$(last_batch)" "NEXT n1:")" "ASK THE USER to approve n1 round 1, showing the critic's notes: check the migration"
"$COORD" drop n1 --reason x >/dev/null

# died -> same role again; twice -> blocked -> tell the user
FAKE_WORKER=exit "$COORD" dispatch p --role worker --brief "$TMP/brief" >/dev/null
"$COORD" relay --once --interval 0.3
assert "$(line "$(last_batch)" "NEXT p:")" "NEXT p: coord dispatch p --role worker"
FAKE_WORKER=exit "$COORD" dispatch p --role worker >/dev/null
"$COORD" relay --once --interval 0.3
has "$(line "$(last_batch)" "NEXT p:")" "NEXT p: tell the user why; once fixed: coord reopen p --reason"

# unit-less events: research and msg
printf 'GOAL: pick one\n' > "$TMP/rbrief"
"$COORD" research --brief "$TMP/rbrief" >/dev/null
"$COORD" msg - "hello" >/dev/null
wave 2
b="$(last_batch)"
has "$b" "NEXT $(printf '%s\n' "$b" | awk '$1=="EVENT" && $4=="finished" {print $2}'): read the report"
has "$b" "NEXT $(printf '%s\n' "$b" | awk '$1=="EVENT" && $4=="msg" {print $2}'): act on the message"
hasnt "$b" "DONE"

# every unit merged or dropped -> DONE
has "$("$COORD" drop p --reason "no longer needed")" "DONE: every unit is merged or dropped"

echo "  hints ok"
