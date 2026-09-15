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
source "$HERE/progress.sh"
progress_start finish

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
progress_context="event=${event:-missing} role=${role:-missing} result=${result:-missing}"
[ -n "$event" ] && [ -n "$role" ] && [ -n "$result" ] || {
  echo "finish.sh: --event, --role and --result are required" >&2
  exit 2
}
case "$event" in
  *[!A-Za-z0-9._-]*|'') echo "finish.sh: invalid --event slug '$event' (use [A-Za-z0-9._-]+)" >&2; exit 2 ;;
esac

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

# A critic's --result is a claim, not a fact: when the critic supplied a
# structured verdict (.scratch/verdict.md), the result is derived from it
# deterministically (issue #9), so a stated pass with a high finding never
# reaches the queue. Without a verdict file (legacy fixtures, non-schema
# critics) the stated result is kept.
verdict_suffix=""
if [ "$role" = "critic" ] && [ -f "$PWD/.scratch/verdict.md" ]; then
  verdict_out="$("$HERE/compute-verdict.sh" "$PWD" "$event")"
  derived_result="$(printf '%s\n' "$verdict_out" | sed -n 's/^RESULT //p')"
  derived_rollup="$(printf '%s\n' "$verdict_out" | sed -n 's/^ROLLUP //p')"
  if [ "$derived_result" != "$result" ]; then
    echo "finish.sh: stated --result '$result' does not match derived verdict '$derived_result' (from $PWD/.scratch/verdict.md)" >&2
    exit 2
  fi
  if [ "$derived_result" = "handback" ] && [ -n "$derived_rollup" ]; then
    verdict_suffix=": $derived_rollup"
  fi
  # position anchoring (issue #10): carry unverifiable quotes in the line the
  # relay sees, so the coordinator can react without reading prose
  quotes="$(printf '%s\n' "$verdict_out" | sed -n 's/^QUOTES //p')"
  if [ -n "$quotes" ] && [ "$quotes" != "n/a" ]; then
    missing="$(printf '%s' "$quotes" | sed -n 's/^verified=[0-9]* shifted=[0-9]* missing=\([0-9]*\).*/\1/p')"
    if [ -n "$missing" ] && [ "$missing" -gt 0 ] 2>/dev/null; then
      verdict_suffix="${verdict_suffix:+$verdict_suffix, }$missing unverified quote$([ "$missing" = 1 ] || echo s)"
    fi
  fi
fi

markers="${COORD_MARKERS:-$PWD/.scratch/status}"
progress_context="event=$event role=$role result=$result"
progress_phase marker
mkdir -p "$markers"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'done TS=%s TASK=%s ROUND=%s ROLE=%s HEAD=%s RESULT=%s SUMMARY=%s\n' \
  "$ts" "$task" "$round" "$role" "$head" "$result" "$summary" > "$markers/$event.done"

if [ "$role" = "critic" ]; then
  line="VERDICT $task: $result$verdict_suffix @ $head — $summary"
else
  line="DONE $task: $result — $summary"
fi
progress_event OK "completion marker written: $markers/$event.done"
progress_phase enqueue
# De-dup key: a repeated completion of THIS event at THIS round and head is a
# true duplicate; a new round or a changed head must still wake the coordinator.
dedup_key="$event.r${round:--}.$(printf '%s' "${head:--}" | cut -c1-12)"
enqueued="$("$HERE/queue.sh" enqueue "$event" "$line" "$dedup_key")"
progress_note="$enqueued; completion published, coordinator processing is separate"
case "$enqueued" in DUP\ *) progress_event WARN "duplicate event=$event suppressed; no new coordinator notification" ;; esac

printf 'FINISH %s task=%s round=%s\n' "$event" "$task" "$round"
