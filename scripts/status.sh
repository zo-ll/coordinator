#!/usr/bin/env bash
# One-command view of a run: the ledger, queue depth, live pids, and the tail of
# every active role log. Read-only — it composes state.sh/queue.sh and never
# touches the ledger itself. This is the sanctioned way to observe progress;
# roles must never be tailed by hand.
#
#   status.sh
#     -> STATUS relay=<pid|-> alive=<0|1>
#        QUEUE pending=<n> inflight=<n> done=<n>
#        SLICE <id> <status> pid=<pid|-> alive=<0|1> verdict=<v|-> goal=<...>
#        LOG <id> <role> <last non-empty line>   (live slices only, truncated)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/queue.sh"

alive() { [ -n "$1" ] && [ "$1" != "-" ] && kill -0 "$1" 2>/dev/null; }

# relay
rpid=""
[ -f "$COORD_ROOT/relay.pid" ] && rpid="$(cat "$COORD_ROOT/relay.pid" 2>/dev/null || true)"
alive "$rpid" && ra=1 || ra=0
printf 'STATUS relay=%s alive=%s\n' "${rpid:--}" "$ra"

# queue depth
"$HERE/queue.sh" depth

# ledger + live role logs. state.sh list is tab-separated; re-delimit on a
# non-whitespace separator so empty fields (verdict) are not collapsed by read.
while IFS=$'\037' read -r id status pid verdict goal; do
  [ -n "$id" ] || continue
  alive "$pid" && a=1 || a=0
  printf 'SLICE %s %s pid=%s alive=%s verdict=%s goal=%s\n' \
    "$id" "$status" "${pid:--}" "$a" "${verdict:--}" "$goal"

  [ "$a" = 1 ] || continue
  case "$status" in
    dispatched|reviewing) ;;
    *) continue ;;
  esac
  for role in worker critic; do
    f="$COORD_ROOT/log/$role.$id.log"
    [ -f "$f" ] || continue
    last="$(tail -n1 "$f" 2>/dev/null | tr -d '\r' | cut -c1-200)"
    [ -n "$last" ] && printf 'LOG %s %s %s\n' "$id" "$role" "$last"
  done
done < <("$HERE/state.sh" list | awk -F'\t' '{ printf "%s\037%s\037%s\037%s\037%s\n", $1, $2, $3, $4, $5 }')
