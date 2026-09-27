# Shape: arena

The same unit attempted two or three times, in parallel; the best attempt
merges, and the best ideas from the others follow in a small unit.

**Use when** one attempt would lock in the wrong shape: an API or data model
other units will build on, a tricky algorithm, a design with real
alternatives. Not for routine work: it costs one worker and one critic per
candidate.

**How**

1. Add one unit per candidate, same kind and the **same brief**:
   `auth-a`, `auth-b`, `auth-c`. If there is more than one lane in config,
   give candidates different `--risk` values so they run on different lanes
   (different models see the problem differently).
2. Units that build on the result take **every** candidate as a dep
   (`--deps auth-a,auth-b,auth-c`): they become ready once the winner is
   merged and the losers are dropped.
3. Dispatch all candidates. Each gets its own critic as usual. A candidate
   the critic hands back can get a correction round, or be left to lose.
4. When the passed candidates are in, ask a **judge**: a read-only helper
   (your harness's native subagent if it has one, else `coord research`)
   given each candidate's worktree (from the `DISPATCHED` lines) and asked to
   score them against ACCEPTANCE, pick one to build on, and list what is worth
   taking from the others. You never read the diffs; the judge does.
5. Ask the user to approve the winner (it merges like any unit), then
   `coord drop <loser> --reason "arena: <winner> chosen: <judge's one-line why>"`
   for the others, so the decision is in the log even when the judge was a
   native subagent.
6. If the judge found ideas worth keeping, add one small follow-up unit
   (`--deps <winner>`) whose brief describes them. Paste the judge's points
   into CONTEXT; the worker can't see the losing worktrees' reasoning.

**Signals.** If all candidates converge on the same design, say so and skip
the follow-up. If they diverge wildly, the brief was underspecified: drop
them all, fix the brief, and run again rather than picking one at random.
