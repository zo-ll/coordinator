#!/usr/bin/env bash
# help: an index and one entry per verb, with no repo or config needed.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$TMP"

out="$("$COORD" help)"
has "$out" "role agents (worker, critic, researcher):"
has "$out" "finish ...               report the result; this wakes the coordinator"
assert "$("$COORD" --help)" "$out"

# every verb the dispatcher accepts has an entry
verbs=$(sed -n '/^case "\$verb" in$/,/^esac$/p' "$ROOT/bin/coord" | grep -oE '^  [a-z|]+\)' | tr -d ' )' | tr '|' '\n' | grep -vE '^(help)$' | sort -u)
for v in $verbs; do "$COORD" help "$v" >/dev/null || { echo "  no help for $v"; exit 1; }; done
has "$("$COORD" help finish)" "wakes the coordinator"
refuses 'no help for "nope"' "$COORD" help nope
refuses "coord help lists the verbs" "$COORD" nope

echo "  help ok"
