#!/usr/bin/env bash
# Merge a passed slice. The review was of the WORKING-TREE STATE (workers only
# stage), so approval binds to a diff hash, not a commit: merge.sh recomputes
# the reviewed state, authors the commit on the slice branch with the user's
# identity, merges it into merge.base, and pushes if origin exists.
#
#   merge.sh --slice <id>      -> MERGE <id> base=<b> sha=<merge-commit>
#                                 [PUSH <base> -> origin/<base>]
#
# Refuses unless: the verdict is pass, the recorded reviewed-state hash still
# matches the worktree, nothing is unstaged or untracked (outside .scratch/),
# and (unless autonomy=auto-merge) an approval exists at
# $COORD_ROOT/approvals/<id>.
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
# approval integrity (issue #14): a headless coordinator resume must never
# merge on its own, even when an approvals file exists — only a human (or the
# interactive coordinator acting on one) may merge.
[ -z "${COORD_HEADLESS:-}" ] || { echo "merge: refusing to merge under COORD_HEADLESS=1 (a human must approve via \`coord approve <id>\`)" >&2; exit 1; }

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

# the review was of the working-tree state, not a commit: recompute the exact
# reviewed state (diff vs the slice base) and refuse on any drift.
hash="$(git -C "$wt" diff HEAD | sha256sum | cut -d' ' -f1)"
[ "$hash" = "$head" ] || {
  echo "merge: reviewed state $head != current $hash (re-review required)" >&2; exit 1; }
[ -n "$(git -C "$wt" diff --name-only)" ] && {
  echo "merge: unstaged tracked changes in $wt (workers must stage everything)" >&2; exit 1; }
if git -C "$wt" status --porcelain | sed -n 's/^?? //p' | grep -v '^\.scratch/' | grep -q .; then
  echo "merge: untracked files (outside .scratch/) were never staged" >&2; exit 1
fi

base="$("$CFG" get "$CONFIG" merge.base 2>/dev/null || echo main)"
git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null || { echo "merge: base '$base' not found in $repo" >&2; exit 1; }

uemail="$(git -C "$repo" config user.email || echo coord@local)"
uname="$(git -C "$repo" config user.name || echo coordinator)"

# the coordinator authors the commit on the slice branch (user's identity only)
goal="$("$STATE" get "$slice" goal 2>/dev/null || echo "$slice")"
if ! git -C "$wt" -c user.email="$uemail" -c user.name="$uname" commit -q -m "[coord] $goal"; then
  echo "merge: commit failed in $wt" >&2; exit 1
fi

if ! git -c user.email="$uemail" -c user.name="$uname" -C "$repo" merge --no-ff --no-edit "$branch" >/dev/null 2>&1; then
  echo "merge: git merge failed for $branch" >&2
  exit 1
fi

sha="$(git -C "$repo" rev-parse HEAD)"
"$STATE" merged "$slice" "$sha" >/dev/null
printf 'MERGE %s base=%s sha=%s\n' "$slice" "$base" "$sha"
# push what we actually merged INTO (the checked-out branch), not the base:
# the merge lands on the current branch, so report and push that ref truthfully
cur="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
if [ -n "$cur" ] && git -C "$repo" remote | grep -qx origin; then
  if git -C "$repo" push origin "$cur" >/dev/null 2>&1; then
    printf 'PUSH %s -> origin/%s\n' "$cur" "$cur"
  else
    echo "merge: merged locally, but push to origin/$cur failed (run \`git push origin $cur\` to publish)" >&2
  fi
fi
