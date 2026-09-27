#!/usr/bin/env bash
# Detect the environment and write $COORD_HOME/env.conf.
# Implemented by bin/coord (detect); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" detect "$@"
