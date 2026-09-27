#!/usr/bin/env bash
# coord brief: a draft with the playbook's fields; dispatch picks it up,
# refuses it while placeholders remain, and spends it; a later round's draft
# carries the last brief plus CORRECTION.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
export FAKE_WORKER=partial

"$COORD" unit add b1 --kind bugfix --goal "fix it" >/dev/null
out="$("$COORD" brief b1)"
p="$REPO/.coordinator/briefs/b1.draft.md"
assert "$out" "BRIEF b1 $p needs=GOAL,SCOPE,REPRO,ACCEPTANCE,VERIFY"
assert "$(grep -oE '^[A-Z]+:' "$p" | paste -sd' ' -)" "GOAL: SCOPE: CONTEXT: REPRO: ACCEPTANCE: VERIFY:"
refuses "still has <fill: ...> placeholders" "$COORD" dispatch b1 --role worker

# a second call keeps the draft in progress
echo "note" >> "$p"
"$COORD" brief b1 >/dev/null
grep -qx note "$p" || { echo "  draft overwritten"; exit 1; }

brief "$p"   # filled in
has "$("$COORD" dispatch b1 --role worker)" "DISPATCHED b1 role=worker round=1"
[ ! -e "$p" ] || { echo "  used draft not spent"; exit 1; }
wait_for is_state b1 handback

# correction round: the last brief, plus CORRECTION to fill
"$COORD" brief b1 >/dev/null
assert "$(head -n1 "$p")" "CORRECTION: <fill: what failed, from the reason in the batch, and what to do now>"
grep -q '^GOAL: file.txt gains a line' "$p" || { echo "  last brief not carried"; exit 1; }
sed -i '1s/.*/CORRECTION: finish the other half/' "$p"
has "$("$COORD" dispatch b1 --role worker)" "round=2"
grep -q 'CORRECTION: finish the other half' "$REPO/.coordinator/briefs/b1.r2.worker.md" || { echo "  worker prompt lacks CORRECTION"; exit 1; }

refuses "unknown unit" "$COORD" brief nope
echo "  brief ok"
