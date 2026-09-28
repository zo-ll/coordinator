#!/usr/bin/env bash
# filo brief: a draft with the playbook's fields; dispatch picks it up,
# refuses it while placeholders remain, and spends it; a later round's draft
# carries the last brief plus CORRECTION.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
export FAKE_WORKER=partial

"$FILO" unit add b1 --kind bugfix --goal "fix it" >/dev/null
out="$("$FILO" brief b1)"
p="$REPO/.filo/briefs/b1.draft.md"
assert "$out" "BRIEF b1 $p needs=GOAL,SCOPE,REPRO,ACCEPTANCE,VERIFY"
assert "$(grep -oE '^[A-Z]+:' "$p" | paste -sd' ' -)" "GOAL: SCOPE: CONTEXT: REPRO: ACCEPTANCE: VERIFY:"
refuses "still has <fill: ...> placeholders" "$FILO" dispatch b1 --role worker

# a second call keeps the draft in progress
echo "note" >> "$p"
"$FILO" brief b1 >/dev/null
grep -qx note "$p" || { echo "  draft overwritten"; exit 1; }

brief "$p"   # filled in
has "$("$FILO" dispatch b1 --role worker)" "DISPATCHED b1 role=worker round=1"
[ ! -e "$p" ] || { echo "  used draft not spent"; exit 1; }
wait_for is_state b1 handback

# correction round: the last brief, plus CORRECTION to fill
"$FILO" brief b1 >/dev/null
assert "$(head -n1 "$p")" "CORRECTION: <fill: what failed, from the reason in the batch, and what to do now>"
grep -q '^GOAL: file.txt gains a line' "$p" || { echo "  last brief not carried"; exit 1; }
sed -i '1s/.*/CORRECTION: finish the other half/' "$p"
has "$("$FILO" dispatch b1 --role worker)" "round=2"
grep -q 'CORRECTION: finish the other half' "$REPO/.filo/briefs/b1.r2.worker.md" || { echo "  worker prompt lacks CORRECTION"; exit 1; }

refuses "unknown unit" "$FILO" brief nope
# a field written twice is one field with both lines, for the critic too
"$FILO" unit add r2 --kind chore --goal r2 >/dev/null
brief "$TMP/twice"; echo "ACCEPTANCE: second criterion" >> "$TMP/twice"
FAKE_WORKER=done "$FILO" dispatch r2 --role worker --brief "$TMP/twice" >/dev/null
wait_for is_state r2 built
FAKE_CRITIC=sleep "$FILO" dispatch r2 --role critic >/dev/null
c="$REPO/.filo/briefs/r2.r1.critic.md"
grep -q "file.txt has more than one line" "$c" && grep -q "second criterion" "$c" || { echo "  critic lost a repeated field:"; cat "$c"; exit 1; }

echo "  brief ok"
