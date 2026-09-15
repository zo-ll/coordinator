#!/usr/bin/env bash
# Shared diagnostics. stdout remains the scripts' machine-readable contract.
# Source, then progress_start <step> [context]. Call progress_phase before a
# fallible operation; progress_cleanup may be overridden for EXIT cleanup.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/queue.sh"

progress_event() { # <START|OK|WAIT|WARN|FAIL> <message>
  local level="$1" message="${2:-}" line
  message="${message//$'\n'/ }"
  message="${message//$'\r'/ }"
  printf -v line '[COORD] %s %(%Y-%m-%dT%H:%M:%S%z)T pid=%s step=%s phase=%s %s' \
    "$level" -1 "$$" "$progress_step" "$progress_stage" "$message"
  printf '%s\n' "$line" >&2
  # Serialize whole records from concurrent workers without sharing their fds.
  if ! ( mkdir -p "$COORD_ROOT" &&
         exec 7>>"$COORD_ROOT/progress.log" &&
         flock 7 && printf '%s\n' "$line" >&7 ); then
    printf '[COORD] FAIL progress log unavailable: %s/progress.log\n' "$COORD_ROOT" >&2
  fi
}

progress_phase() {
  progress_stage="$1"
  progress_event START "${2:-$progress_context}"
}

progress_cleanup() { :; }

progress_exit() {
  local rc="$1"
  if [ "$rc" -eq 0 ]; then
    progress_event "${progress_result:-OK}" "exit=0 $progress_context ${progress_note:-step completed}"
  else
    progress_event FAIL "exit=$rc $progress_context ${progress_note:-step failed; inspect the error above and run status.sh}"
  fi
  progress_cleanup
  return "$rc"
}

progress_start() {
  progress_step="$1"
  progress_stage=validate
  progress_context="${2:-}"
  progress_note=""
  progress_result=OK
  trap 'progress_exit "$?"' EXIT
  progress_event START "$progress_context"
}
