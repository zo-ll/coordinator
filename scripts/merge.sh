#!/usr/bin/env bash
# Merge a passed slice, bound to the reviewed HEAD and a recorded user approval.
#
#   merge.sh --slice <id>      -> MERGE <id> base=<b> sha=<merge-commit>
#
# Refuses unless: the verdict is pass, the branch HEAD still equals the reviewed
# HEAD, and (unless autonomy=auto-merge) an approval exists at
# $COORD_ROOT/approvals/<id>. Merges the slice branch into config merge.base
# (default: main) in $COORD_REPO (default: $PWD), then records merged.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/cfg.sh"
STATE="$HERE/state.sh"
CONFIG="${COORD_CONFIG:-$PWD/.coordinator/config.conf}"
COORD_ROOT="${COORD_ROOT:-/tmp/coordinator}"
repo="${COORD_REPO:-$PWD}"

slice=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slice) slice="$2"; shift 2 ;;
    *) echo "merge.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$slice" ] || { echo "merge.sh: --slice is required" >&2; exit 2; }

verdict="$("$STATE" get "$slice" verdict 2>/dev/null || true)"
head="$("$STATE" get "$slice" head 2>/dev/null || true)"
wt="$("$STATE" get "$slice" worktree 2>/dev/null || true)"
branch="$("$STATE" get "$slice" branch 2>/dev/null || true)"

[ "$verdict" = "pass" ] || { echo "merge: slice $slice has no PASS verdict (got '${verdict:-none}')" >&2; exit 1; }
[ -n "$wt" ] && [ -n "$branch" ] || { echo "merge: slice $slice has no worktree/branch" >&2; exit 1; }

autonomy="$("$CFG" get "$CONFIG" autonomy 2>/dev/null || true)"
if [ "$autonomy" != "auto-merge" ]; then
  [ -f "$COORD_ROOT/approvals/$slice" ] || { echo "merge: no recorded user approval for $slice" >&2; exit 1; }
fi

cur="$(git -C "$wt" rev-parse HEAD 2>/dev/null)" || { echo "merge: cannot read HEAD in $wt" >&2; exit 1; }
[ "$cur" = "$head" ] || { echo "merge: reviewed HEAD $head != branch HEAD $cur (re-review required)" >&2; exit 1; }

base="$("$CFG" get "$CONFIG" merge.base 2>/dev/null || echo main)"
git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "merge: base '$base' not found in $repo" >&2; exit 1; }

uemail="$(git -C "$repo" config user.email || echo coord@local)"
uname="$(git -C "$repo" config user.name || echo coordinator)"
if ! git -c user.email="$uemail" -c user.name="$uname" -C "$repo" merge --no-ff --no-edit "$branch" >/dev/null 2>&1; then
  echo "merge: git merge failed for $branch" >&2
  exit 1
fi

sha="$(git -C "$repo" rev-parse HEAD)"
"$STATE" merged "$slice" "$sha" >/dev/null
printf 'MERGE %s base=%s sha=%s\n' "$slice" "$base" "$sha"
