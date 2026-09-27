#!/usr/bin/env bash
# One-command view of a run: ledger, queue depth, live pids, log tails.
# Implemented by bin/coord (status); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" status "$@"
