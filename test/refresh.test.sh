#!/usr/bin/env bash
# A worker round after the base moved on: the worktree moves onto the new
# base with the worker's change re-applied, conflicts left as markers and
# named in the prompt; build artifacts never reach a change; untracked files
# in the base checkout refuse a merge honestly, without blaming the unit.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"
cd "$REPO"
wt() { echo "$REPO/.coordinator/worktrees/$1"; }
pass() { "$COORD" dispatch "$1" --role critic >/dev/null; wait_for is_state "$1" passed; }

# two units append to file.txt: the second conflicts once the first merges
"$COORD" unit add a --kind chore --goal a >/dev/null
"$COORD" unit add b --kind chore --goal b >/dev/null
"$COORD" dispatch a --role worker --brief "$TMP/brief" >/dev/null; wait_for is_state a built
"$COORD" dispatch b --role worker --brief "$TMP/brief" >/dev/null; wait_for is_state b built
echo new > "$(wt b)/b-only.txt"                    # an untracked file of b's
pass a; "$COORD" approve a >/dev/null; "$COORD" merge a >/dev/null
pass b; "$COORD" approve b >/dev/null
refuses "conflicted" "$COORD" merge b
assert "$(state_of b)" handback

# the next worker round starts on the new main, with b's change re-applied
FAKE_WORKER=sleep "$COORD" dispatch b --role worker --brief "$TMP/brief" >/dev/null
assert "$(git -C "$(wt b)" rev-parse HEAD)" "$(git -C "$REPO" rev-parse main)"
grep -q '^<<<<<<<' "$(wt b)/file.txt" || { echo "  no conflict markers"; cat "$(wt b)/file.txt"; exit 1; }
assert "$(cat "$(wt b)/b-only.txt")" "new"
grep -q 'ENGINE NOTE: .*conflict markers.*file.txt' .coordinator/briefs/b.r2.worker.md || { echo "  prompt lacks the note"; exit 1; }
ls .coordinator/log/b.refresh.*.patch >/dev/null
"$COORD" block b --reason done >/dev/null

# build artifacts are ignored locally, never committed
grep -qx '__pycache__/' "$(git rev-parse --git-common-dir)/info/exclude"
"$COORD" unit add c --kind chore --goal c >/dev/null
"$COORD" dispatch c --role worker --brief "$TMP/brief" >/dev/null; wait_for is_state c built
mkdir -p "$(wt c)/__pycache__"; echo x > "$(wt c)/__pycache__/m.pyc"
[ -z "$(git -C "$(wt c)" status --porcelain -- __pycache__)" ] || { echo "  artifacts visible to agents"; exit 1; }

# untracked files in the base checkout: refused honestly, the unit keeps its approval
echo "c file" > "$(wt c)/c.txt"
pass c; "$COORD" approve c >/dev/null
echo "in the way" > "$REPO/c.txt"
refuses "untracked files in $REPO would be overwritten: c.txt" "$COORD" merge c
assert "$(state_of c)" approved
rm "$REPO/c.txt"
has "$("$COORD" merge c)" "MERGED c"
git -C "$REPO" show --name-only --format= HEAD^2 | grep -q __pycache__ && { echo "  artifacts merged"; exit 1; }

echo "  refresh ok"
