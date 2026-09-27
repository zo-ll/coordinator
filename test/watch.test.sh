#!/usr/bin/env bash
# coord watch: the frame for a live run (waiting items, agents, units, feed),
# and the keys that act on the selected item.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"
cd "$REPO"
frame() { "$COORD" watch --once --width "${1:-60}" --height 70 "${@:2}"; }

# no run yet
rm -f "$COORD_EVENTS"
has "$(frame)" "No run here yet"

# a run with something in every region
"$COORD" unit add done1 --kind chore --goal "already shipped" >/dev/null
"$COORD" unit add pass1 --kind feature --goal "passes review" >/dev/null
"$COORD" unit add dead1 --kind feature --goal "keeps dying" >/dev/null
"$COORD" unit add busy1 --kind feature --goal "still working" >/dev/null
"$COORD" unit add next1 --kind chore --goal "after busy1" --deps busy1 >/dev/null
pass() { # pass <unit>: worker, then critic
  "$COORD" dispatch "$1" --role worker --brief "$TMP/brief" >/dev/null; wait_for is_state "$1" built
  "$COORD" dispatch "$1" --role critic >/dev/null; wait_for is_state "$1" passed
}
pass done1; "$COORD" approve done1 >/dev/null; "$COORD" merge done1 >/dev/null
pass pass1   # branched after done1 merged, so it merges cleanly
FAKE_WORKER=exit "$COORD" dispatch dead1 --role worker --brief "$TMP/brief" >/dev/null
"$COORD" block dead1 --reason "agent died twice" >/dev/null
FAKE_WORKER=sleep "$COORD" dispatch busy1 --role worker --brief "$TMP/brief" >/dev/null
echo "ran pytest: 3 failed" >> .coordinator/log/busy1.r1.worker.log
"$COORD" gate add "which retry library?" --default hand-rolled >/dev/null
printf 'GOAL: pick a queue\n' > "$TMP/rb"; "$COORD" research --brief "$TMP/rb" >/dev/null
wait_for grep -q 'role=researcher.*result=done\|result=done.*research' "$COORD_EVENTS"

out="$(frame 60)"
has "$out" "coordinator  ✗ stuck: the wake process is down"     # no relay in tests
has "$out" "NOTHING WILL MOVE"
has "$out" "PENDING ━"
has "$out" "▸ ■ dead1  blocked: agent died twice"
has "$out" "▲ pass1  passed review · round 1 · ●●○ tests"
has "$out" '"looks right"'
has "$out" "? decision  which retry library?"
has "$out" "≡ report  recommend B"
has "$out" "o reopen  x drop  ↵ details"                         # keys only on the ▸ item
has "$out" "◐ busy1  worker · round 1"
has "$out" "└ ran pytest: 3 failed"
has "$out" "◐ busy1         feature   being built · round 1"
has "$out" "up next  ○ next1, waiting on busy1"
has "$out" "done     ✓ done1"
has "$out" "critic passed pass1 · round 1 · tests"
has "$out" "merged done1"
# every line fits the width
[ "$(frame 44 | awk '{ print length($0) }' | sort -n | tail -1)" -le 44 ] || { echo "  wider than 44"; exit 1; }
hasnt "$(frame 44)" "feature   being built"                        # the kind column goes first

# keys: tab to the passed unit, approve -> approved and merged
out="$(frame 60 --press $'\ta')"
has "$out" "› ok: MERGED pass1"
assert "$(state_of pass1)" merged
# the gate is now selected (dead1 then the gate): confirm the default
out="$(frame 60 --press $'\tc')"
has "$out" "ok: GATE G1 decided: hand-rolled"
# reading the report clears it from the waiting box
out="$(PAGER=true frame 60 --press $'\tv')"
hasnt "$(frame 60)" "≡ report"
# reopen the blocked unit
has "$(frame 60 --press o)" "ok: REOPENED dead1"
# a refused action shows the engine's reason (no session: the relay can't start)
has "$(frame 60 --press w)" "✗ refused: no session for this run (coord init)"
# messages and prompts read their answer from the reply line
has "$(echo "use httpx" | frame 60 --press m)" "ok: sent; the coordinator wakes to read it"
has "$("$COORD" log)" "msg - use httpx"

echo "  watch ok"
