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
printf 'do the thing\nGOAL: g\nSCOPE: s\nACCEPTANCE: a\nVERIFY: v\n' > "$TMP/brief"

"$STATE" add s1 "a slice" >/dev/null

# a worker/critic without --slice refuses loudly (finish contract + ledger)
if "$SPAWN" --role critic --prompt "$TMP/brief" --worktree "$WT" >/dev/null 2>"$TMP/err"; then
  echo "  critic without --slice allowed"; exit 1
fi
grep -q -- '--slice is required' "$TMP/err" || { echo "  unclear slice error:"; cat "$TMP/err"; exit 1; }

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
# the ledger records the finish slug this launch owes (the relay's DIED check)
[ "$("$STATE" get s1 task)" = "s1" ] || { echo "  task not the owed slug"; exit 1; }

wait_log() { for _ in $(seq 1 50); do grep -q "$1" "$2" 2>/dev/null && return 0; sleep 0.1; done; return 1; }

# --- brief validation: a worker brief without its fields never launches
rm -f "$FAKE_LOG"
printf 'GOAL: g\nSCOPE: s\n' > "$TMP/thin"
if "$SPAWN" --role worker --prompt "$TMP/thin" --worktree "$WT" --slice s1 >/dev/null 2>"$TMP/err"; then
  echo "  thin brief allowed"; exit 1
fi
grep -q 'brief missing ACCEPTANCE VERIFY' "$TMP/err" || { echo "  unclear brief error:"; cat "$TMP/err"; exit 1; }
sleep 0.2
[ ! -f "$FAKE_LOG" ] || { echo "  launched with a thin brief"; exit 1; }
# a header mid-line does not count
printf 'GOAL: g\nSCOPE: s\nVERIFY: v\nnote ACCEPTANCE: later\n' > "$TMP/thin"
"$SPAWN" --role worker --prompt "$TMP/thin" --worktree "$WT" --slice s1 >/dev/null 2>&1 && {
  echo "  mid-line header accepted"; exit 1; }
# a critic needs only ACCEPTANCE
printf 'review it\n' > "$TMP/cbrief"
"$SPAWN" --role critic --prompt "$TMP/cbrief" --worktree "$WT" --slice s1 >/dev/null 2>&1 && {
  echo "  critic without ACCEPTANCE allowed"; exit 1; }

# --- standing orders ride on every launch, before the finish contract
printf '1. never touch vendor/\n' > "$(dirname "$COORD_CONFIG")/standing.md"
rm -f "$FAKE_LOG"
"$SPAWN" --role worker --prompt "$TMP/brief" --worktree "$WT" --slice s1 >/dev/null
wait_log 'FINISH CONTRACT' "$FAKE_LOG" || { echo "  worker never ran"; exit 1; }
grep -q 'never touch vendor/' "$FAKE_LOG" || { echo "  standing orders missing:"; cat "$FAKE_LOG"; exit 1; }
s_line="$(grep -n 'STANDING ORDERS' "$FAKE_LOG" | cut -d: -f1)"
f_line="$(grep -n 'FINISH CONTRACT' "$FAKE_LOG" | cut -d: -f1)"
[ "$s_line" -lt "$f_line" ] || { echo "  finish contract not last"; exit 1; }

# --- a round-2 critic owes a round-scoped slug (else its VERDICT is a DUP)
printf 'ACCEPTANCE: a\n' > "$TMP/cbrief"
printf 'critic.harness=fake\ncritic.model=\n' >> "$COORD_CONFIG"
"$STATE" review s1 2 >/dev/null
rm -f "$FAKE_LOG"
"$SPAWN" --role critic --prompt "$TMP/cbrief" --worktree "$WT" --slice s1 >/dev/null
wait_log 'FINISH CONTRACT' "$FAKE_LOG" || { echo "  critic never ran"; exit 1; }
grep -q -- '--event s1.r2.critic --role critic' "$FAKE_LOG" || { echo "  critic slug not round-scoped:"; cat "$FAKE_LOG"; exit 1; }
[ "$("$STATE" get s1 task)" = "s1.r2.critic" ] || { echo "  critic task not recorded"; exit 1; }

# --- risk routing: --risk <class> picks lane routing.<class>
cat > "$TMP/fake2" <<'EOF'
#!/usr/bin/env bash
echo "fake2 ran" >> "$FAKE_LOG"
EOF
chmod +x "$TMP/fake2"
printf 'harness.fake2.exec=fake2|__PROMPT__\nharness.fake2.bin=%s\n' "$TMP/fake2" >> "$COORD_ENV_CONF"
printf 'lane.strong.harness=fake2\nlane.strong.model=\nrouting.risky=strong\nrouting.mechanical=default\n' >> "$COORD_CONFIG"
"$STATE" add s2 "risky slice" >/dev/null
rm -f "$FAKE_LOG"
"$SPAWN" --role worker --prompt "$TMP/brief" --worktree "$WT" --slice s2 --risk risky >/dev/null
wait_log 'fake2 ran' "$FAKE_LOG" || { echo "  risky slice not on strong lane:"; cat "$FAKE_LOG" 2>/dev/null; exit 1; }
if "$SPAWN" --role worker --prompt "$TMP/brief" --worktree "$WT" --slice s2 --risk bogus >/dev/null 2>"$TMP/err"; then
  echo "  unknown risk allowed"; exit 1
fi
grep -q 'no routing.bogus' "$TMP/err" || { echo "  unclear risk error:"; cat "$TMP/err"; exit 1; }

echo "  spawn ok"
