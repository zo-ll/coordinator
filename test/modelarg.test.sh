#!/usr/bin/env bash
# The configured model reaches the launched harness; with none, the flag is
# dropped and the harness uses its default.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"
cat > "$TMP/bin/argv" <<'A'
#!/usr/bin/env bash
printf '%s\n' "${@:1:$#-1}" > "$FAKE_DIR/argv.$COORD_OWES"
A
chmod +x "$TMP/bin/argv"
printf 'harness.argv.bin=%s\nharness.argv.exec=argv|--model|__MODEL__|__PROMPT__\n' "$TMP/bin/argv" >> "$COORD_ENV_CONF"
printf 'lane.default.harness=argv\nlane.default.model=gpt-6-luna\ncritic.harness=argv\ncritic.model=\n' >> "$REPO/.coordinator/config.conf"

"$COORD" unit add m --kind chore --goal m >/dev/null
"$COORD" dispatch m --role worker --brief "$TMP/brief" >/dev/null
wait_for test -f "$FAKE_DIR/argv.m.r1.worker"
assert "$(paste -sd' ' "$FAKE_DIR/argv.m.r1.worker")" "--model gpt-6-luna"

COORD_EVENTS="$COORD_EVENTS" COORD_OWES=m.r1.worker "$COORD" finish --result done --summary x >/dev/null
"$COORD" dispatch m --role critic >/dev/null
wait_for test -f "$FAKE_DIR/argv.m.r1.critic"
assert "$(cat "$FAKE_DIR/argv.m.r1.critic")" ""

echo "  modelarg ok"
