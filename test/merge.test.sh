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
refuses "the worktree changed after review" "$COORD" merge m2
assert "$(state_of m2)" "handback"          # sent back for a new round, not stuck
has "$("$COORD" log m2)" "rejected m2 the worktree changed after review"
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

# --- VERIFY that leaves new files (reports, output): dropped, merge goes on ---
printf 'GOAL: g\nSCOPE: s\nACCEPTANCE: a\nVERIFY:\n  $ echo x > verify-report.txt\n' > "$TMP/litter"
to_passed m4 "$TMP/litter"
"$COORD" approve m4 >/dev/null
has "$("$COORD" merge m4)" "MERGED m4"
if git -C "$REPO" show --name-only --format= HEAD^2 | grep -q verify-report; then echo "  verify output was merged"; exit 1; fi
[ ! -e "$(wt m4)/verify-report.txt" ] || { echo "  verify output left in the worktree"; exit 1; }

# --- VERIFY that edits a reviewed file tested something else: refused ---
printf 'GOAL: g\nSCOPE: s\nACCEPTANCE: a\nVERIFY:\n  $ echo reformatted >> file.txt\n' > "$TMP/edits"
to_passed m6 "$TMP/edits"
"$COORD" approve m6 >/dev/null
reviewed="$(cat "$(wt m6)/file.txt")"
refuses "verify modified reviewed files: file.txt" "$COORD" merge m6
assert "$(state_of m6)" "handback"
assert "$(cat "$(wt m6)/file.txt")" "$reviewed"
hasnt "$(git -C "$(wt m6)" log -1 --format=%s)" "[coord]"

# --- the repo must be on the base ---
to_passed m5
"$COORD" approve m5 >/dev/null
git -C "$REPO" checkout -q -b elsewhere
refuses 'the repo is on "elsewhere", not the base "main"' "$COORD" merge m5
git -C "$REPO" checkout -q main
has "$("$COORD" merge m5)" "MERGED m5"

# --- auto-merge: a clean pass merges on its own; notes or risk wait for the user ---
printf 'autonomy=auto-merge\n' >> "$REPO/.coordinator/config.conf"
"$COORD" unit add m7 --kind feature --goal "unit m7" >/dev/null
"$COORD" dispatch m7 --role worker --brief "$TMP/brief" >/dev/null; wait_for is_state m7 built
has "$("$COORD" dispatch m7 --role critic)" "DISPATCHED m7"
wait_for is_state m7 merged
has "$("$COORD" log m7)" "merged m7"
grep -q $'\ttype=merged\tunit=m7\t.*by=auto' "$COORD_EVENTS" || { echo "  not marked auto"; exit 1; }
"$COORD" unit add m8 --kind feature --goal "unit m8" >/dev/null
"$COORD" dispatch m8 --role worker --brief "$TMP/brief" >/dev/null; wait_for is_state m8 built
FAKE_CRITIC=notepass "$COORD" dispatch m8 --role critic >/dev/null; wait_for is_state m8 passed
refuses "the critic passed it with notes, so it needs the user's approval" "$COORD" merge m8
"$COORD" unit add m9 --kind feature --goal "unit m9" --risk risky >/dev/null
printf 'routing.risky=default\n' >> "$REPO/.coordinator/config.conf"
"$COORD" dispatch m9 --role worker --brief "$TMP/brief" >/dev/null; wait_for is_state m9 built
"$COORD" dispatch m9 --role critic >/dev/null; wait_for is_state m9 passed
refuses "a risky unit needs the user's approval" "$COORD" merge m9

echo "  merge ok"
