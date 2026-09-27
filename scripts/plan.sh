#!/usr/bin/env bash
# Reduce detected facts to a proposal plus the fields to ask about.
# Implemented by bin/coord (plan); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" plan "$@"
