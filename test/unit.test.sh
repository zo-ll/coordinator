#!/usr/bin/env bash
# filo unit: kinds need a playbook, deps must exist, readiness follows deps,
# a repo playbook overrides the shipped one.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run

assert "$("$FILO" unit add a --kind feature --goal "first")" "ADDED a kind=feature"
"$FILO" unit add b --kind bugfix --goal "second" --deps a >/dev/null
"$FILO" unit add c --kind chore --goal "third" >/dev/null
assert "$("$FILO" unit next)" "a c"

refuses "REFUSED a unit_added: id already exists" "$FILO" unit add a --kind feature --goal again
refuses "REFUSED d unit_added: unknown dep \"ghost\"" "$FILO" unit add d --kind feature --goal x --deps ghost
refuses "REFUSED e unit_added: no playbook for kind \"poetry\"" "$FILO" unit add e --kind poetry --goal x
refuses "REFUSED x.1 unit_added: invalid id" "$FILO" unit add x.1 --kind chore --goal x
refuses "--kind and --goal are required" "$FILO" unit add f --goal x

# b becomes ready once a is terminal
"$FILO" drop a --reason "not needed" >/dev/null
assert "$("$FILO" unit next)" "b c"

# a repo playbook replaces the shipped one for its kind (and adds new kinds)
mkdir -p "$REPO/.filo/playbooks"
printf -- '---\nkind=poetry\nbrief.require=GOAL\ntimebox=5m\n---\n' > "$REPO/.filo/playbooks/poetry.md"
assert "$("$FILO" unit add p --kind poetry --goal verse)" "ADDED p kind=poetry"

echo "  unit ok"
