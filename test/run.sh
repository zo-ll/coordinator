#!/usr/bin/env bash
# Run every test/*.test.sh in a fresh bash process. Each test creates its own
# temp repo and drives bin/filo with a fake harness; no network, no real agents.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

shopt -s nullglob
for t in "$HERE"/*.test.sh; do
  echo "== $(basename "$t")"
  if bash "$t"; then
    echo "   ok"
  else
    echo "   FAIL"
    fail=1
  fi
done

exit "$fail"
