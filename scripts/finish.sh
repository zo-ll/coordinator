#!/usr/bin/env bash
# Record completion: write the recovery marker, then enqueue the ping.
#
#   finish.sh --event <slug> --role <worker|critic|researcher> \
#             --result <done|checkpoint|correction|pass|handback> \
#             --head <sha|-> --summary "one line"
#
# Marker: $COORD_MARKERS/<event>.done (default <cwd>/.scratch/status),
# written BEFORE the ping is enqueued so a crash between the two is recoverable.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

event="" role="" result="" head="-" summary=""
while [ $# -gt 0 ]; do
  case "$1" in
    --event)   event="$2";   shift 2 ;;
    --role)    role="$2";    shift 2 ;;
    --result)  result="$2";  shift 2 ;;
    --head)    head="$2";    shift 2 ;;
    --summary) summary="$2"; shift 2 ;;
    *) echo "finish.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$event" ] && [ -n "$role" ] && [ -n "$result" ] || {
  echo "finish.sh: --event, --role and --result are required" >&2
  exit 2
}

# Derive TASK and ROUND from the slug: foo -> foo/r1; foo.critic -> foo/r1;
# foo.r2 -> foo/r2; foo.r2.critic -> foo/r2.
base="${event%.critic}"
round=1
task="$base"
case "$base" in
  *.r[0-9]*)
    round="${base##*.r}"
    task="${base%.*}"
    ;;
esac

markers="${COORD_MARKERS:-$PWD/.scratch/status}"
mkdir -p "$markers"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'done TS=%s TASK=%s ROUND=%s ROLE=%s HEAD=%s RESULT=%s SUMMARY=%s\n' \
  "$ts" "$task" "$round" "$role" "$head" "$result" "$summary" > "$markers/$event.done"

if [ "$role" = "critic" ]; then
  line="VERDICT $task: $result @ $head — $summary"
else
  line="DONE $task: $result — $summary"
fi
"$HERE/queue.sh" enqueue "$event" "$line" >/dev/null

printf 'FINISH %s task=%s round=%s\n' "$event" "$task" "$round"
