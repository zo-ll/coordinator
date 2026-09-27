#!/usr/bin/env bash
# Merge a passed slice bound to its exact reviewed state, after approval.
# Implemented by bin/coord (merge); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" merge "$@"
