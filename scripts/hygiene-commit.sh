#!/usr/bin/env bash
# Commit a boot-hygiene file authored by the coordinator; never fatal.
# Implemented by bin/coord (hygiene); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" hygiene "$@"
