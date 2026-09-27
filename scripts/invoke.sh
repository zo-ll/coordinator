#!/usr/bin/env bash
# Build a role's argv from the env.conf exec recipe (NUL-separated); runs nothing.
# Implemented by bin/coord (invoke); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" invoke "$@"
