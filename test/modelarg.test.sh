#!/usr/bin/env bash
# The configured model reaches the launched harness; with none, the flag is
# dropped and the harness uses its default.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"
cat > "$TMP/bin/argv" <<'A'
#!/usr/bin/env bash
printf '%s\n' "${@:1:$#-1}" > "$FAKE_DIR/argv.$FILO_OWES"
A
chmod +x "$TMP/bin/argv"
printf 'harness.argv.bin=%s\nharness.argv.exec=argv|--model|__MODEL__|__PROMPT__\n' "$TMP/bin/argv" >> "$FILO_ENV_CONF"
printf 'lane.default.harness=argv\nlane.default.model=gpt-6-luna\ncritic.harness=argv\ncritic.model=\n' >> "$REPO/.filo/config.conf"

"$FILO" unit add m --kind chore --goal m >/dev/null
"$FILO" dispatch m --role worker --brief "$TMP/brief" >/dev/null
wait_for test -f "$FAKE_DIR/argv.m.r1.worker"
assert "$(paste -sd' ' "$FAKE_DIR/argv.m.r1.worker")" "--model gpt-6-luna"

FILO_EVENTS="$FILO_EVENTS" FILO_OWES=m.r1.worker "$FILO" finish --result done --summary x >/dev/null
"$FILO" dispatch m --role critic >/dev/null
wait_for test -f "$FAKE_DIR/argv.m.r1.critic"
assert "$(cat "$FAKE_DIR/argv.m.r1.critic")" ""

echo "  modelarg ok"
