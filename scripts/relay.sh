#!/usr/bin/env bash
# Serial queue consumer: batches pings and resumes the coordinator.
# Implemented by bin/coord (relay); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" relay "$@"
