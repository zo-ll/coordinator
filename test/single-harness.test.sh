#!/usr/bin/env bash
# Single-harness loop: ONE binary serves every role. The same fake harness is
# the worker (exec) and the coordinator (resume); producer-severance is by
# process and starved input, not by harness.
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
export FAKE_LOG="$TMP/fake.log"
export FINISH="$HERE/../scripts/finish.sh"
mkdir -p "$COORD_HOME" "$(dirname "$COORD_CONFIG")"

cat > "$TMP/fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG"
if [ "${1:-}" = "resume" ]; then
  exit 0
fi
"$FINISH" --event s1 --role worker --result done --head - --summary "done"
EOF
chmod +x "$TMP/fake"
export PATH="$TMP:$PATH"

cat > "$COORD_ENV_CONF" <<EOF
current=fake
harness.fake.bin=$TMP/fake
harness.fake.exec=fake|__PROMPT__
harness.fake.resume=fake|resume|__SESSION__|__BATCH__
EOF
printf 'lane.default.harness=fake\nlane.default.model=\ncritic.harness=fake\ncritic.model=\nadapters=\n' > "$COORD_CONFIG"
printf 'sss-1\n' > "$TMP/repo/.coordinator/session"

WT="$TMP/wt"
mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'do it\nGOAL: g\nSCOPE: s\nACCEPTANCE: a\nVERIFY: v\n' > "$TMP/brief"

"$STATE" add s1 "slice" >/dev/null
"$SPAWN" --role worker --prompt "$TMP/brief" --worktree "$WT" --slice s1 >/dev/null

for _ in $(seq 1 50); do "$QUEUE" pending && break; sleep 0.1; done
"$QUEUE" pending || { echo "  worker never finished"; exit 1; }

# resume recipe + session come from env.conf / .coordinator/session; no env override
"$RELAY" --once --interval 0.2

grep -q '^resume sss-1 WAKE batch=' "$FAKE_LOG" || { echo "  resume not from same harness:"; cat "$FAKE_LOG"; exit 1; }
grep -q 'do it' "$FAKE_LOG" || { echo "  worker did not run"; exit 1; }
[ "$(ls "$COORD_ROOT/queue/.done" | wc -l)" = "1" ] || { echo "  event not acked"; exit 1; }

echo "  single-harness ok"
