# Shape: arena

Two or three attempts at the same unit in parallel; the best one merges.
For a design other units build on (an API, a data model, a tricky
algorithm), not routine work: each candidate costs a worker and a critic.

1. One unit per candidate (`auth-a`, `auth-b`, …), same kind, dispatched with
   the **same brief** (`--brief <file>`). With more than one lane in config,
   give them different `--risk` so different models try.
2. Units that build on the result depend on **every** candidate; they become
   ready once the winner merges and the rest are dropped.
3. When the passed candidates are in, a read-only judge (a helper) scores
   each worktree against ACCEPTANCE, picks one, and lists what's worth taking
   from the others. You read the verdict, never the diffs.
4. Ask the user to approve the winner; `filo drop <loser> --reason "arena:
   <winner> chosen: <why>"` for the rest.
5. Worth-keeping ideas become one small follow-up unit (`--deps <winner>`)
   with the judge's points pasted into CONTEXT.

If all candidates converge, say so and skip the follow-up. If they diverge
wildly, the brief was underspecified: drop them all, fix it, run again.
