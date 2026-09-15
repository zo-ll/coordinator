#!/usr/bin/env bash
# Serial queue consumer: the only thing that turns workers' pings into a
# coordinator turn. No daemon framework, no tmux, no polling of a live session.
#
#   relay.sh [--once] [--interval N] [--max-attempts N] [--backoff N]
#
# Loop: wait for the queue to be non-empty; claim every pending event, in order,
# into one batch file; resume the coordinator with a one-line pointer to it; wait
# for the turn to exit; ack the batch. One turn at a time.
#
# Delivery is bounded: a failed resume is retried with exponential backoff up to
# --max-attempts. On exhaustion the batch is returned to the queue and the relay
# exits nonzero — one clear line, never a silent spin. Fix the resume recipe and
# restart the relay to drain what was returned.
#
# Delivery is at-least-once: if the relay crashes after claiming a batch, the
# events are stranded in .inflight; on restart, while holding the single-relay
# lock, the stranded events are requeued and redelivered. Actions must survive
# redelivery (see the coordinator rule: never re-spawn a critic for a slice
# already under review).
#
# The wake pointer never phrases an open yes/no question (a resumed turn must
# not be able to answer its own "should I merge?"): it tells the coordinator
# to surface any pending merge decision for the human and end the turn.
# Approval is recorded only by a human running `coord.sh approve <id>`.
# Exception: when config autonomy=auto-merge (unattended/test runs) the wake
# tells the coordinator to merge directly instead — no approval round-trip.
#
# Exactly one relay per COORD_ROOT: a non-blocking flock guards the loop, and a
# fresh relay.pid is written (self-cleaned on exit) so a stale pid cannot point
# at a dead process.
#
# The resume command is config data (never eval'd):
#   $COORD_CONFIG (default <cwd>/.coordinator/config.conf) keys:
#     relay.resume   '|'-separated argv template with __SESSION__, __BATCH__
#                    and __SERVER__ (the latter from $COORD_OPENCODE_SERVER,
#                    used by opencode's attach-based wake)
#     relay.session  session id/name to resume
# Overrides: COORD_RESUME, COORD_SESSION.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/queue.sh"
source "$HERE/progress.sh"
progress_start relay
progress_note="delivery stopped; inspect relay.log and run status.sh"
QUEUE="$HERE/queue.sh"

once=0
interval="${RELAY_INTERVAL:-1}"
max_attempts="${RELAY_MAX_ATTEMPTS:-5}"
backoff="${RELAY_BACKOFF:-2}"
while [ $# -gt 0 ]; do
  case "$1" in
    --once)         once=1; shift ;;
    --interval)     interval="$2"; shift 2 ;;
    --max-attempts) max_attempts="$2"; shift 2 ;;
    --backoff)      backoff="$2"; shift 2 ;;
    *) echo "relay.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

cfg_get() { "$HERE/cfg.sh" get "$1" "$2" 2>/dev/null || true; }

resume_recipe() {
  [ -n "${COORD_RESUME:-}" ] && { printf '%s' "$COORD_RESUME"; return 0; }
  local file="${COORD_CONFIG:-$PWD/.coordinator/config.conf}"
  local v; v="$(cfg_get "$file" relay.resume)"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  local envconf="${COORD_ENV_CONF:-${COORD_HOME:-$HOME/.coordinator}/env.conf}"
  local cur; cur="$(cfg_get "$envconf" current)"
  [ -n "$cur" ] && cfg_get "$envconf" "harness.$cur.resume"
}

normalize_id() { # strip a rollout- prefix / leading ISO timestamp (codex rollouts)
  local id="$1"
  id="${id#rollout-}"
  printf '%s' "$id" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-//'
}

session_id() {
  [ -n "${COORD_SESSION:-}" ] && { normalize_id "$COORD_SESSION"; return 0; }
  local file="${COORD_CONFIG:-$PWD/.coordinator/config.conf}"
  local v; v="$(cfg_get "$file" relay.session)"
  [ -n "$v" ] && { normalize_id "$v"; return 0; }
  local dir; dir="$(dirname "$file")"
  [ -f "$dir/session" ] && { normalize_id "$(cat "$dir/session")"; return 0; }
  [ -f "$PWD/.coordinator/session" ] && normalize_id "$(cat "$PWD/.coordinator/session")"
}

resume() { # pointer
  local pointer="$1" recipe session i argv
  recipe="$(resume_recipe)"
  [ -n "$recipe" ] || {
    echo "relay: no relay.resume recipe (set COORD_RESUME, config, or env.conf)" >&2
    return 1
  }
  session="$(session_id)"
  local server="${COORD_OPENCODE_SERVER:-}"
  IFS='|' read -r -a argv <<< "$recipe"
  for i in "${!argv[@]}"; do
    argv[$i]="${argv[$i]//__BATCH__/$pointer}"
    argv[$i]="${argv[$i]//__SESSION__/$session}"
    argv[$i]="${argv[$i]//__SERVER__/$server}"
  done
  # Capture the wake command's output: for headless-turn harnesses (claude,
  # opencode) this is the coordinator's visible narration. Without it the user
  # sees an idle TUI; with it, status/watch can tail the coordinator's voice.
  # The resume exit code still gates retry/ack.
  local log="$COORD_ROOT/turn.log" rc=0
  {
    printf '\n=== turn %s batch=%s ===\n%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(basename "$pointer")" "$wake"
    "${argv[@]}"
  } >> "$log" 2>&1 || rc=$?
  return "$rc"
}

mkdir -p "$COORD_ROOT" "$COORD_ROOT/batch"

# single relay: hold the lock for the process lifetime
exec 8>"$COORD_ROOT/relay.lock"
if ! flock -n 8; then
  echo "relay: another relay already holds $COORD_ROOT/relay.lock; refusing to run two" >&2
  exit 1
fi
printf '%s\n' "$$" > "$COORD_ROOT/relay.pid"
progress_cleanup() { rm -f "$COORD_ROOT/relay.pid"; }
progress_event OK "relay lock acquired; pid=$$ root=$COORD_ROOT"

# reclaim events stranded by a previous relay crash: the lock guarantees no
# other consumer exists, so anything in .inflight is ours to requeue.
"$QUEUE" nack
progress_event OK "recovery complete; stranded events returned to pending queue"

deliver() { # batch: retry resume with backoff, ack on success, give up loudly
  local batch="$1" attempt=0 wait="$backoff" autonomy wake
  autonomy="$(cfg_get "${COORD_CONFIG:-$PWD/.coordinator/config.conf}" autonomy 2>/dev/null || true)"
  if [ "$autonomy" = "auto-merge" ]; then
    # test/unattended runs: merges are pre-authorized by config, so never tell
    # the coordinator to stop and ask
    wake="WAKE batch=$batch — route each event and merge passed slices directly: this run is configured autonomy=auto-merge, so no human approval is required."
  else
    wake="WAKE batch=$batch — route each event; if a merge decision is due, do not decide it yourself: surface it for the human and end the turn. Approval can only come from a human running 'coord.sh approve <id>' in their own terminal — never from inside this turn."
  fi
  while :; do
    attempt=$(( attempt + 1 ))
    progress_phase wake "batch=$batch attempt=$attempt/$max_attempts; invoking configured wake command"
    if resume "$wake"; then
      progress_event OK "wake command returned exit=0 batch=$batch; this alone does not prove coordinator routing completed"
      progress_phase acknowledge "batch=$batch; acknowledging under the configured wake-command contract"
      "$QUEUE" ack
      progress_event OK "batch=$batch queue acknowledged; check slice state for routing results"
      return 0
    fi
    if [ "$attempt" -ge "$max_attempts" ]; then
      "$QUEUE" nack
      progress_event FAIL "batch=$batch wake failed $max_attempts times; events returned to queue; fix wake command and restart relay"
      echo "relay: resume failed $max_attempts times for $batch; returned the events to the queue and stopped (fix the resume recipe, then restart the relay)" >&2
      return 1
    fi
    echo "relay: resume failed (attempt $attempt/$max_attempts), retrying in ${wait}s" >&2
    progress_event WARN "batch=$batch wake failed attempt=$attempt/$max_attempts; retry in ${wait}s"
    sleep "$wait"
    wait=$(( wait * 2 ))
    [ "$wait" -le 60 ] || wait=60
  done
}

waiting=0
while :; do
  if "$QUEUE" pending; then
    waiting=0
    batch="$COORD_ROOT/batch/$(date +%s%N).$$.txt"
    progress_phase claim "batch=$batch"
    if claimed="$("$QUEUE" pop-batch "$batch")"; then
      progress_event OK "$claimed"
      deliver "$batch" || exit 1
      if [ "$once" = 1 ]; then progress_note="one batch delivered; relay stopped as requested by --once"; exit 0; fi
    fi
  else
    if [ "$waiting" = 0 ]; then
      progress_stage=queue
      progress_event WAIT "queue empty; waiting for worker completion or a user event"
      waiting=1
    fi
    sleep "$interval"
  fi
done
