#!/usr/bin/env bash
# filo gate and filo standing: CLI-managed gates and standing orders; open
# gates show in status and at the end of every batch.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
fake_resume
cd "$REPO"

refuses "--default is required" "$FILO" gate add "which lib?"
assert "$("$FILO" gate add "which retry lib?" --default hand-rolled --options "backoff · hand-rolled")" "GATE G1 open default=hand-rolled"
assert "$("$FILO" gate add "edge case in scope?" --default no)" "GATE G2 open default=no"
assert "$("$FILO" gate list)" 'GATE G1 open "which retry lib?" default=hand-rolled options=backoff · hand-rolled
GATE G2 open "edge case in scope?" default=no'
has "$("$FILO" status)" 'GATE G2 open "edge case in scope?"'

"$FILO" msg - "ping" >/dev/null
"$FILO" relay --once --interval 0.1
has "$(cat "$(sed 's/.*WAKE batch=//' "$RELAY_LOG" | tail -n1)")" "GATES G1 G2 open: list them together in your next report"

assert "$("$FILO" gate decide G2 no)" "GATE G2 decided: no"
out="$("$FILO" gate decide G1 backoff)"
has "$out" "GATE G1 decided: backoff"
has "$out" "NEXT: the answer differs from the default (hand-rolled)"
assert "$("$FILO" gate list)" ""
refuses "no gate G9" "$FILO" gate decide G9 x

# standing orders: numbered, carried by launches
assert "$("$FILO" standing add "keep it small")" "STANDING 1: keep it small"
assert "$("$FILO" standing add "no new deps")" "STANDING 2: no new deps"
assert "$("$FILO" standing)" "1. keep it small
2. no new deps"
brief "$TMP/brief"
"$FILO" unit add s --kind chore --goal s >/dev/null
FAKE_WORKER=sleep "$FILO" dispatch s --role worker --brief "$TMP/brief" >/dev/null
grep -qx '2. no new deps' .filo/briefs/s.r1.worker.md || { echo "  launch lacks standing orders"; exit 1; }

echo "  gate ok"
