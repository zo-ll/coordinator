#!/usr/bin/env bash
# Create a slice's worktree off the latest base.
#
#   worktree.sh --slice <id> --slug <slug> [--repo PATH] [--base BRANCH] [--dir PATH]
#     -> WORKTREE <id> branch=coord/<id>-<slug> path=<path>
#
# Base branch defaults to config `merge.base`, else main. Worktrees live under
# $COORD_WORKTREES/<id>-<slug>, else <repo>/.coordinator/worktrees/<id>-<slug>.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/cfg.sh"
CONFIG="${COORD_CONFIG:-$PWD/.coordinator/config.conf}"
repo="${COORD_REPO:-$PWD}"
slice=""; slug=""; base=""; dir=""

while [ $# -gt 0 ]; do
  case "$1" in
    --slice) slice="$2"; shift 2 ;;
    --slug)  slug="$2";  shift 2 ;;
    --repo)  repo="$2";  shift 2 ;;
    --base)  base="$2";  shift 2 ;;
    --dir)   dir="$2";   shift 2 ;;
    *) echo "worktree.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$slice" ] && [ -n "$slug" ] || { echo "worktree.sh: --slice and --slug are required" >&2; exit 2; }

[ -n "$base" ] || base="$("$CFG" get "$CONFIG" merge.base 2>/dev/null || echo main)"
[ -n "$dir" ] || dir="${COORD_WORKTREES:-$repo/.coordinator/worktrees}/$slice-$slug"
branch="coord/$slice-$slug"

git -C "$repo" rev-parse --verify --quiet "$base^{commit}" >/dev/null || {
  echo "worktree.sh: base '$base' not found in $repo" >&2; exit 1
}
[ -e "$dir" ] && { echo "worktree.sh: path already exists: $dir" >&2; exit 1; }

mkdir -p "$(dirname "$dir")"
if git -C "$repo" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
  git -C "$repo" worktree add -q "$dir" "$branch"
else
  git -C "$repo" worktree add -q -b "$branch" "$dir" "$base"
fi
printf 'WORKTREE %s branch=%s path=%s\n' "$slice" "$branch" "$dir"
