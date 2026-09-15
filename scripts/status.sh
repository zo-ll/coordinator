#!/usr/bin/env bash
# One-command view of a run: the ledger, queue depth, live pids, wake-liveness
# staleness, and the tail of every active role log. Read-only — it composes
# state.sh/queue.sh and never touches the ledger itself. This is the sanctioned
# way to observe progress; roles must never be tailed by hand.
#
#   status.sh
#     -> STATUS relay=<pid|-> alive=<0|1>
#        QUEUE pending=<n> inflight=<n> done=<n>
#        STALE batch=<path> age=<min>    one line per stale pending/inflight ping
#        STALE none                      when nothing on the delivery path is stale
#        SLICE <id> <status> pid=<pid|-> alive=<0|1> verdict=<v|-> goal=<...>
#        SLICE-STALE <id> age=<min>      dispatched slice, dead pid or no event
#        LOG <id> <role> <last non-empty line>   (live slices only, truncated)
#
# A stale batch ping is a relay/wake failure: it has sat on the delivery path
# (pending in the queue, or crash-stranded in .inflight) longer than
# COORD_STALE_MIN minutes (default 15). A stale slice is a dispatched slice
# whose recorded pid is dead, or whose pid is alive but whose worktree has
# produced no finish marker for that long. status.sh never auto-fixes; it
# surfaces the signal and exits nonzero when anything is stale.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/queue.sh"

# A plain second terminal is enough to observe detached work. Emit a new
# snapshot only when it changes; keep watching through nonzero health checks.
if [ "${1:-}" = --watch ]; then
  shift
  interval=2
  if [ "${1:-}" = --interval ]; then interval="${2:-}"; shift 2; fi
  case "$interval" in ''|*[!0-9]*|0) echo 'status: --interval must be a positive integer' >&2; exit 2 ;; esac
  [ $# -eq 0 ] || { echo 'status: usage: status.sh [--watch [--interval seconds]]' >&2; exit 2; }
  trap 'exit 0' INT TERM
  printf 'WATCH root=%s interval=%ss (Ctrl-C stops watching; workers keep running)\n' "$COORD_ROOT" "$interval"
  previous=""
  while :; do
    snapshot="$("$HERE/status.sh" 2>&1)" || true
    if [ "$snapshot" != "$previous" ]; then
      printf '\n%s\n' "$snapshot"
      previous="$snapshot"
    fi
    sleep "$interval"
  done
fi
[ $# -eq 0 ] || { echo 'status: usage: status.sh [--watch [--interval seconds]]' >&2; exit 2; }

STALE_MIN="${COORD_STALE_MIN:-15}"

case "$STALE_MIN" in
  ''|*[!0-9]*)
    echo "status: COORD_STALE_MIN must be a non-negative integer" >&2
    exit 2
    ;;
esac
stale_secs=$(( STALE_MIN * 60 ))


alive() { [ -n "$1" ] && [ "$1" != "-" ] && kill -0 "$1" 2>/dev/null; }

now="$(date +%s)"

# Whole minutes since an epoch timestamp, rounded up, so a 60-minute-old ping
# reports age=60 rather than 59.
age_min() { # <epoch-seconds>
  local d=$(( now - $1 ))
  if [ "$d" -lt 0 ]; then d=0; fi
  echo $(( (d + 59) / 60 ))
}

# Minutes since the freshest activity in a dispatched slice's worktree: the
# newest finish marker under <worktree>/.scratch/status, else the worktree dir
# itself. Empty (return 1) when neither exists, so an unlocatable worktree is
# never reported stale on freshness alone.
slice_age() { # <slice-id>
  local id="$1" wt f mt best=0
  wt="$("$HERE/state.sh" get "$id" worktree 2>/dev/null || true)"
  if [ -z "$wt" ] || [ "$wt" = "-" ]; then return 1; fi
  if [ -d "$wt/.scratch/status" ]; then
    for f in "$wt"/.scratch/status/*.done; do
      [ -e "$f" ] || continue
      mt="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
      if [ "$mt" -gt "$best" ]; then best="$mt"; fi
    done
  fi
  if [ "$best" = 0 ] && [ -d "$wt" ]; then
    best="$(stat -c %Y "$wt" 2>/dev/null || echo 0)"
  fi
  if [ "$best" = 0 ]; then return 1; fi
  age_min "$best"
}

stale=0

# relay
rpid=""
if [ -f "$COORD_ROOT/relay.pid" ]; then
  rpid="$(cat "$COORD_ROOT/relay.pid" 2>/dev/null || true)"
fi
if alive "$rpid"; then ra=1; else ra=0; fi
printf 'STATUS relay=%s alive=%s\n' "${rpid:--}" "$ra"

# queue depth
"$HERE/queue.sh" depth

# delivery-path staleness: anything pending on the queue, or stranded in
# .inflight by a relay crash, that nobody has drained for too long.
shopt -s nullglob
delivery=("$COORD_ROOT"/queue/*.ping "$COORD_ROOT"/queue/.inflight/*.ping)
if [ "$ra" = 0 ] && [ "${#delivery[@]}" -gt 0 ]; then
  printf '!!! FAIL relay: %s event(s) waiting with no live relay; inspect %s/relay.log and restart relay.sh\n' "${#delivery[@]}" "$COORD_ROOT"
  stale=1
fi
delivery_stale=0
for f in "$COORD_ROOT"/queue/*.ping "$COORD_ROOT"/queue/.inflight/*.ping; do
  [ -e "$f" ] || continue
  mt="$(stat -c %Y "$f" 2>/dev/null || echo "$now")"
  d=$(( now - mt ))
  if [ "$d" -ge "$stale_secs" ]; then
    printf 'STALE batch=%s age=%s\n' "$f" "$(age_min "$mt")"
    stale=1
    delivery_stale=1
  fi
done
if [ "$delivery_stale" = 0 ]; then printf 'STALE none\n'; fi

# ledger + live role logs. state.sh list is tab-separated; re-delimit on a
# non-whitespace separator so empty fields (verdict) are not collapsed by read.
while IFS=$'\037' read -r id status pid verdict goal; do
  [ -n "$id" ] || continue
  if alive "$pid"; then a=1; else a=0; fi
  printf 'SLICE %s %s pid=%s alive=%s verdict=%s goal=%s\n' \
    "$id" "$status" "${pid:--}" "$a" "${verdict:--}" "$goal"

  # A supervised process may finish normally before the coordinator consumes
  # its event. Its exit record distinguishes that wait from a vanished worker.
  role_result=""
  if [ -n "$pid" ] && [ -f "$COORD_ROOT/progress.log" ]; then
    role_result="$(awk -v pid="$pid" '
      index($0, " pid=" pid " step=role ") {
        if ($2 == "START" && / phase=validate /) result=""
        if (/ exit=[0-9]+ /) result=$2
      }
      END { print result }
    ' "$COORD_ROOT/progress.log")"
  fi

  # sibling signal: a dispatched slice whose pid is dead, or whose worktree
  # markers show no event for COORD_STALE_MIN minutes.
  if [ "$status" = "dispatched" ] || { [ "$status" = reviewing ] && [ -z "$verdict" ]; }; then
    if [ "$role_result" = OK ]; then
      printf 'WAIT slice=%s process completed; coordinator must advance the ledger after handling its result\n' "$id"
    fi
    if [ "$role_result" = FAIL ]; then
      printf '!!! FAIL slice=%s supervised process failed; inspect role logs and progress below\n' "$id"
      stale=1
    elif [ "$a" = 0 ] && [ "$role_result" != OK ]; then
      printf 'SLICE-STALE %s age=%s\n' "$id" "$(slice_age "$id" || echo 0)"
      stale=1
      printf '!!! FAIL slice=%s process is gone; check completion delivery and role logs below\n' "$id"
    else
      s_age="$(slice_age "$id" || true)"
      if [ -n "$s_age" ] && [ "$s_age" -ge "$STALE_MIN" ]; then
        printf 'SLICE-STALE %s age=%s\n' "$id" "$s_age"
        stale=1
      fi
    fi
  fi

  case "$status:$verdict" in
    reviewing:pass)
      if [ -f "$COORD_ROOT/approvals/$id" ]; then
        printf 'NEXT slice=%s approval recorded; coordinator must run merge.sh --slice %s\n' "$id" "$id"
      else
        printf 'WAIT slice=%s PASS recorded; awaiting merge approval (coord.sh approve %s)\n' "$id" "$id"
      fi
      ;;
    handback:*) printf 'NEXT slice=%s critic requested corrections; coordinator must dispatch a correction round\n' "$id" ;;
    blocked:*) printf '!!! WAIT slice=%s blocked; coordinator must explain the blocker\n' "$id" ;;
  esac
  case "$status" in
    dispatched|reviewing) ;;
    *) continue ;;
  esac
  for role in worker critic; do
    f="$COORD_ROOT/log/$role.$id.log"
    [ -f "$f" ] || continue
    last="$(tail -n1 "$f" 2>/dev/null | tr -d '\r' | cut -c1-200)"
    if [ -n "$last" ]; then printf 'LOG %s %s %s\n' "$id" "$role" "$last"; fi
  done
done < <("$HERE/state.sh" list | awk -F'\t' '{ printf "%s\037%s\037%s\037%s\037%s\n", $1, $2, $3, $4, $5 }')

if [ -f "$COORD_ROOT/progress.log" ]; then
  printf 'PROGRESS recent=12 file=%s/progress.log\n' "$COORD_ROOT"
  tail -n 12 "$COORD_ROOT/progress.log"
  # Retain visibility even after a failure scrolls out of the recent tail.
  awk '/^\[COORD\] FAIL / { last=$0 } END { if (last != "") print "LAST-FAIL (history; may have been recovered): " last }' "$COORD_ROOT/progress.log"
fi
if [ "$stale" != 0 ]; then
  printf '!!! FAIL health check: delivery or slice needs attention; see diagnostics above\n'
  exit 1
fi
printf 'HEALTH OK: no liveness or staleness alarms; this does not verify task correctness\n'
