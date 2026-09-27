#!/usr/bin/env bash
# Slice ledger: the coordinator's memory, and the only parser of it.
# Implemented by bin/coord (state); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" state "$@"
