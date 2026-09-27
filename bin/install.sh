#!/usr/bin/env bash
# Install this skill into every agent-harness skill dir found on the machine.
#
#   bin/install.sh              symlink this repo as <harness>/coordinator
#   bin/install.sh --uninstall  remove those symlinks
#
# The repo root is the skill (SKILL.md, bin/coord, playbooks/, agents/), so it
# is symlinked as a directory: edits and `git pull` stay live (bin/coord
# rebuilds itself when a Go source is newer than it and go is on PATH). Safe and idempotent. Override the
# target list with COORD_SKILL_DIRS (colon-separated) for testing.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${COORD_SKILL_NAME:-coordinator}"

if [ -n "${COORD_SKILL_DIRS:-}" ]; then
  IFS=':' read -r -a DIRS <<< "$COORD_SKILL_DIRS"
else
  DIRS=(
    "$HOME/.pi/agent/skills"
    "$HOME/.agents/skills"
    "$HOME/.claude/skills"
    "$HOME/.codex/skills"
    "$HOME/.config/opencode/skills"
    "$HOME/.config/crush/skills"
    "$HOME/.config/devin/skills"
    "$HOME/.config/goose/skills"
    "$HOME/.codemaker/skills"
    "$HOME/.codestudio/skills"
    "$HOME/.commandcode/skills"
    "$HOME/.astrbot/data/skills"
  )
fi

mode=install
case "${1:-}" in
  --uninstall) mode=uninstall ;;
  "")          ;;
  *) echo "usage: install.sh [--uninstall]" >&2; exit 2 ;;
esac

# build bin/coord (build output on stderr so stdout stays one line). Without
# go, an existing binary is kept.
if [ "$mode" = install ]; then
  if command -v go >/dev/null 2>&1; then
    (cd "$REPO" && go build -o bin/coord ./cmd/coord) >&2 || { echo "install: go build failed" >&2; exit 1; }
  elif [ ! -x "$REPO/bin/coord" ]; then
    echo "install: go is not on PATH and bin/coord is missing; the skill will not run until it is built" >&2
  fi
fi

linked=0 skipped=0 removed=0
for dir in "${DIRS[@]}"; do
  [ -d "$dir" ] || continue
  target="$dir/$NAME"

  if [ "$mode" = uninstall ]; then
    if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$REPO" ]; then
      rm -f "$target"
      echo "removed: $target" >&2
      removed=$((removed + 1))
    elif [ -e "$target" ] || [ -L "$target" ]; then
      echo "SKIP (not ours): $target" >&2
      skipped=$((skipped + 1))
    fi
    continue
  fi

  if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$REPO" ]; then
    skipped=$((skipped + 1))
    continue
  fi
  if [ -e "$target" ] || [ -L "$target" ]; then
    echo "SKIP (exists, not ours): $target" >&2
    skipped=$((skipped + 1))
    continue
  fi
  ln -s "$REPO" "$target"
  echo "linked: $target -> $REPO" >&2
  linked=$((linked + 1))
done

if [ "$mode" = install ]; then
  printf 'DONE linked=%s skipped=%s\n' "$linked" "$skipped"
else
  printf 'DONE removed=%s skipped=%s\n' "$removed" "$skipped"
fi
