#!/usr/bin/env bash
# finish.sh: marker-before-ping, slug -> task/round, ping shape.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIN="$HERE/../scripts/finish.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export COORD_ROOT="$TMP/coord"
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

ping="$(cat "$COORD_ROOT/queue/"*.ping)"
assert "$ping" "VERDICT s1: pass @ abc123 — looks good"

# round parsing on a worker event
(cd "$WT" && "$FIN" --event s1.r2 --role worker --result done --head - --summary 'fixed' >/dev/null)
grep -q 'ROUND=2' "$WT/.scratch/status/s1.r2.done" || { echo "  round parse failed"; exit 1; }

# de-dup: re-finishing the same event does not enqueue twice
(cd "$WT" && "$FIN" --event s1.r2 --role worker --result done --head - --summary 'fixed again' >/dev/null)
assert "$("$HERE/../scripts/queue.sh" list | wc -l)" "2"

echo "  finish ok"
