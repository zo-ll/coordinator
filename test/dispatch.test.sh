#!/usr/bin/env bash
# coord dispatch: brief validation, worktree creation, engine-computed round
# and slug, the composed prompt, risk lanes, and the engine-written critic brief.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
export FAKE_WORKER=exit FAKE_CRITIC=exit   # launches record their prompt, then leave

"$COORD" unit add u1 --kind bugfix --goal "fix the drift" >/dev/null

# a brief missing a required field never launches
printf 'GOAL: g\nSCOPE: s\nVERIFY:\n  $ true\n' > "$TMP/thin"
refuses "REFUSED u1 brief: missing REPRO ACCEPTANCE (a bugfix brief needs: GOAL SCOPE REPRO ACCEPTANCE VERIFY)" \
  "$COORD" dispatch u1 --role worker --brief "$TMP/thin"
# a header mid-line does not count; VERIFY needs a "$ " command
printf 'GOAL: g\nSCOPE: s\nREPRO: r\nnote ACCEPTANCE: later\nVERIFY: run the tests\n' > "$TMP/thin"
refuses "missing ACCEPTANCE" "$COORD" dispatch u1 --role worker --brief "$TMP/thin"
printf 'GOAL: g\nSCOPE: s\nREPRO: r\nACCEPTANCE: a\nVERIFY: run the tests\n' > "$TMP/thin"
refuses 'VERIFY has no "$ " command' "$COORD" dispatch u1 --role worker --brief "$TMP/thin"
[ ! -e "$REPO/.coordinator/worktrees/u1" ] || { echo "  refused brief created a worktree"; exit 1; }
# a critic cannot come before the worker
refuses "REFUSED u1 dispatched: cannot dispatch a critic from todo" "$COORD" dispatch u1 --role critic

# standing orders ride on every launch, before the finish contract
printf '1. never touch vendor/\n' > "$REPO/.coordinator/standing.md"
brief "$TMP/brief"
out="$("$COORD" dispatch u1 --role worker --brief "$TMP/brief")"
has "$out" "DISPATCHED u1 role=worker round=1 slug=u1.r1.worker pid="
has "$out" "wt=$REPO/.coordinator/worktrees/u1"
assert "$(git -C "$REPO/.coordinator/worktrees/u1" rev-parse --abbrev-ref HEAD)" "coord/u1"
wait_for test -f "$FAKE_DIR/prompt.u1.r1.worker"
p="$(cat "$FAKE_DIR/prompt.u1.r1.worker")"
has "$p" "Reproduce first"                 # the bugfix playbook's worker section
has "$p" "CONTEXT: coordinator framing"    # the worker sees its whole brief
has "$p" "never touch vendor/"
has "$p" "COORD_OWES=u1.r1.worker $COORD finish --result done"
s_line="$(grep -n 'STANDING ORDERS' "$FAKE_DIR/prompt.u1.r1.worker" | cut -d: -f1)"
f_line="$(grep -n 'FINISH CONTRACT' "$FAKE_DIR/prompt.u1.r1.worker" | cut -d: -f1)"
[ "$s_line" -lt "$f_line" ] || { echo "  finish contract not last"; exit 1; }

# the launch died without finishing -> the relay would report it; simulate:
# a second worker dispatch now is refused (u1 is working, not handback)
refuses "cannot dispatch a worker from working" "$COORD" dispatch u1 --role worker --brief "$TMP/brief"

# worker finishes (by hand, as the fake left), then the critic brief is the
# engine's: criteria only, never CONTEXT
(cd "$REPO/.coordinator/worktrees/u1" && echo more >> file.txt && COORD_OWES=u1.r1.worker "$COORD" finish --result done --summary ok >/dev/null)
refuses "a critic's brief is written by the engine" "$COORD" dispatch u1 --role critic --brief "$TMP/brief"
out="$("$COORD" dispatch u1 --role critic)"
has "$out" "role=critic round=1 slug=u1.r1.critic"
wait_for test -f "$FAKE_DIR/prompt.u1.r1.critic"
c="$(cat "$FAKE_DIR/prompt.u1.r1.critic")"
for f in "GOAL: file.txt gains a line" "SCOPE: file.txt only" "REPRO: cat file.txt" "ACCEPTANCE: file.txt has more" 'test "$(wc -l < file.txt)" -gt 1' \
         "Prove red-green" "--flag red-green" "least tests"; do
  has "$c" "$f"
done
hasnt "$c" "coordinator framing"
hasnt "$c" "Please do the thing"

# round 2 after a handback: new slug, same worktree
COORD_OWES=u1.r1.critic "$COORD" finish --result handback --summary "no test" >/dev/null
out="$("$COORD" dispatch u1 --role worker --brief "$TMP/brief")"
has "$out" "round=2 slug=u1.r2.worker"
has "$out" "wt=$REPO/.coordinator/worktrees/u1"

# risk routing: a risky unit runs on the lane routing.risky names
cat > "$TMP/bin/fake2" <<'F2'
#!/usr/bin/env bash
echo ran > "$FAKE_DIR/fake2.$COORD_OWES"
F2
chmod +x "$TMP/bin/fake2"
printf 'harness.fake2.bin=%s\nharness.fake2.exec=fake2|__PROMPT__\n' "$TMP/bin/fake2" >> "$COORD_ENV_CONF"
printf 'lane.strong.harness=fake2\nrouting.risky=strong\n' >> "$REPO/.coordinator/config.conf"
"$COORD" unit add r1 --kind feature --goal "risky" --risk risky >/dev/null
"$COORD" dispatch r1 --role worker --brief "$TMP/brief" >/dev/null
wait_for test -f "$FAKE_DIR/fake2.r1.r1.worker"
"$COORD" unit add r2 --kind feature --goal "odd" --risk bogus >/dev/null
refuses "REFUSED r2 dispatched: no routing.bogus" "$COORD" dispatch r2 --role worker --brief "$TMP/brief"

echo "  dispatch ok"
