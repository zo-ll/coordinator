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

out="$(frame 80)"
has "$out" "coordinator  ✗ stuck: the wake process is down"     # no relay in tests
has "$out" "NOTHING WILL MOVE"
hasnt "$out" "PENDING"
has "$out" "needs you    ▲ pass1 · ■ dead1 · ? G1 · ≡ research.1"
has "$out" "─ WORK "
has "$out" "▸▲ pass1  passed · needs your approval"                  # approve-merge in tests
has "$out" 'critic: looks right'
has "$out" "coord/pass1 · 1 file +1 −0 · file.txt · .coordinator/worktrees/pass1"
has "$out" " ■ dead1  blocked: agent died twice"
has "$out" " ◐ busy1  being built · round 1"
has "$out" "worker r1 · 0/60m · output"
has "$out" "└ ran pytest: 3 failed"
has "$out" "? decision G1  which retry library?"
has "$out" "≡ research.1  report ready: recommend B"
has "$out" "up next  ○ next1, waiting on busy1"
has "$out" "done     ✓ done1"
has "$out" "critic passed pass1 · round 1 · tests"
has "$out" "a approve  r reject  j/k move"                            # keys follow the ▸ item
# every line fits the width
[ "$(frame 44 | awk '{ print length($0) }' | sort -n | tail -1)" -le 44 ] || { echo "  wider than 44"; exit 1; }

# mouse: SGR reports hit-tested against the frame (rows as printed, the key
# bar on the last row: --height 70)
click() { printf '\e[<%s;%s;%sM' "${3:-0}" "$1" "$2"; }    # click <col> <row> [button]
row_of() { frame 80 | grep -nF -- "$1" | head -n1 | cut -d: -f1; }
col_of() { local pre=${1%%"$2"*}; echo $(( ${#pre} + 1 )); } # col_of <line> <text>
out="$(frame 80)"; bar=$(tail -n1 <<< "$out"); need=$(grep -F 'needs you' <<< "$out")
r=$(row_of "busy1  being built")
has "$(frame 80 --press "$(click 3 "$r")")" "▸◐ busy1"                      # click selects
has "$(frame 80 --press "$(click 3 "$((r + 1))")")" "▸◐ busy1"              # any of its rows
hasnt "$(frame 80 --press "$(click 3 "$r" 0 | tr M m)")" "▸◐ busy1"         # a release does nothing
hasnt "$(frame 80 --press "$(click 3 "$r" 2)")" "▸◐ busy1"                  # nor another button
has "$(frame 80 --press "$(click "$(col_of "$need" dead1)" "$(row_of 'needs you')")")" "o reopen  x drop"
has "$(PAGER='head -n1' frame 80 --press "$(click 3 "$r")$(click 3 "$r")")" "== busy1 · feature · working"  # again opens
has "$(PAGER='head -n1' frame 80 --press "$(click "$(col_of "$bar" '? keys')" 70)")" "coord watch keys"
has "$(frame 80 --press "$(click 3 "$r" 65)$(click 3 "$r" 65)")" "▸◐ busy1"  # wheel moves the selection
has "$(frame 80 --press "$(click 3 "$(row_of '─ RECENT')" 65)")" "↑ 1 newer" # and scrolls the feed
hasnt "$(frame 80 --press "$(click 3 "$(row_of '─ RECENT')" 65)$(click 3 "$(row_of '─ RECENT')" 64)")" "newer"
# a terminal without SGR sends ESC [ M and three raw bytes: never keys
# (wheel-down's button byte is "a")
frame 80 --press $'\e[Ma!!' >/dev/null; assert "$(state_of pass1)" passed
# a narrow prompt keeps its ✓ send / ✗ cancel targets: cancel, then ↵ would drop
{ printf 'yes'; click 40 69; echo; } | "$COORD" watch --once --width 44 --height 70 \
  --press "$(click "$(col_of "$need" dead1)" "$(row_of 'needs you')")x" >/dev/null
assert "$(state_of dead1)" blocked
# prompts: typed, with ✓ send / ✗ cancel on the reply row (row 69)
{ printf 'no'; click 75 69; echo; } | frame 80 --press m >/dev/null; hasnt "$("$COORD" log)" "msg - no"
{ printf 'drop\e'; } | frame 80 --press m >/dev/null; hasnt "$("$COORD" log)" "msg - drop"   # esc cancels
has "$( { printf 'hi therex\177'; click 65 69; } | frame 80 --press m)" "ok: sent"
has "$("$COORD" log)" "msg - hi there"
# a click never skips drop's typed confirmation
has "$( { click 65 69; } | frame 80 --press "$(click "$(col_of "$need" dead1)" "$(row_of 'needs you')")x")" "x drop"
assert "$(state_of dead1)" blocked

# keys: approve the selected passed unit -> approved and merged
has "$(frame 80 --press a)" "› ok: MERGED pass1"
assert "$(state_of pass1)" merged
# move to the decision (dead1, busy1, G1) and confirm the default
has "$(frame 80 --press jjc)" "ok: GATE G1 decided: hand-rolled"
# reading the report clears it from what needs you
PAGER=true frame 80 --press jjv >/dev/null
hasnt "$(frame 80)" "≡ research.1"
# reopen the blocked unit (selected first now)
has "$(frame 80 --press o)" "ok: REOPENED dead1"
# a refused action shows the engine's reason (no session: the relay can't start)
has "$(frame 80 --press w)" "✗ refused: no session for this run (coord init)"
# messages and prompts read their answer from the reply line
has "$(echo "use httpx" | frame 80 --press m)" "ok: sent; the coordinator wakes to read it"
has "$("$COORD" log)" "msg - use httpx"

# auto-merge: a clean pass isn't "needs you", a pass with notes is
printf 'autonomy=auto-merge\n' >> .coordinator/config.conf
"$COORD" unit add noted --kind chore --goal noted >/dev/null
"$COORD" dispatch noted --role worker --brief "$TMP/brief" >/dev/null; wait_for is_state noted built
FAKE_CRITIC=notepass "$COORD" dispatch noted --role critic >/dev/null; wait_for is_state noted passed
out="$(frame 80)"
has "$out" "▲ noted  passed with notes · needs you"
has "$out" "notes: check the migration"

echo "  watch ok"
