#!/usr/bin/env bash
# filo finish: owed slugs only, idempotent, evidence checked against the
# playbook (floor, --ran, required flags), state hash computed by the engine.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
export FAKE_WORKER=exit FAKE_CRITIC=exit
brief "$TMP/brief"
fin() { (cd "$REPO" && FILO_OWES="$1" "$FILO" finish "${@:2}"); }
critic_round() { # critic_round <id>: worker done, critic dispatched
  "$FILO" dispatch "$1" --role worker --brief "$TMP/brief" >/dev/null
  echo "work on $1" >> "$REPO/.filo/worktrees/$1/file.txt"
  fin "$1.r1.worker" --result done --summary ok >/dev/null
  "$FILO" dispatch "$1" --role critic >/dev/null
}

"$FILO" unit add f1 --kind feature --goal one >/dev/null
"$FILO" dispatch f1 --role worker --brief "$TMP/brief" >/dev/null

refuses "REFUSED - finished: slug \"f1.r1.critic\" is not owed" fin f1.r1.critic --result pass --summary x
refuses "worker result \"pass\"" fin f1.r1.worker --result pass --summary x
assert "$(fin f1.r1.worker --result done --summary ok)" "FINISHED f1.r1.worker -> built"
assert "$(fin f1.r1.worker --result done --summary again)" "DUP f1.r1.worker"

# a critic pass at the floor passes and records the engine's state hash
"$FILO" dispatch f1 --role critic >/dev/null
assert "$(fin f1.r1.critic --result pass --evidence tests --ran 'go test ./...' --summary good)" "FINISHED f1.r1.critic -> passed"
hash="$(grep $'\ttype=finished\t' "$FILO_EVENTS" | grep $'\tslug=f1.r1.critic\t' | sed -E 's/.*\tstate=([0-9a-f]+)\t.*/\1/')"
[ "${#hash}" = 64 ] || { echo "  no state hash recorded: $hash"; exit 1; }

# below the floor, no --ran, a missing required flag: each converts to handback
"$FILO" unit add f2 --kind feature --goal two >/dev/null; critic_round f2
assert "$(fin f2.r1.critic --result pass --evidence typecheck --ran true --summary meh)" \
  "FINISHED f2.r1.critic -> handback (converted: evidence typecheck is below the feature floor tests)"
"$FILO" unit add f3 --kind feature --goal three >/dev/null; critic_round f3
assert "$(fin f3.r1.critic --result pass --evidence tests --summary trust-me)" \
  "FINISHED f3.r1.critic -> handback (converted: no --ran command recorded)"
"$FILO" unit add b1 --kind bugfix --goal four >/dev/null; critic_round b1
assert "$(fin b1.r1.critic --result pass --evidence live --ran 'make test' --summary ok)" \
  "FINISHED b1.r1.critic -> handback (converted: missing --flag red-green)"
"$FILO" unit add b2 --kind bugfix --goal five >/dev/null; critic_round b2
assert "$(fin b2.r1.critic --result pass --evidence tests --ran 'make test' --flag red-green --summary ok)" \
  "FINISHED b2.r1.critic -> passed"
# a chore's floor is none: a bare pass is enough
"$FILO" unit add c1 --kind chore --goal six >/dev/null; critic_round c1
assert "$(fin c1.r1.critic --result pass --summary fine)" "FINISHED c1.r1.critic -> passed"
# the conversion wakes the coordinator with its reason
has "$("$FILO" log f2)" "converted f2 pass -> handback: evidence typecheck is below"

# an unknown level is an input error, not a verdict
"$FILO" unit add f4 --kind feature --goal seven >/dev/null; critic_round f4
refuses "--evidence \"vibes\" is not one of none,typecheck,tests,live" fin f4.r1.critic --result pass --evidence vibes --summary x

# a worker's partial is a handback
"$FILO" unit add f5 --kind feature --goal eight >/dev/null
"$FILO" dispatch f5 --role worker --brief "$TMP/brief" >/dev/null
assert "$(fin f5.r1.worker --result partial --summary 'ran out of time')" "FINISHED f5.r1.worker -> handback"

# a finish that neither names nor finds a log refuses, and creates none
mkdir -p "$TMP/elsewhere"
if (cd "$TMP/elsewhere" && FILO_EVENTS= FILO_OWES=x.r1.worker "$FILO" finish --result done --summary x >/dev/null 2>"$TMP/err"); then
  echo "  finish without a log allowed"; exit 1
fi
grep -q 'no event log' "$TMP/err" || { echo "  unclear no-log error:"; cat "$TMP/err"; exit 1; }
[ ! -e "$TMP/elsewhere/.filo" ] || { echo "  finish created a stray log"; exit 1; }
# ...while a worker in its worktree finds the repo's log by itself
"$FILO" unit add w1 --kind feature --goal nine >/dev/null
"$FILO" dispatch w1 --role worker --brief "$TMP/brief" >/dev/null
out="$(cd "$REPO/.filo/worktrees/w1" && FILO_EVENTS= FILO_OWES=w1.r1.worker "$FILO" finish --result done --summary x)"
assert "$out" "FINISHED w1.r1.worker -> built"

echo "  finish ok"
