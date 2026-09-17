#!/usr/bin/env bash
# Coordinator inbox relay: delivers ONE-LINE pings from sandboxed workers
# into the coordinator's conversation.
# - new-files-only, consumed once after delivery (no stale re-fires)
# - dedupes by event slug for this process lifetime (log: DUP)
#   so re-writing a ping with different wording cannot deliver it twice
# - COALESCES: waits for a quiet window, then types ALL pending events as ONE
#   line (log: DELIVER, "EVENTS n: a | b | c") so one coordinator turn drains a
#   whole wave instead of one turn per ping. A lone event flushes after the
#   same quiet window.
# - single line only (no multiline corruption)
# - guarded: only when the coordinator pane's foreground command is `pi`
# Usage: run DETACHED (recommended), e.g.
#   setsid nohup <this script> >/dev/null 2>&1 &   (pid -> /tmp/shipwright/relay.pid)
# or in a tmux window during debugging:
#   tmux new-window -d -t <session> -n relay -c /tmp/shipwright '<this script>'
# All activity is logged to $LOG (default /tmp/shipwright/relay.log).
# Overridable for testing: RELAY_INBOX, RELAY_LOG, RELAY_COORD_PANE,
# RELAY_LOCK, RELAY_COALESCE (quiet seconds), RELAY_INTERVAL (scan seconds).
INBOX="${RELAY_INBOX:-/tmp/shipwright/inbox}"
LOG="${RELAY_LOG:-/tmp/shipwright/relay.log}"
COORD_PANE="${RELAY_COORD_PANE:-personal:coordinator.0}"
COALESCE="${RELAY_COALESCE:-6}"
INTERVAL="${RELAY_INTERVAL:-1}"
LOCK="${RELAY_LOCK:-/tmp/shipwright/relay.lock}"
mkdir -p "$INBOX"
mkdir -p "$(dirname "$LOG")"
exec 9>"$LOCK"
if ! flock -n 9; then
  printf '%s\n' 'relay already running (lock held)' >&2
  exit 1
fi
CLAIMED="$INBOX/.claimed"
mkdir -p "$CLAIMED"
echo "[relay started $(date '+%Y-%m-%d %H:%M:%S')] watching $INBOX -> $COORD_PANE (coalesce ${COALESCE}s)"
echo "[relay started $(date '+%Y-%m-%d %H:%M:%S')] coalesce=${COALESCE}s interval=${INTERVAL}s" >> "$LOG"
shopt -s nullglob
deferred=""
prev=""
last_keys=""
delivered=""
pending_since=""
batch_typed=0
batch_keys=""
declare -A failures=()
while true; do
  # Arrival log: once per newly-seen file, regardless of guard outcome.
  cur="$(printf '%s\n' "$INBOX"/*.ping)"
  if [ "$cur" != "$prev" ]; then
    comm -13 <(printf '%s\n' "$prev") <(printf '%s\n' "$cur") 2>/dev/null \
      | while read -r nf; do
          [ -n "$nf" ] && [ -f "$nf" ] && printf '%s ARRIVE %-22s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(basename "$nf" .ping)" | tee -a "$LOG"
        done
    prev="$cur"
  fi
  # Claim: atomic rename inbox -> .claimed, never overwriting a live claim.
  for f in "$INBOX"/*.ping; do
    [ -f "$f" ] || continue
    claimed="$CLAIMED/$(basename "$f")"
    [ ! -e "$claimed" ] || continue
    mv -T -- "$f" "$claimed" 2>/dev/null || continue
  done
  # Drop already-delivered slugs (dedupe by event identity, process lifetime).
  for f in "$CLAIMED"/*.ping; do
    [ -f "$f" ] || continue
    key="$(basename "$f" .ping)"
    if printf '%s\n' "$delivered" | grep -Fqx -- "$key"; then
      printf '%s DUP    %-22s :: dropped (already delivered)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$key" | tee -a "$LOG"
      rm -f "$f"
    fi
  done
  # Gather deliverable slugs (auto-attempts disabled after 3 failures).
  keys=""
  for f in "$CLAIMED"/*.ping; do
    [ -f "$f" ] || continue
    key="$(basename "$f" .ping)"
    [ "${failures[$key]:-0}" -lt 3 ] || continue
    keys="$keys $key"
  done
  keys="${keys# }"
  # An in-flight batch (text typed, Enter pending) owns delivery exclusively.
  if [ "$batch_typed" = 1 ]; then
    keys="$batch_keys"
  elif [ "$keys" != "$last_keys" ]; then
    pending_since="$(date +%s)"   # reset quiet window whenever the set changes
    last_keys="$keys"
  fi
  if [ -z "$keys" ]; then
    pending_since=""
    sleep "$INTERVAL" 9>&-
    continue
  fi
  if [ "$batch_typed" = 1 ]; then
    alive=0
    for key in $batch_keys; do [ "${failures[$key]:-0}" -lt 3 ] && alive=1; done
    if [ "$alive" = 0 ]; then
      sleep "$INTERVAL" 9>&-    # Enter retries exhausted: retain claims, wait
      continue
    fi
  else
    now="$(date +%s)"
    [ -n "$pending_since" ] && [ $(( now - pending_since )) -ge "$COALESCE" ] || {
      sleep "$INTERVAL" 9>&-
      continue
    }
  fi
  cmd="$(tmux display-message -p -t "$COORD_PANE" '#{pane_current_command}' 2>/dev/null || true)"
  mode="$(tmux display-message -p -t "$COORD_PANE" '#{pane_in_mode}' 2>/dev/null || true)"
  if [ "$cmd" != "pi" ] || [ "$mode" != "0" ]; then
    for key in $keys; do
      name="$key.ping"
      case "$deferred" in
        *"$name"*) ;;
        *) printf '%s DEFER  %-22s :: cmd=%s mode=%s (left for retry)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$name" "$cmd" "$mode" | tee -a "$LOG"
           deferred="$deferred $name";;
      esac
    done
    sleep "$INTERVAL" 9>&-
    continue
  fi
  # Build the batch line from each claim's first line.
  if [ "$batch_typed" = 0 ]; then
    content=""
    n=0
    for key in $keys; do
      line="$(head -n 1 "$CLAIMED/$key.ping" | tr -d '\r')"
      [ -n "$line" ] || continue
      if [ -z "$content" ]; then content="$line"; else content="$content | $line"; fi
      n=$(( n + 1 ))
    done
    if [ -z "$content" ]; then
      for key in $keys; do rm -f "$CLAIMED/$key.ping"; done
      pending_since=""
      sleep "$INTERVAL" 9>&-
      continue
    fi
    [ "$n" -gt 1 ] && content="EVENTS $n: $content"
    batch_keys="$keys"
  else
    content=""
  fi
  sent=false
  stage=text
  if [ "$batch_typed" = 1 ] || tmux send-keys -t "$COORD_PANE" -l "$content" 2>/dev/null; then
    batch_typed=1
    stage=Enter
    if tmux send-keys -t "$COORD_PANE" Enter 2>/dev/null; then
      sent=true
    fi
  fi
  if [ "$sent" = true ]; then
    printf '%s DELIVER %-22s :: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(printf '%s' "$batch_keys" | tr ' ' ',')" "$content" | tee -a "$LOG"
    for key in $batch_keys; do
      rm -f "$CLAIMED/$key.ping"
      delivered="$(printf '%s\n%s' "$delivered" "$key")"
      unset 'failures[$key]'
      deferred="${deferred//"$key.ping"/}"
    done
    batch_typed=0
    batch_keys=""
    last_keys=""
    pending_since=""
  else
    for key in $keys; do
      failures[$key]=$(( ${failures[$key]:-0} + 1 ))
      outcome=RETRY
      [ "${failures[$key]}" -lt 3 ] || outcome=FAILED
      printf '%s %-7s %-22s :: stage=%s attempt=%s/3 (claim retained)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$outcome" "$key" "$stage" "${failures[$key]}" | tee -a "$LOG"
    done
    sleep 1 9>&-
  fi
  sleep "$INTERVAL" 9>&-
done
