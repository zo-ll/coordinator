#!/usr/bin/env bash
set -uo pipefail

if [ "$#" -ne 1 ]; then
  printf 'Usage: bash %s <tmux-session>\n' "$0" >&2
  exit 2
fi

panes=$(tmux list-panes -s -t "$1" -F '#{pane_id}|#{window_name}|#{pane_current_command}') || exit 1
result=0
while IFS='|' read -r pane name command; do
  [ "$name" != coordinator ] || continue
  case "$name:$command" in
    *critic*|*researcher*|*worker*|*codex*|*claude*|*:pi) ;;
    *) continue ;;
  esac
  if ! capture=$(tmux capture-pane -p -t "$pane" -S -80 2>/dev/null); then
    printf '%s\t%s\tcapture-error\n' "$pane" "$name"
    result=1
    continue
  fi
  status=$(printf '%s\n' "$capture" | tail -n 80 | awk '
    BEGIN { state = "idle-ok" }
    {
      line = $0
      if (line ~ /^[[:space:]]*[$>]/) next
      sub(/^[^[:alnum:]]*/, "", line)
      if (line ~ /^(Working|Thinking)([[:space:](]|$)/) {
        state = "working"
      } else if (line ~ /Retry failed after [0-9]+ attempts|Aborted after [0-9]+ retry attempts/) {
        state = "aborted-at-idle"
      } else if (line ~ /rate_limit_exceeded|[Rr]etrying (in|after)|[Rr]etry [0-9]+\//) {
        state = "retry-wait"
      }
    }
    END { print state }
  ')
  printf '%s\t%s\t%s\n' "$pane" "$name" "$status"
done <<< "$panes"
exit "$result"
