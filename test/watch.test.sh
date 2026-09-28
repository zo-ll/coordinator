#!/usr/bin/env bash
# filo watch: the frame for a live run (waiting items, agents, units, feed),
# and the keys that act on the selected item.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"
cd "$REPO"
frame() { "$FILO" watch --once --width "${1:-60}" --height 70 "${@:2}"; }

# no run yet
rm -f "$FILO_EVENTS"
has "$(frame)" "No run here yet"

# a run with something in every region
"$FILO" unit add done1 --kind chore --goal "already shipped" >/dev/null
"$FILO" unit add pass1 --kind feature --goal "passes review" >/dev/null
"$FILO" unit add dead1 --kind feature --goal "keeps dying" >/dev/null
"$FILO" unit add busy1 --kind feature --goal "still working" >/dev/null
"$FILO" unit add next1 --kind chore --goal "after busy1" --deps busy1 >/dev/null
pass() { # pass <unit>: worker, then critic
  "$FILO" dispatch "$1" --role worker --brief "$TMP/brief" >/dev/null; wait_for is_state "$1" built
  "$FILO" dispatch "$1" --role critic >/dev/null; wait_for is_state "$1" passed
}
pass done1; "$FILO" approve done1 >/dev/null; "$FILO" merge done1 >/dev/null
pass pass1   # branched after done1 merged, so it merges cleanly
FAKE_WORKER=exit "$FILO" dispatch dead1 --role worker --brief "$TMP/brief" >/dev/null
"$FILO" block dead1 --reason "agent died twice" >/dev/null
FAKE_WORKER=sleep "$FILO" dispatch busy1 --role worker --brief "$TMP/brief" >/dev/null
echo "ran pytest: 3 failed" >> .filo/log/busy1.r1.worker.log
"$FILO" gate add "which retry library?" --default hand-rolled >/dev/null
printf 'GOAL: pick a queue\n' > "$TMP/rb"; "$FILO" research --brief "$TMP/rb" >/dev/null
wait_for grep -q 'role=researcher.*result=done\|result=done.*research' "$FILO_EVENTS"

out="$(frame 80)"
has "$out" "coordinator  ✗ stuck: the wake process is down"     # no relay in tests
has "$out" "NOTHING WILL MOVE"
hasnt "$out" "PENDING"
has "$out" "needs you    ▲ pass1 · ■ dead1 · ? G1 · ≡ research.1"
has "$out" "─ WORK "
has "$out" "▸▲ pass1  passed · needs your approval"                  # approve-merge in tests
has "$out" 'critic: looks right'
has "$out" "filo/pass1 · 1 file +1 −0 · file.txt · .filo/worktrees/pass1"
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
has "$(frame 80 --press "$(click 3 "$r")$(click 3 "$r")")" "esc ‹  busy1  feature · round 1"  # again opens
has "$(PAGER='head -n1' frame 80 --press "$(click "$(col_of "$bar" '? keys')" 70)")" "filo watch keys"
has "$(frame 80 --press "$(click 3 "$r" 65)$(click 3 "$r" 65)")" "▸◐ busy1"  # wheel moves the selection
has "$(frame 80 --press "$(click 3 "$(row_of '─ RECENT')" 65)")" "↑ 1 newer" # and scrolls the feed
hasnt "$(frame 80 --press "$(click 3 "$(row_of '─ RECENT')" 65)$(click 3 "$(row_of '─ RECENT')" 64)")" "newer"
# a terminal without SGR sends ESC [ M and three raw bytes: never keys
# (wheel-down's button byte is "a")
frame 80 --press $'\e[Ma!!' >/dev/null; assert "$(state_of pass1)" passed
frame 80 --press $'\e[Ma\xe2\x30\e[Ma\xe2\x30' >/dev/null; assert "$(state_of pass1)" passed  # column 194: bytes, not UTF-8
# a narrow prompt keeps its ✓ send / ✗ cancel targets: cancel, then ↵ would drop
{ printf 'yes'; click 40 69; echo; } | "$FILO" watch --once --width 44 --height 70 \
  --press "$(click "$(col_of "$need" dead1)" "$(row_of 'needs you')")x" >/dev/null
assert "$(state_of dead1)" blocked
# prompts: typed, with ✓ send / ✗ cancel on the reply row (row 69)
{ printf 'no'; click 75 69; echo; } | frame 80 --press m >/dev/null; hasnt "$("$FILO" log)" "msg - no"
{ printf 'drop\e'; } | frame 80 --press m >/dev/null; hasnt "$("$FILO" log)" "msg - drop"   # esc cancels
has "$( { printf 'hi therex\177'; click 65 69; } | frame 80 --press m)" "ok: sent"
has "$("$FILO" log)" "msg - hi there"
# a click never skips drop's typed confirmation
has "$( { click 65 69; } | frame 80 --press "$(click "$(col_of "$need" dead1)" "$(row_of 'needs you')")x")" "x drop"
assert "$(state_of dead1)" blocked

# the unit view (the design's 3a-3f): ↵ opens the selected unit on its brief
out="$(frame 80 --press $'\n')"
has "$out" "esc ‹  pass1  feature · round 1"
has "$out" "▲ passed · needs your approval"
has "$out" "           passes review"                                           # its goal
has "$out" "  1 brief  2 findings  3 diff  4 log  5 output  6 history"
has "$out" "1-6 tab  j/k scroll  esc back  a approve  r reject  p pager"
out="$("$FILO" watch --once --width 60 --height 40 --open pass1 --tab diff)"   # the design's own width
has "$out" "▲ needs approval"; has "$out" " j/k scroll  esc back  a approve  r reject  n/N file"   # the bar sheds 1-6, never the tab's keys
view() { "$FILO" watch --once --width 80 --height "${H:-70}" --open "$@"; }
# 3a brief: a headed section per field, deps, what it blocks, who wrote it
out="$(view pass1)"
has "$out" $' Goal\n   file.txt gains a line'
has "$out" $' Done when\n   · file.txt has more than one line'
has "$out" $' Checks\n   test "$(wc -l < file.txt)" -gt 1'
has "$out" " Depends on  none"; has "$out" " Blocks      none"
has "$(view busy1)" " Blocks      next1"; has "$(view next1)" " Depends on  busy1"
has "$out" "Written by the coordinator at"
# 3b findings: newest round first, its summary, checks and notes
out="$(view pass1 --tab findings)"
has "$out" " Round 1  passed · evidence ●●○ tests · "
has "$out" '   "looks right"'; has "$out" $' Checks\n   $ test -f file.txt\n   – live check  not run'
# 3c diff: the summary, then a rule per file, no git headers
out="$(view pass1 --tab diff)"
has "$out" " 1 file  +1 −0"; has "$out" "branch filo/pass1 (round 1)"
has "$out" " ── file.txt ──"; has "$out" " +change by pass1.r1.worker"; hasnt "$out" "diff --git"; hasnt "$out" "index "
has "$(view pass1 --tab log)" "the merge's checks haven't run"
# 3e output: the newest round, under its role, round and end
out="$(view pass1 --tab output)"; has "$out" " critic · round 1  0m of 60m · finished at "; has "$out" "[ an earlier round"
has "$(view pass1 --tab output --press '[')" " worker · round 1"               # [ ] switch rounds
# 3f history: the feed's sentences, oldest first
out="$(view pass1 --tab history)"
has "$out" "coordinator added pass1 · feature"; has "$out" "critic passed pass1 · round 1 · tests"
[ "$(grep -n 'coordinator added pass1' <<< "$out" | cut -d: -f1)" -lt "$(grep -n 'critic passed pass1' <<< "$out" | cut -d: -f1)" ] || { echo "  history not oldest first"; exit 1; }
has "$(view pass1 --press 3)" " ── file.txt ──"                           # 1-6 pick a tab
has "$(view pass1 --press $'\e[C')" " Round 1  passed"                      # → next
has "$(view pass1 --press $'\e[D')" "coordinator added pass1"               # ← previous, wrapping
has "$(view pass1 --press $'\e')" "─ WORK "                                  # esc: back to the main screen
has "$(view pass1 --press "$(click 3 1)")" "─ WORK "                          # so does a click on "esc ‹"
has "$(PAGER='head -n1' view pass1 --press p)" "Please do the thing."          # p: the tab in $PAGER
# a running agent's output follows its tail until you scroll up
for i in $(seq -w 1 50); do echo "line $i"; done >> .filo/log/busy1.r1.worker.log
has "$(H=14 view busy1 --tab output)" "line 50"
hasnt "$(H=14 view busy1 --tab output --press k)" "line 50"
has "$(H=14 view busy1 --tab output --press k)" "of 53"
# the newest output stays the newest: a new round's log takes over, still followed
echo "critic here" > .filo/log/busy1.r1.critic.log
has "$(H=14 view busy1 --tab output)" "critic · round 1"
has "$(H=14 view busy1 --tab output --press '[')" "line 01"                  # an older round starts at its top
has "$(H=14 view busy1 --tab output --press '[]')" "critic here"             # ] past the end: the newest again
rm .filo/log/busy1.r1.critic.log
# new files join the diff whatever their names, and nothing reaches stderr
printf 'a\nb\n' > .filo/worktrees/pass1/café.txt
out="$(view pass1 --tab diff 2>"$TMP/err")"
has "$out" "café.txt (new)"; has "$out" " ── café.txt ──"; has "$out" " +b"; assert "$(cat "$TMP/err")" ""
assert "$(git -c core.quotePath=false -C .filo/worktrees/pass1 status --short café.txt)" "?? café.txt"   # the real index untouched
rm .filo/worktrees/pass1/café.txt
assert "$(ls .filo/watch.* 2>/dev/null || true)" ""                   # its scratch files leave with it
# narrow: the tab bar keeps all six; a bad --tab is refused
has "$("$FILO" watch --once --width 44 --height 30 --open pass1)" "6 hist"
refuses "--tab is one of 1-6" "$FILO" watch --once --open pass1 --tab nope
refuses 'no unit "nope"' "$FILO" watch --once --open nope
# mouse: a tab name switches, the wheel scrolls, a unit in done opens its view
bar=$(sed -n 4p <<< "$(view pass1)")
has "$(view pass1 --press "$(click "$(col_of "$bar" diff)" 4)")" " ── file.txt ──"
hasnt "$(H=14 view busy1 --tab output --press "$(click 3 8 64)")" "line 50"
done_line=$(frame 80 | grep -F 'done     ')
out="$(frame 80 --press "$(click "$(col_of "$done_line" done1)" "$(row_of 'done     ')")")"
has "$out" "esc ‹  done1  chore · round 1"
out="$(view done1 --tab diff)"; has "$out" "+change by done1.r1.worker"; has "$out" "merge commit"   # a merged unit: its merge commit

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
has "$(frame 80 --press w)" "✗ refused: no session for this run (filo init)"
# messages and prompts read their answer from the reply line
has "$(echo "use httpx" | frame 80 --press m)" "ok: sent; the coordinator wakes to read it"
has "$("$FILO" log)" "msg - use httpx"

# auto-merge: a clean pass isn't "needs you", a pass with notes is
printf 'autonomy=auto-merge\n' >> .filo/config.conf
"$FILO" unit add noted --kind chore --goal noted >/dev/null
"$FILO" dispatch noted --role worker --brief "$TMP/brief" >/dev/null; wait_for is_state noted built
FAKE_CRITIC=notepass "$FILO" dispatch noted --role critic >/dev/null; wait_for is_state noted passed
out="$(frame 80)"
has "$out" "▲ noted  passed with notes · needs you"
has "$out" "notes: check the migration"

# the merge's checks failed: the view opens on their log
sed 's/-gt 1/-gt 99/' "$TMP/brief" > "$TMP/strict"
"$FILO" unit add strict --kind chore --goal strict >/dev/null
"$FILO" dispatch strict --role worker --brief "$TMP/strict" >/dev/null; wait_for is_state strict built
FAKE_CRITIC=notepass "$FILO" dispatch strict --role critic >/dev/null; wait_for is_state strict passed
"$FILO" approve strict >/dev/null; "$FILO" merge strict >/dev/null 2>&1 || true
assert "$(state_of strict)" handback
out="$(view strict)"
has "$out" " Merge of round 1  "; has "$out" "✗ failed · exit 1"; has "$out" '$ test "$(wc -l < file.txt)" -gt 99'
has "$out" "exit 1 · sent back to the worker at"
has "$(view strict --tab findings)" "✗ the merge re-ran the checks: exit 1 (see 4 log)"
touch -d '+5 seconds' .filo/log/strict.verify.log                     # a new merge rewrote the log
has "$(view strict --tab log)" " Merge  running"

# DEL and C1 controls in event text never reach the terminal
"$FILO" msg strict $'odd\x7f\xc2\x9b31m text' >/dev/null
out="$(frame 80)"; has "$out" "odd31m text"; hasnt "$out" $'\xc2\x9b'
has "$(view strict --tab history)" "odd"; hasnt "$(view strict --tab history)" $'\x7f'

# an agent restarted after a death: its output tab says running, not the old death
fake_resume; echo sess-1 > .filo/session
"$FILO" unit add again --kind chore --goal again >/dev/null
FAKE_WORKER=exit "$FILO" dispatch again --role worker --brief "$TMP/brief" >/dev/null
"$FILO" relay --once --interval 0.1 >/dev/null; wait_for is_state again stalled
FAKE_WORKER=sleep "$FILO" dispatch again --role worker >/dev/null
out="$(view again --tab output)"; has "$out" " worker · round 1  0m of 20m · running"; hasnt "$out" "died"

echo "  watch ok"
