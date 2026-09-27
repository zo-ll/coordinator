#!/usr/bin/env bash
# Ping queue: ordered, de-duplicated, single-consumer.
# Implemented by bin/coord (queue); see cmd/coord for the contract.
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/lib/exec.sh" queue "$@"
