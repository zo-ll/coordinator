#!/usr/bin/env bash
# Apply the user's answers over the proposal, validate, and write config.conf.
# Implemented by bin/coord (apply); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" apply "$@"
