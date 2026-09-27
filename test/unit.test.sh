#!/usr/bin/env bash
# coord unit: kinds need a playbook, deps must exist, readiness follows deps,
# a repo playbook overrides the shipped one.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run

assert "$("$COORD" unit add a --kind feature --goal "first")" "ADDED a kind=feature"
"$COORD" unit add b --kind bugfix --goal "second" --deps a >/dev/null
"$COORD" unit add c --kind chore --goal "third" >/dev/null
assert "$("$COORD" unit next)" "a c"

refuses "REFUSED a unit_added: id already exists" "$COORD" unit add a --kind feature --goal again
refuses "REFUSED d unit_added: unknown dep \"ghost\"" "$COORD" unit add d --kind feature --goal x --deps ghost
refuses "REFUSED e unit_added: no playbook for kind \"poetry\"" "$COORD" unit add e --kind poetry --goal x
refuses "REFUSED x.1 unit_added: invalid id" "$COORD" unit add x.1 --kind chore --goal x
refuses "--kind and --goal are required" "$COORD" unit add f --goal x

# b becomes ready once a is terminal
"$COORD" drop a --reason "not needed" >/dev/null
assert "$("$COORD" unit next)" "b c"

# a repo playbook replaces the shipped one for its kind (and adds new kinds)
mkdir -p "$REPO/.coordinator/playbooks"
printf -- '---\nkind=poetry\nbrief.require=GOAL\ntimebox=5m\n---\n' > "$REPO/.coordinator/playbooks/poetry.md"
assert "$("$COORD" unit add p --kind poetry --goal verse)" "ADDED p kind=poetry"

echo "  unit ok"
