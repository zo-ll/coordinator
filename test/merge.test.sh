#!/usr/bin/env bash
# coord merge: approval gate, reviewed-state binding (independent of staging),
# VERIFY re-run by the engine, coordinator-authored commit, auto-merge.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"
git init -q --bare "$TMP/remote.git"
git -C "$REPO" remote add origin "$TMP/remote.git"
git -C "$REPO" push -q origin main
remote_before=$(git --git-dir="$TMP/remote.git" rev-parse refs/heads/main)
to_passed() { # to_passed <id> [brief]
  "$COORD" unit add "$1" --kind feature --goal "unit $1" >/dev/null
  "$COORD" dispatch "$1" --role worker --brief "${2:-$TMP/brief}" >/dev/null
  wait_for is_state "$1" built
  "$COORD" dispatch "$1" --role critic >/dev/null
  wait_for is_state "$1" passed
}
wt() { echo "$REPO/.coordinator/worktrees/$1"; }

# --- happy path ---
to_passed m1
refuses "REFUSED m1 merged: needs the user's approval (coord approve m1)" "$COORD" merge m1
"$COORD" approve m1 >/dev/null
git -C "$(wt m1)" add -A     # staging after review does not change the state
out="$("$COORD" merge m1)"
has "$out" "MERGED m1 sha="
hasnt "$out" "PUSHED"
assert "$(git --git-dir="$TMP/remote.git" rev-parse refs/heads/main)" "$remote_before"
if [ "$(git -C "$REPO" rev-parse main)" = "$remote_before" ]; then echo "  local merge did not advance main"; exit 1; fi
git -C "$REPO" show main:file.txt | grep -q "change by m1.r1.worker" || { echo "  main lacks the change"; exit 1; }
assert "$(git -C "$(wt m1)" log -1 --format='%an %s')" "t [coord] unit m1"
assert "$(state_of m1)" "merged"
has "$(cat "$REPO/.coordinator/log/m1.verify.log")" '$ test "$(wc -l < file.txt)" -gt 1'

# --- drift after review ---
to_passed m2
"$COORD" approve m2 >/dev/null
echo sneaky > "$(wt m2)/extra.txt"      # untracked counts too
refuses "reviewed state" "$COORD" merge m2
assert "$(state_of m2)" "approved"
rm "$(wt m2)/extra.txt"

# --- VERIFY fails on the reviewed state -> handback ---
sed 's/-gt 1/-gt 99/' "$TMP/brief" > "$TMP/strict"
to_passed m3 "$TMP/strict"
"$COORD" approve m3 >/dev/null
refuses 'REFUSED m3 merged: verify failed: test "$(wc -l < file.txt)" -gt 99 (exit 1)' "$COORD" merge m3
assert "$(state_of m3)" "handback"
has "$("$COORD" log m3)" "verify_failed m3"

# the failed merge left no commit behind
hasnt "$(git -C "$(wt m3)" log -1 --format=%s)" "[coord]"

# --- VERIFY that leaves new files (bytecode, reports): dropped, merge goes on ---
printf 'GOAL: g\nSCOPE: s\nACCEPTANCE: a\nVERIFY:\n  $ mkdir -p __pycache__ && echo x > __pycache__/m.pyc\n' > "$TMP/litter"
to_passed m4 "$TMP/litter"
"$COORD" approve m4 >/dev/null
has "$("$COORD" merge m4)" "MERGED m4"
if git -C "$REPO" show --name-only --format= HEAD^2 | grep -q __pycache__; then echo "  verify output was merged"; exit 1; fi
[ ! -e "$(wt m4)/__pycache__" ] || { echo "  verify output left in the worktree"; exit 1; }

# --- VERIFY that edits a reviewed file tested something else: refused ---
printf 'GOAL: g\nSCOPE: s\nACCEPTANCE: a\nVERIFY:\n  $ echo reformatted >> file.txt\n' > "$TMP/edits"
to_passed m6 "$TMP/edits"
"$COORD" approve m6 >/dev/null
reviewed="$(cat "$(wt m6)/file.txt")"
refuses "verify modified reviewed files: file.txt" "$COORD" merge m6
assert "$(state_of m6)" "handback"
assert "$(cat "$(wt m6)/file.txt")" "$reviewed"
hasnt "$(git -C "$(wt m6)" log -1 --format=%s)" "[coord]"

# --- auto-merge needs no approval; repo must be on the base ---
printf 'autonomy=auto-merge\n' >> "$REPO/.coordinator/config.conf"
to_passed m5
git -C "$REPO" checkout -q -b elsewhere
refuses 'the repo is on "elsewhere", not the base "main"' "$COORD" merge m5
git -C "$REPO" checkout -q main
has "$("$COORD" merge m5)" "MERGED m5"

echo "  merge ok"
