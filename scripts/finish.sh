#!/usr/bin/env bash
# Record completion: write the recovery marker, then enqueue the ping.
# Implemented by bin/coord (finish); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" finish "$@"
