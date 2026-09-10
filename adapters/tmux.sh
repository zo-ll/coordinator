#!/usr/bin/env bash
# Optional launch adapter: run a role in a tmux pane so it can be watched.
#
# Contract: adapter_launch <cwd> <log> <argv...> -> echoes a pid.
# Enabled by listing `tmux` in config.conf:adapters. It only changes WHERE a
# role runs; delivery, the finish protocol, routing, and merge are unchanged.
adapter_launch() {
  local cwd="$1" log="$2"
  shift 2
  command -v tmux >/dev/null 2>&1 || return 1
  local name="${ADAPTER_NAME:-coord}"
  local cmd qlog
  printf -v cmd '%q ' "$@"
  printf -v qlog '%q' "$log"
  tmux new-window -d -P -F '#{pane_pid}' -n "$name" -c "$cwd" "$cmd>>$qlog 2>&1"
}
