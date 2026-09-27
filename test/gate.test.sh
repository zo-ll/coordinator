#!/usr/bin/env bash
# coord gate and coord standing: CLI-managed gates and standing orders; open
# gates show in status and at the end of every batch.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
fake_resume
cd "$REPO"

refuses "--default is required" "$COORD" gate add "which lib?"
assert "$("$COORD" gate add "which retry lib?" --default hand-rolled --options "backoff · hand-rolled")" "GATE G1 open default=hand-rolled"
assert "$("$COORD" gate add "edge case in scope?" --default no)" "GATE G2 open default=no"
assert "$("$COORD" gate list)" 'GATE G1 open "which retry lib?" default=hand-rolled options=backoff · hand-rolled
GATE G2 open "edge case in scope?" default=no'
has "$("$COORD" status)" 'GATE G2 open "edge case in scope?"'

"$COORD" msg - "ping" >/dev/null
"$COORD" relay --once --interval 0.1
has "$(cat "$(sed 's/.*WAKE batch=//' "$RELAY_LOG" | tail -n1)")" "GATES G1 G2 open: list them together in your next report"

assert "$("$COORD" gate decide G2 no)" "GATE G2 decided: no"
out="$("$COORD" gate decide G1 backoff)"
has "$out" "GATE G1 decided: backoff"
has "$out" "NEXT: the answer differs from the default (hand-rolled)"
assert "$("$COORD" gate list)" ""
refuses "no gate G9" "$COORD" gate decide G9 x

# standing orders: numbered, carried by launches
assert "$("$COORD" standing add "keep it small")" "STANDING 1: keep it small"
assert "$("$COORD" standing add "no new deps")" "STANDING 2: no new deps"
assert "$("$COORD" standing)" "1. keep it small
2. no new deps"
brief "$TMP/brief"
"$COORD" unit add s --kind chore --goal s >/dev/null
FAKE_WORKER=sleep "$COORD" dispatch s --role worker --brief "$TMP/brief" >/dev/null
grep -qx '2. no new deps' .coordinator/briefs/s.r1.worker.md || { echo "  launch lacks standing orders"; exit 1; }

echo "  gate ok"
