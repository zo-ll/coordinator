#!/usr/bin/env bash
# End to end: a scripted coordinator that only follows each batch's NEXT
# and READY lines (auto-merge) drives the run until filo done. Units a and
# b (after a).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"
export BRIEF="$TMP/brief" TURNS="$TMP/turns"
printf 'autonomy=auto-merge\n' >> "$REPO/.filo/config.conf"

cat > "$TMP/bin/fake-coordinator" <<'C'
#!/usr/bin/env bash
batch="${1#WAKE batch=}"
echo "turn $batch" >> "$TURNS"
follow() { # the batch, then the output of every command it runs
  local l cmd argv ids id
  while IFS= read -r l; do
    case "$l" in
      "NEXT "*": filo "*) cmd=${l#*: filo }; read -ra argv <<< "$cmd"; follow <<< "$("$FILO" "${argv[@]}")" ;;
      "READY "*) ids=${l#READY }; for id in ${ids%%:*}; do "$FILO" dispatch "$id" --role worker --brief "$BRIEF"; done ;;
    esac
  done
}
follow < "$batch"
C
chmod +x "$TMP/bin/fake-coordinator"
export FILO_RESUME="fake-coordinator|__BATCH__" FILO_SESSION=s

"$FILO" unit add a --kind feature --goal "first" >/dev/null
"$FILO" unit add b --kind feature --goal "second" --deps a >/dev/null
# the boot turn: dispatch what is ready, then the relay drives every turn
for id in $("$FILO" unit next); do "$FILO" dispatch "$id" --role worker --brief "$BRIEF" >/dev/null; done
"$FILO" relay --interval 0.1 >"$TMP/relay.out" 2>&1 &
relay=$!
wait_for "$FILO" done
"$FILO" relay --stop >/dev/null; wait "$relay" || true

assert "$("$FILO" done)" "DONE units=2"
main="$(git -C "$REPO" show main:file.txt)"
has "$main" "change by a.r1.worker"
has "$main" "change by b.r1.worker"
assert "$(git -C "$REPO" log --format=%s main | grep -c '^\[filo\]')" "2"
# every step is in the log, in protocol order
steps="$("$FILO" log | awk '$2 !~ /^(claimed|acked|nacked)$/ {print $2, $3}' | paste -sd, -)"   # delivery bookkeeping aside
assert "$steps" "unit_added a,unit_added b,dispatched a,finished a,dispatched a,finished a,merged a,dispatched b,finished b,dispatched b,finished b,merged b"

echo "  flow ok"
