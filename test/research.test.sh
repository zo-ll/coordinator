#!/usr/bin/env bash
# filo research: a unit-less launch that writes a decision brief and wakes
# the coordinator; a researcher that dies is reported like any launch.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
fake_resume

printf 'no goal here\n' > "$TMP/q0"
refuses "missing GOAL" "$FILO" research --brief "$TMP/q0"

printf 'GOAL: which queue library should we use?\nCONTEXT: we run on Linux only\n' > "$TMP/q1"
out="$("$FILO" research --brief "$TMP/q1")"
has "$out" "RESEARCH research.1 pid="
report="$REPO/.filo/research/1.md"
has "$out" "report=$report"
wait_for bash -c "\"\$FILO\" log | grep -q 'finished - research.1 done report='"
assert "$(cat "$report")" "# decision: option B"
has "$(cat "$FAKE_DIR/prompt.research.1")" "we run on Linux only"

# a second researcher that exits without finishing is reported as died
export FAKE_RESEARCH=exit
has "$("$FILO" research --brief "$TMP/q1")" "RESEARCH research.2"
"$FILO" relay --once --interval 0.1
b="$(cat "$(sed 's/.*WAKE batch=//' "$RELAY_LOG" | tail -n1)")"
has "$b" "- finished research.1 done report=$report — recommend B"
has "$b" "- died research.2 pid="

echo "  research ok"
