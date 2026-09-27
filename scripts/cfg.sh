#!/usr/bin/env bash
# Flat key=value config reader/writer; values are literal, never evaluated.
# Implemented by bin/coord (cfg); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" cfg "$@"
