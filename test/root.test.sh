#!/usr/bin/env bash
# Default runtime roots are shared by scripts, but isolated by repository.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../scripts"
TMP="$(mktemp -d)"
roots=()
pids=()
cleanup() {
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; done
  for root in "${roots[@]}"; do rm -rf "$root"; done
  rm -rf "$TMP"
}
trap cleanup EXIT
assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }
export COORD_LEDGER="$TMP/ledger.tsv"
export COORD_DASHBOARD="$TMP/dashboard.md"
unset COORD_ROOT

# Same basename, different parent directories (including spaces).
for name in 'one repo' 'two repo'; do
  export COORD_REPO="$TMP/$name/project"
  root="$(source "$S/queue.sh"; printf '%s' "$COORD_ROOT")"
  roots+=("$root")
  case "$root" in /tmp/coordinator/*) ;; *) echo '  wrong default root'; exit 1;; esac
  case "${root##*/}" in *' '*) echo '  unsanitized slug'; exit 1;; esac
  assert "$([ -d "$root" ] && echo exists || echo absent)" absent
  "$S/queue.sh" enqueue same 'DONE same: done' >/dev/null
  [ -f "$root/queue/000000000001.same.ping" ]
  "$S/queue.sh" pop-batch "$TMP/claimed" >/dev/null
  "$S/queue.sh" ack
  "$S/relay.sh" --interval 0.05 >"$TMP/relay-${#roots[@]}.log" 2>&1 &
  pid=$!
  pids+=("$pid")
  for ((i=0; i<100; i++)); do
    [ -s "$root/relay.pid" ] && break
    sleep 0.02
  done
  assert "$(cat "$root/relay.pid")" "$pid"
  out="$("$S/status.sh")"
  assert "$(printf '%s\n' "$out" | head -n1)" "STATUS relay=$pid alive=1"
  assert "$(printf '%s\n' "$out" | sed -n 2p)" 'QUEUE pending=0 inflight=0 done=1'
done
[ "${roots[0]}" != "${roots[1]}" ]
[ -d "${roots[0]}/batch" ] && [ -d "${roots[1]}/batch" ]

# PWD fallback and a verbatim override, including spaces and trailing slash.
unset COORD_REPO
assert "$(cd "$TMP"; source "$S/queue.sh"; printf '%s' "$COORD_ROOT")" \
  "$(COORD_REPO="$TMP"; source "$S/queue.sh"; printf '%s' "$COORD_ROOT")"
export COORD_ROOT="$TMP/explicit root/"
assert "$(source "$S/queue.sh"; printf '%s' "$COORD_ROOT")" "$TMP/explicit root/"
"$S/queue.sh" enqueue override 'DONE override: done' >/dev/null
[ -f "$COORD_ROOT/queue/000000000001.override.ping" ]
printf '%s\n' "$$" > "$COORD_ROOT/relay.pid"
assert "$("$S/status.sh" | sed -n '1p')" "STATUS relay=$$ alive=1"
COORD_RESUME=true COORD_SESSION=test "$S/relay.sh" --once
assert "$("$S/queue.sh" depth)" 'QUEUE pending=0 inflight=0 done=1'

# Only the shared initializer defines the default; no old global fallback.
if grep -F '/tmp/coordinator' "$S/queue.sh" "$S/relay.sh" "$S/coord.sh" "$S/status.sh"; then
  echo '  hardcoded global runtime root'; exit 1
fi
echo '  root ok'
