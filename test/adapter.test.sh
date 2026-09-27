#!/usr/bin/env bash
# spawn.sh adapter hook: an enabled adapter controls the launch and its pid.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN="$HERE/../scripts/spawn.sh"
STATE="$HERE/../scripts/state.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export COORD_HOME="$TMP/coord"
export COORD_ENV_CONF="$TMP/coord/env.conf"
export COORD_CONFIG="$TMP/repo/.coordinator/config.conf"
export COORD_ROOT="$TMP/coord"
export COORD_EVENTS="$TMP/repo/.coordinator/events.jsonl"
export COORD_AGENTS="$TMP/no-agents"
export COORD_ADAPTERS="$TMP/adapters"
export ADAPTER_LOG="$TMP/adapter.log"
mkdir -p "$COORD_HOME" "$(dirname "$COORD_CONFIG")" "$COORD_ADAPTERS"

cat > "$TMP/fake" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/fake"
export PATH="$TMP:$PATH"

# fake adapter that records the launch and returns a fixed pid
cat > "$COORD_ADAPTERS/foo.sh" <<'EOF'
adapter_launch() {
  local cwd="$1" log="$2"
  shift 2
  printf 'cwd=%s log=%s argv=%s\n' "$cwd" "$log" "$*" >> "$ADAPTER_LOG"
  printf '4242'
}
EOF

printf 'harness.fake.exec=fake|__PROMPT__\nharness.fake.bin=%s\n' "$TMP/fake" > "$COORD_ENV_CONF"
printf 'lane.default.harness=fake\nlane.default.model=\nadapters=foo\n' > "$COORD_CONFIG"

WT="$TMP/wt"; mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'do it\nGOAL: g\nSCOPE: s\nACCEPTANCE: a\nVERIFY: v\n' > "$TMP/brief"

"$STATE" add s1 "slice" >/dev/null
"$SPAWN" --role worker --prompt "$TMP/brief" --worktree "$WT" --slice s1 >/dev/null

[ "$("$STATE" get s1 pid)" = "4242" ] || { echo "  adapter pid not used"; exit 1; }
grep -q "cwd=$WT" "$ADAPTER_LOG" || { echo "  adapter not invoked"; cat "$ADAPTER_LOG"; exit 1; }

echo "  adapter ok"
