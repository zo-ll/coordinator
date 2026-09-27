#!/usr/bin/env bash
# End to end: a scripted coordinator follows the SKILL routing on every batch
# the relay delivers — worker done -> critic, critic pass -> merge (auto-merge),
# then dispatch whatever is ready — until coord done. Units a and b (after a).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"
export BRIEF="$TMP/brief" TURNS="$TMP/turns"
printf 'autonomy=auto-merge\n' >> "$REPO/.coordinator/config.conf"

cat > "$TMP/bin/fake-coordinator" <<'C'
#!/usr/bin/env bash
batch="${1#WAKE batch=}"
echo "turn $batch" >> "$TURNS"
while read -r tag seq unit type slug result rest; do
  [ "$tag" = EVENT ] || continue
  case "$type:$slug:$result" in
    finished:*.worker:done) "$COORD" dispatch "$unit" --role critic ;;
    finished:*.critic:pass) "$COORD" merge "$unit" ;;
  esac
done < "$batch"
for id in $("$COORD" unit next); do "$COORD" dispatch "$id" --role worker --brief "$BRIEF"; done
C
chmod +x "$TMP/bin/fake-coordinator"
export COORD_RESUME="fake-coordinator|__BATCH__" COORD_SESSION=s

"$COORD" unit add a --kind feature --goal "first" >/dev/null
"$COORD" unit add b --kind feature --goal "second" --deps a >/dev/null
# the boot turn: dispatch what is ready, then the relay drives every turn
for id in $("$COORD" unit next); do "$COORD" dispatch "$id" --role worker --brief "$BRIEF" >/dev/null; done
"$COORD" relay --interval 0.1 >"$TMP/relay.out" 2>&1 &
relay=$!
wait_for "$COORD" done
kill "$relay"

assert "$("$COORD" done)" "DONE units=2"
main="$(git -C "$REPO" show main:file.txt)"
has "$main" "change by a.r1.worker"
has "$main" "change by b.r1.worker"
assert "$(git -C "$REPO" log --format=%s main | grep -c '^\[coord\]')" "2"
# every step is in the log, in protocol order
steps="$("$COORD" log | awk '$2 != "claimed" && $2 != "acked" {print $2, $3}' | paste -sd, -)"
assert "$steps" "unit_added a,unit_added b,dispatched a,finished a,dispatched a,finished a,merged a,dispatched b,finished b,dispatched b,finished b,merged b"

echo "  flow ok"
