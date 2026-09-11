#!/usr/bin/env bash
# merge.sh: approval gate, reviewed-state binding, coordinator-authored commit,
# merge into base, ledger update.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MERGE="$HERE/../scripts/merge.sh"
STATE="$HERE/../scripts/state.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export COORD_ROOT="$TMP/coord"
export COORD_CONFIG="$TMP/repo/.coordinator/config.conf"
export COORD_LEDGER="$TMP/repo/.coordinator/ledger.tsv"
export COORD_REPO="$TMP/repo"
mkdir -p "$(dirname "$COORD_CONFIG")" "$COORD_ROOT"

git init -q -b main "$COORD_REPO"
git -C "$COORD_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$COORD_REPO" config user.email t@t
git -C "$COORD_REPO" config user.name t
printf 'autonomy=approve-merge\nmerge.base=main\n' > "$COORD_CONFIG"

state_hash() { git -C "$1" diff HEAD | sha256sum | cut -d' ' -f1; }

# --- happy path: worker stages (never commits); reviewer binds to the state ---
git -C "$COORD_REPO" worktree add -q -b coord/1-s1 "$TMP/wt" main
echo hi > "$TMP/wt/file.txt"
git -C "$TMP/wt" add -A            # stage only — no worker commit
head="$(state_hash "$TMP/wt")"
[ "$head" != "$(git -C "$TMP/wt" rev-parse HEAD)" ] || { echo "  state hash should differ from commit"; exit 1; }

"$STATE" add s1 "slice one" >/dev/null
"$STATE" dispatch s1 0 "$TMP/wt" coord/1-s1 s1 >/dev/null
"$STATE" verdict s1 1 pass "$head" >/dev/null

# no approval -> refuse
if "$MERGE" --slice s1 >/dev/null 2>&1; then echo "  merged without approval"; exit 1; fi

mkdir -p "$COORD_ROOT/approvals"
: > "$COORD_ROOT/approvals/s1"
out="$("$MERGE" --slice s1)"
case "$out" in MERGE\ s1\ base=main\ sha=*) ;; *) echo "  bad output: $out"; exit 1 ;; esac
[ "$out" = "$(printf '%s\n' "$out" | grep -v '^PUSH ')" ] || { echo "  pushed without origin"; exit 1; }
git -C "$COORD_REPO" cat-file -e main:file.txt || { echo "  main missing merged file"; exit 1; }
# the commit was authored by the coordinator on the slice branch
[ "$(git -C "$TMP/wt" log -1 --format=%an)" = "t" ] || { echo "  commit not user identity"; exit 1; }
[ "$(git -C "$TMP/wt" log -1 --format=%s)" = "[coord] slice one" ] || { echo "  bad commit message"; exit 1; }
[ "$("$STATE" get s1 status)" = "merged" ] || { echo "  not marked merged"; exit 1; }

# --- state drift after review -> refuse ---
git -C "$COORD_REPO" worktree add -q -b coord/2-s2 "$TMP/wt2" main
echo y > "$TMP/wt2/f2"
git -C "$TMP/wt2" add -A
head2="$(state_hash "$TMP/wt2")"
"$STATE" add s2 "slice two" >/dev/null
"$STATE" dispatch s2 0 "$TMP/wt2" coord/2-s2 s2 >/dev/null
"$STATE" verdict s2 1 pass "$head2" >/dev/null
: > "$COORD_ROOT/approvals/s2"
echo z >> "$TMP/wt2/f2"            # drift after review
git -C "$TMP/wt2" add -A
if "$MERGE" --slice s2 >/dev/null 2>"$TMP/err"; then echo "  merged a drifted state"; exit 1; fi
grep -q "reviewed state" "$TMP/err" || { echo "  unclear drift error:"; cat "$TMP/err"; exit 1; }

# --- untracked (non-.scratch) files left unstaged -> refuse ---
git -C "$COORD_REPO" worktree add -q -b coord/3-s3 "$TMP/wt3" main
echo n > "$TMP/wt3/f3"
git -C "$TMP/wt3" add -A
head3="$(state_hash "$TMP/wt3")"
"$STATE" add s3 "slice three" >/dev/null
"$STATE" dispatch s3 0 "$TMP/wt3" coord/3-s3 s3 >/dev/null
"$STATE" verdict s3 1 pass "$head3" >/dev/null
: > "$COORD_ROOT/approvals/s3"
echo scratch > "$TMP/wt3/never-staged.txt"
if "$MERGE" --slice s3 >/dev/null 2>"$TMP/err"; then echo "  merged with untracked files"; exit 1; fi
grep -q "untracked files" "$TMP/err" || { echo "  unclear untracked error:"; cat "$TMP/err"; exit 1; }

# --- .scratch/ markers do NOT count as untracked ---
echo ok > "$TMP/wt3/f3"
git -C "$TMP/wt3" add -A
head3b="$(state_hash "$TMP/wt3")"
"$STATE" verdict s3 1 pass "$head3b" >/dev/null
mkdir -p "$TMP/wt3/.scratch/status"
: > "$TMP/wt3/.scratch/status/s3-worker-1.done"
out="$("$MERGE" --slice s3)"
case "$out" in MERGE\ s3\ base=main\ sha=*) ;; *) echo "  merge with .scratch failed: $out"; exit 1 ;; esac

echo "  merge ok"