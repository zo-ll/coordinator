#!/usr/bin/env bash
# Playbooks: a malformed repo playbook is refused with the reason; the
# shipped ones load; a repo override wins for its kind.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
mkdir -p "$REPO/.filo/playbooks"
pb() { printf '%b' "$2" > "$REPO/.filo/playbooks/$1.md"; }

for k in feature bugfix refactor chore; do
  has "$("$FILO" unit add "ok-$k" --kind "$k" --goal x)" "ADDED ok-$k kind=$k"
done

pb nohead 'kind=nohead\n'
refuses "missing --- header" "$FILO" unit add a1 --kind nohead --goal x
pb badfloor '---\nkind=badfloor\nevidence.floor=vibes\n---\n'
refuses 'evidence.floor "vibes" is not one of none,typecheck,tests,live' "$FILO" unit add a2 --kind badfloor --goal x
pb badtime '---\nkind=badtime\ntimebox=soon\n---\n'
refuses 'timebox "soon" is not a duration' "$FILO" unit add a3 --kind badtime --goal x
pb badkey '---\nkind=badkey\ncolor=red\n---\n'
refuses 'unknown header key "color"' "$FILO" unit add a4 --kind badkey --goal x
pb notkv '---\nkind=notkv\njust words\n---\n'
refuses 'is not key=value' "$FILO" unit add a5 --kind notkv --goal x
pb open '---\nkind=open\n'
refuses 'unterminated --- header' "$FILO" unit add a6 --kind open --goal x
pb wrong '---\nkind=other\n---\n'
refuses 'kind="other", want "wrong"' "$FILO" unit add a7 --kind wrong --goal x
refuses 'invalid kind "../x"' "$FILO" unit add a8 --kind ../x --goal x

# an override replaces the shipped playbook: a chore that now needs ACCEPTANCE
pb chore '---\nkind=chore\nbrief.require=GOAL,ACCEPTANCE\ntimebox=5m\n---\n## worker\nOverride says hi.\n'
"$FILO" unit add c1 --kind chore --goal x >/dev/null
printf 'GOAL: g\n' > "$TMP/b"
refuses "missing ACCEPTANCE (a chore brief needs: GOAL ACCEPTANCE)" "$FILO" dispatch c1 --role worker --brief "$TMP/b"

echo "  playbook ok"
