#!/usr/bin/env bash
# Minimal test runner: runs every test/*.test.sh in a fresh bash process.
# Each test creates its own temp dir; no network, no real agents.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

# the scripts are shims over bin/coord: vet and build it once, up front
(cd "$HERE/.." && go vet ./... && go build -o bin/coord ./cmd/coord) || { echo "build failed"; exit 1; }

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
