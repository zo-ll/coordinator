#!/usr/bin/env bash
# End to end: dispatch a fake worker that finishes, then relay delivers it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN="$HERE/../scripts/spawn.sh"
STATE="$HERE/../scripts/state.sh"
QUEUE="$HERE/../scripts/queue.sh"
RELAY="$HERE/../scripts/relay.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export COORD_HOME="$TMP/coord"
export COORD_ENV_CONF="$TMP/coord/env.conf"
export COORD_CONFIG="$TMP/repo/.coordinator/config.conf"
export COORD_ROOT="$TMP/coord"
export COORD_LEDGER="$TMP/repo/.coordinator/ledger.tsv"
export COORD_AGENTS="$TMP/no-agents"
export RELAY_LOG="$TMP/resume.log"
export FINISH="$HERE/../scripts/finish.sh"
mkdir -p "$COORD_HOME" "$(dirname "$COORD_CONFIG")"

# fake worker: on launch, finishes slice s1
cat > "$TMP/fake-worker" <<'EOF'
#!/usr/bin/env bash
"$FINISH" --event s1 --role worker --result done --head - --summary "done by fake"
EOF
chmod +x "$TMP/fake-worker"
export PATH="$TMP:$PATH"

# fake coordinator resume: record the batch pointer
cat > "$TMP/fake-resume" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RELAY_LOG"
EOF
chmod +x "$TMP/fake-resume"

printf 'harness.fake.exec=fake-worker|__PROMPT__\nharness.fake.bin=%s\n' "$TMP/fake-worker" > "$COORD_ENV_CONF"
printf 'lane.default.harness=fake\nlane.default.model=\n' > "$COORD_CONFIG"

WT="$TMP/wt"
mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'do the thing\n' > "$TMP/brief"

"$STATE" add s1 "the slice" >/dev/null
"$SPAWN" --role worker --prompt "$TMP/brief" --worktree "$WT" --slice s1 >/dev/null

# wait for the worker to enqueue its finish
for _ in $(seq 1 50); do "$QUEUE" pending && break; sleep 0.1; done
"$QUEUE" pending || { echo "  worker never finished"; exit 1; }

COORD_RESUME="$TMP/fake-resume|__SESSION__|__BATCH__" COORD_SESSION="sess-x" "$RELAY" --once --interval 0.2

[ "$(wc -l < "$RELAY_LOG" | tr -d ' ')" = "1" ] || { echo "  expected one resume"; exit 1; }
[ "$(ls "$COORD_ROOT/queue/.done" | wc -l)" = "1" ] || { echo "  event not acked"; exit 1; }
[ "$("$STATE" get s1 status)" = "dispatched" ] || { echo "  ledger wrong"; exit 1; }

echo "  flow ok"
