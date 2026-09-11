#!/usr/bin/env bash
# spawn.sh: launches the configured harness in the worktree and records dispatch.
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
export COORD_LEDGER="$TMP/repo/.coordinator/ledger.tsv"
export COORD_AGENTS="$TMP/no-agents"
export FAKE_LOG="$TMP/fake.log"
mkdir -p "$COORD_HOME" "$(dirname "$COORD_CONFIG")"

cat > "$TMP/fake" <<'EOF'
#!/usr/bin/env bash
{ echo "cwd=$(pwd)"; for a in "$@"; do echo "arg=$a"; done; } >> "$FAKE_LOG"
EOF
chmod +x "$TMP/fake"
export PATH="$TMP:$PATH"

printf 'harness.fake.exec=fake|__CWD__|__PROMPT__\nharness.fake.bin=%s\n' "$TMP/fake" > "$COORD_ENV_CONF"
printf 'lane.default.harness=fake\nlane.default.model=\n' > "$COORD_CONFIG"

WT="$TMP/wt"
mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'do the thing\n' > "$TMP/brief"

"$STATE" add s1 "a slice" >/dev/null

# a missing brief fails loudly before anything launches
if "$SPAWN" --role worker --prompt "$TMP/nope" --worktree "$WT" --slice s1 2>"$TMP/err"; then
  echo "  missing prompt allowed"; exit 1
fi
grep -q "prompt file not readable" "$TMP/err" || { echo "  unclear error:"; cat "$TMP/err"; exit 1; }
[ ! -f "$FAKE_LOG" ] || { echo "  launched with a missing brief"; exit 1; }

out="$("$SPAWN" --role worker --prompt "$TMP/brief" --worktree "$WT" --slice s1)"
case "$out" in
  SPAWN\ worker\ slice=s1\ pid=*) ;;
  *) echo "  bad output: $out"; exit 1 ;;
esac

for _ in $(seq 1 50); do [ -f "$FAKE_LOG" ] && break; sleep 0.1; done
[ -f "$FAKE_LOG" ] || { echo "  fake harness never ran"; exit 1; }
grep -q "cwd=$WT" "$FAKE_LOG" || { echo "  wrong cwd:"; cat "$FAKE_LOG"; exit 1; }
grep -q "arg=do the thing" "$FAKE_LOG" || { echo "  brief missing:"; cat "$FAKE_LOG"; exit 1; }

# the finish contract is appended mechanically, not left to the brief
for _ in $(seq 1 50); do grep -q 'FINISH CONTRACT' "$FAKE_LOG" && break; sleep 0.1; done
grep -q -- '--event s1 --role worker --result done --head -' "$FAKE_LOG" || {
  echo "  finish contract missing:"; cat "$FAKE_LOG"; exit 1; }

[ "$("$STATE" get s1 status)" = "dispatched" ] || { echo "  s1 not dispatched"; exit 1; }
[ -n "$("$STATE" get s1 pid)" ] || { echo "  pid not recorded"; exit 1; }
[ -n "$("$STATE" get s1 branch)" ] || { echo "  branch not recorded"; exit 1; }

echo "  spawn ok"
