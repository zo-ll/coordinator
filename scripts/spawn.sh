#!/usr/bin/env bash
# Launch one role, detached, in its worktree, and record the dispatch.
# Implemented by bin/coord (spawn); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" spawn "$@"
