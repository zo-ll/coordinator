#!/usr/bin/env bash
# Commit a boot-hygiene file authored by the coordinator. Never fatal: if the
# repo has no HEAD, the file is already ignored, or the commit fails, we leave
# the file in place and exit 0/1 quietly.
#
#   hygiene-commit.sh <repo> <path> <message>
#     force-add <path> (ignored files included) and commit IF it changed.
set -euo pipefail

repo="${1:?repo}"
path="${2:?path}"
msg="${3:?message}"

git -C "$repo" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || exit 0

uemail="$(git -C "$repo" config user.email || echo coord@local)"
uname="$(git -C "$repo" config user.name || echo coordinator)"

git -C "$repo" add -f -- "$path" 2>/dev/null || exit 0
[ -n "$(git -C "$repo" status --porcelain -- "$path" 2>/dev/null)" ] || exit 0
git -C "$repo" -c user.email="$uemail" -c user.name="$uname" commit -q -m "$msg" 2>/dev/null || exit 0
printf 'DONE %s\n' "$msg"