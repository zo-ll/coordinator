#!/usr/bin/env bash
# Create a slice's worktree off the latest base.
# Implemented by bin/coord (worktree); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" worktree "$@"
