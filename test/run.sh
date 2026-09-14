#!/usr/bin/env bash
# Minimal test runner: runs every test/*.test.sh in a fresh bash process.
# Each test creates its own temp dir; no network, no real agents.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

shopt -s nullglob
for t in "$HERE"/*.test.sh; do
  echo "== $(basename "$t")"
  # sealed: clear any coordinator env inherited from a live run so tests always
  # operate on their own temp state (observed leaking COORD_WORKTREES into
  # worktree.test.sh when this runner executes inside a coordinator session)
  if COORD_HOME= COORD_ROOT= COORD_CONFIG= COORD_LEDGER= COORD_REPO= \
     COORD_WORKTREES= COORD_ENV_CONF= COORD_ADAPTERS= COORD_SESSION= \
     COORD_MARKERS= COORD_MARKERS_ROOT= \
     bash "$t"; then
    echo "   ok"
  else
    echo "   FAIL"
    fail=1
  fi
done

exit "$fail"
