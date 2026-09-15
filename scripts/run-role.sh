#!/usr/bin/env bash
# Supervise a detached harness so launch success never masquerades as work
# completion. Used by both core setsid and optional launch adapters.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/progress.sh"
role="${1:?role}"; slice="${2:?slice or -}"; event="${3:?event or -}"
shift 3
progress_start role "role=$role slice=$slice event=$event"
progress_phase running "role=$role slice=$slice harness=${1:-missing}; waiting for process exit"
rc=0
"$@" || rc=$?
if [ "$rc" -ne 0 ]; then
  progress_note="harness exited unsuccessfully; inspect log/$role.$slice.log"
  exit "$rc"
fi
if [ "$event" != - ] && [ ! -f "${COORD_MARKERS:-$PWD/.scratch/status}/$event.done" ]; then
  progress_note="harness exited without completion marker for $event; inspect log/$role.$slice.log"
  exit 1
fi
progress_note="harness exited successfully; completion marker verified"
if [ "$event" = - ]; then progress_note="harness exited successfully; no completion contract for this role"; fi
