#!/usr/bin/env bash
# finish.sh: marker-before-ping, slug -> task/round, ping shape.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIN="$HERE/../scripts/finish.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export COORD_ROOT="$TMP/coord"
export COORD_EVENTS="$TMP/events.jsonl"
WT="$TMP/wt"
mkdir -p "$WT"

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }

out="$(cd "$WT" && "$FIN" --event s1.critic --role critic --result pass --head abc123 --summary 'looks good')"
assert "$out" "FINISH s1.critic task=s1 round=1"

marker="$(cat "$WT/.scratch/status/s1.critic.done")"
case "$marker" in
  *"TASK=s1"*"ROUND=1"*"ROLE=critic"*"HEAD=abc123"*"RESULT=pass"*) ;;
  *) echo "  bad marker: $marker"; exit 1 ;;
esac

"$HERE/../scripts/queue.sh" pop-batch "$TMP/batch" >/dev/null
assert "$(cat "$TMP/batch")" "EVENT s1.critic VERDICT s1: pass @ abc123 — looks good"
"$HERE/../scripts/queue.sh" nack

# round parsing on a worker event
(cd "$WT" && "$FIN" --event s1.r2 --role worker --result done --head - --summary 'fixed' >/dev/null)
grep -q 'ROUND=2' "$WT/.scratch/status/s1.r2.done" || { echo "  round parse failed"; exit 1; }

# de-dup: re-finishing the same event does not enqueue twice
(cd "$WT" && "$FIN" --event s1.r2 --role worker --result done --head - --summary 'fixed again' >/dev/null)
assert "$("$HERE/../scripts/queue.sh" list | wc -l)" "2"

# invalid slugs (whitespace/tabs) are rejected before any file is written
if (cd "$WT" && "$FIN" --event 'bad slug' --role worker --result done --head - --summary x >/dev/null 2>"$TMP/err"); then
  echo "  whitespace slug allowed"; exit 1
fi
grep -q 'invalid --event slug' "$TMP/err" || { echo "  unclear slug error:"; cat "$TMP/err"; exit 1; }
assert "$("$HERE/../scripts/queue.sh" list | wc -l)" "2"

# a finish that neither names nor finds a log refuses, and creates none
if (cd "$WT" && COORD_EVENTS= "$FIN" --event s9 --role worker --result done --summary x >/dev/null 2>"$TMP/err"); then
  echo "  finish without a log allowed"; exit 1
fi
grep -q 'no event log' "$TMP/err" || { echo "  unclear no-log error:"; cat "$TMP/err"; exit 1; }
[ ! -e "$WT/.coordinator" ] || { echo "  finish created a stray log"; exit 1; }

# a worker in <repo>/.coordinator/worktrees/<x> finds its repo's log
REPO="$TMP/repo"; mkdir -p "$REPO/.coordinator/worktrees/w1"
: > "$REPO/.coordinator/events.jsonl"
(cd "$REPO/.coordinator/worktrees/w1" && COORD_EVENTS= "$FIN" --event w1 --role worker --result done --summary x >/dev/null)
grep -q '"slug":"w1"' "$REPO/.coordinator/events.jsonl" || { echo "  worktree finish did not reach the repo log"; exit 1; }

echo "  finish ok"
