#!/usr/bin/env bash
# merge.sh: approval gate, HEAD binding, merge into base, ledger update.
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
printf 'autonomy=approve-merge\nmerge.base=main\n' > "$COORD_CONFIG"

git -C "$COORD_REPO" worktree add -q -b coord/1-s1 "$TMP/wt" main
echo hi > "$TMP/wt/file.txt"
git -C "$TMP/wt" add -A
git -C "$TMP/wt" -c user.email=t@t -c user.name=t commit -q -m change
head="$(git -C "$TMP/wt" rev-parse HEAD)"

"$STATE" add s1 "slice one" >/dev/null
"$STATE" dispatch s1 0 "$TMP/wt" coord/1-s1 s1 >/dev/null
"$STATE" verdict s1 1 pass "$head" >/dev/null

# no approval -> refuse
if "$MERGE" --slice s1 >/dev/null 2>&1; then echo "  merged without approval"; exit 1; fi

mkdir -p "$COORD_ROOT/approvals"
: > "$COORD_ROOT/approvals/s1"
out="$("$MERGE" --slice s1)"
case "$out" in MERGE\ s1\ base=main\ sha=*) ;; *) echo "  bad output: $out"; exit 1 ;; esac
git -C "$COORD_REPO" cat-file -e main:file.txt || { echo "  main missing merged file"; exit 1; }
[ "$("$STATE" get s1 status)" = "merged" ] || { echo "  not marked merged"; exit 1; }

# HEAD drift after review -> refuse
git -C "$COORD_REPO" worktree add -q -b coord/2-s2 "$TMP/wt2" main
echo y > "$TMP/wt2/f2"
git -C "$TMP/wt2" add -A
git -C "$TMP/wt2" -c user.email=t@t -c user.name=t commit -q -m change2
head2="$(git -C "$TMP/wt2" rev-parse HEAD)"
"$STATE" add s2 "slice two" >/dev/null
"$STATE" dispatch s2 0 "$TMP/wt2" coord/2-s2 s2 >/dev/null
"$STATE" verdict s2 1 pass "$head2" >/dev/null
: > "$COORD_ROOT/approvals/s2"
echo z >> "$TMP/wt2/f2"
git -C "$TMP/wt2" add -A
git -C "$TMP/wt2" -c user.email=t@t -c user.name=t commit -q -m drift
if "$MERGE" --slice s2 >/dev/null 2>&1; then echo "  merged a drifted HEAD"; exit 1; fi

echo "  merge ok"
