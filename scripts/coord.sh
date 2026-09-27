#!/usr/bin/env bash
# Start a run: resolve the real session id, record it, start the relay.
# Implemented by bin/coord (start); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" start "$@"
