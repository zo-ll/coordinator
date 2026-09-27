#!/usr/bin/env bash
# Build bin/coord, run the Go unit tests, then every test/*.test.sh in a fresh
# bash process. Each test creates its own temp dir; no network, no real agents.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0

(cd "$HERE/.." && go vet ./... && go build -o bin/coord ./cmd/coord && go test ./... >/dev/null) || {
  echo "build or go test failed"; exit 1; }

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
