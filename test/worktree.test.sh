#!/usr/bin/env bash
# worktree.sh: branch off the base and create the slice worktree.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WT="$HERE/../scripts/worktree.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export COORD_REPO="$TMP/repo"
export COORD_CONFIG="$TMP/repo/.coordinator/config.conf"
mkdir -p "$(dirname "$COORD_CONFIG")"
git init -q -b main "$COORD_REPO"
git -C "$COORD_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'merge.base=main\n' > "$COORD_CONFIG"

out="$("$WT" --slice 1 --slug thing)"
expected="WORKTREE 1 branch=coord/1-thing path=$COORD_REPO/.coordinator/worktrees/1-thing"
[ "$out" = "$expected" ] || { echo "  bad output: $out"; exit 1; }
[ -d "$COORD_REPO/.coordinator/worktrees/1-thing" ] || { echo "  worktree not created"; exit 1; }
[ "$(git -C "$COORD_REPO/.coordinator/worktrees/1-thing" rev-parse --abbrev-ref HEAD)" = "coord/1-thing" ] || {
  echo "  wrong branch"; exit 1
}

echo "  worktree ok"
