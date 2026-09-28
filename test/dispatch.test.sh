#!/usr/bin/env bash
# filo dispatch: brief validation, worktree creation, engine-computed round
# and slug, the composed prompt, risk lanes, and the engine-written critic brief.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
export FAKE_WORKER=exit FAKE_CRITIC=exit   # launches record their prompt, then leave

"$FILO" unit add u1 --kind bugfix --goal "fix the drift" >/dev/null

# a brief missing a required field never launches
printf 'GOAL: g\nSCOPE: s\nVERIFY:\n  $ true\n' > "$TMP/thin"
refuses "REFUSED u1 brief: missing REPRO ACCEPTANCE (a bugfix brief needs: GOAL SCOPE REPRO ACCEPTANCE VERIFY)" \
  "$FILO" dispatch u1 --role worker --brief "$TMP/thin"
# a header mid-line does not count; VERIFY needs a "$ " command
printf 'GOAL: g\nSCOPE: s\nREPRO: r\nnote ACCEPTANCE: later\nVERIFY: run the tests\n' > "$TMP/thin"
refuses "missing ACCEPTANCE" "$FILO" dispatch u1 --role worker --brief "$TMP/thin"
printf 'GOAL: g\nSCOPE: s\nREPRO: r\nACCEPTANCE: a\nVERIFY: run the tests\n' > "$TMP/thin"
refuses 'VERIFY has no "$ " command' "$FILO" dispatch u1 --role worker --brief "$TMP/thin"
[ ! -e "$REPO/.filo/worktrees/u1" ] || { echo "  refused brief created a worktree"; exit 1; }
# a critic cannot come before the worker
refuses "REFUSED u1 dispatched: cannot dispatch a critic from todo" "$FILO" dispatch u1 --role critic

# standing orders ride on every launch, before the finish contract
printf '1. never touch vendor/\n' > "$REPO/.filo/standing.md"
brief "$TMP/brief"
out="$("$FILO" dispatch u1 --role worker --brief "$TMP/brief")"
has "$out" "DISPATCHED u1 role=worker round=1 slug=u1.r1.worker pid="
has "$out" "wt=$REPO/.filo/worktrees/u1"
assert "$(git -C "$REPO/.filo/worktrees/u1" rev-parse --abbrev-ref HEAD)" "filo/u1"
wait_for test -f "$FAKE_DIR/prompt.u1.r1.worker"
p="$(cat "$FAKE_DIR/prompt.u1.r1.worker")"
has "$p" "Reproduce first"                 # the bugfix playbook's worker section
has "$p" "CONTEXT: coordinator framing"    # the worker sees its whole brief
has "$p" "never touch vendor/"
has "$p" "FILO_OWES=u1.r1.worker $FILO finish --result done"
s_line="$(grep -n 'STANDING ORDERS' "$FAKE_DIR/prompt.u1.r1.worker" | cut -d: -f1)"
f_line="$(grep -n 'FINISH CONTRACT' "$FAKE_DIR/prompt.u1.r1.worker" | cut -d: -f1)"
[ "$s_line" -lt "$f_line" ] || { echo "  finish contract not last"; exit 1; }

# the launch died without finishing -> the relay would report it; simulate:
# a second worker dispatch now is refused (u1 is working, not handback)
refuses "cannot dispatch a worker from working" "$FILO" dispatch u1 --role worker --brief "$TMP/brief"

# worker finishes (by hand, as the fake left), then the critic brief is the
# engine's: criteria only, never CONTEXT
(cd "$REPO/.filo/worktrees/u1" && echo more >> file.txt && FILO_OWES=u1.r1.worker "$FILO" finish --result done --summary ok >/dev/null)
refuses "a critic's brief is written by the engine" "$FILO" dispatch u1 --role critic --brief "$TMP/brief"
out="$("$FILO" dispatch u1 --role critic)"
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
FILO_OWES=u1.r1.critic "$FILO" finish --result handback --summary "no test" >/dev/null
out="$("$FILO" dispatch u1 --role worker --brief "$TMP/brief")"
has "$out" "round=2 slug=u1.r2.worker"
has "$out" "wt=$REPO/.filo/worktrees/u1"

# risk routing: a risky unit runs on the lane routing.risky names
cat > "$TMP/bin/fake2" <<'F2'
#!/usr/bin/env bash
echo ran > "$FAKE_DIR/fake2.$FILO_OWES"
F2
chmod +x "$TMP/bin/fake2"
printf 'harness.fake2.bin=%s\nharness.fake2.exec=fake2|__PROMPT__\n' "$TMP/bin/fake2" >> "$FILO_ENV_CONF"
printf 'lane.strong.harness=fake2\nrouting.risky=strong\n' >> "$REPO/.filo/config.conf"
"$FILO" unit add r1 --kind feature --goal "risky" --risk risky >/dev/null
"$FILO" dispatch r1 --role worker --brief "$TMP/brief" >/dev/null
wait_for test -f "$FAKE_DIR/fake2.r1.r1.worker"
"$FILO" unit add r2 --kind feature --goal "odd" --risk bogus >/dev/null
refuses "REFUSED r2 dispatched: no routing.bogus" "$FILO" dispatch r2 --role worker --brief "$TMP/brief"

# many dispatches at once: each gets its worktree (git worktree add is not
# safe to run concurrently in one repo, so the engine takes turns)
brief "$TMP/brief"
for i in $(seq 20); do "$FILO" unit add p$i --kind chore --goal "parallel $i" >/dev/null; done
for i in $(seq 20); do "$FILO" dispatch p$i --role worker --brief "$TMP/brief" > "$TMP/p$i.out" 2>&1 & done
wait
for i in $(seq 20); do
  grep -q "^DISPATCHED p$i " "$TMP/p$i.out" || { echo "  p$i: $(cat "$TMP/p$i.out")"; exit 1; }
done

# a post-checkout hook that leaves a job running never holds the lock
printf '#!/bin/sh\n(sleep 30 >/dev/null 2>&1 &)\n' > "$REPO/.git/hooks/post-checkout"; chmod +x "$REPO/.git/hooks/post-checkout"
"$FILO" unit add h1 --kind chore --goal hook1 >/dev/null; "$FILO" unit add h2 --kind chore --goal hook2 >/dev/null
"$FILO" dispatch h1 --role worker --brief "$TMP/brief" >/dev/null
timeout 10 "$FILO" dispatch h2 --role worker --brief "$TMP/brief" >/dev/null || { echo "  dispatch waited on a hook's job"; exit 1; }
rm "$REPO/.git/hooks/post-checkout"

echo "  dispatch ok"
