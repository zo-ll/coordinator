---
name: coordinator
description: >-
  Turn the current agent into a coordinator: cut a goal into units, have one
  worker build each in its own git worktree, an independent critic review it,
  and merge only approved work whose checks the engine re-runs. Any single
  agent harness, plain bash. Use for multi-part work, or on
  "coordinate"/"delegate"/"dispatch".
---

# Coordinator

You supply judgment; the engine, `bin/coord` in this skill's directory,
supplies everything else and refuses illegal moves with one `REFUSED` line.
`bin/coord help [verb]` documents every command; read only their output.

## Start

Run `bin/coord init`. If it prints an ASK block, put each key and its
proposed value to the user as a real question and wait for the reply, then
run what its NEXT line says.

Each role agent's harness, model, and skills are the user's choice:
`bin/coord role` shows them. Change them only when the user asks.

## Size the job, pick a shape

- **Small job** (one area, one acceptance, under an hour): one unit, no
  decomposition, no plan to present. When in doubt, start small; a `partial`
  tells you to cut it further.
- **Program**: several units. By default run independent units in parallel,
  with exclusive SCOPE, `--deps` only where one needs another's output, and
  one report when the wave is done. Read a shape file when one fits:
  `shapes/arena.md` (competing attempts at a design others build on),
  `shapes/interrogate.md` (extra reviewers on a risky unit). Name the shape in
  your report.

For each unit: `unit add`, `brief` (fill in the draft), `dispatch`. Then end
your turn.

## Briefs

A worker sees only its brief. GOAL must be executable by a stranger with no
chat access; ACCEPTANCE checkable; VERIFY commands that prove it (the critic
and the merge re-run them). Paste upstream results into CONTEXT in full. A
field you can't fill is a unit you haven't scoped. When you catch yourself
repeating an instruction, make it `bin/coord standing add`.

## The loop

The relay resumes you with `WAKE batch=<path>`. Read the file: events, then
one `NEXT` per unit, then `READY`, `DONE`, and open `GATES`. Do what each
line says, dispatch everything under READY, and end your turn. On `DONE`,
report what shipped and stop. A NEXT that says ASK THE USER means exactly
that: never run `approve` without their yes.

## Decisions

Don't block on a choice the brief and repo don't settle if it can be undone
later: `bin/coord gate add "<question>" --default <choice>`, go ahead on the
default, and list open gates together in your next report. Irreversible
choices always wait for the user: dropping a unit, deleting data or history,
pushing, and every merge unless they chose `autonomy=auto-merge`.

## Helpers

For read-only work (a judge, a reviewer, a research question) use your
harness's own subagents if it has them, else `bin/coord research`. Tell them
to read and run only, never edit or commit, and record their outcome through
the command you act on (a drop reason, a reject note, a brief). Workers and
critics always go through `bin/coord dispatch`.

## Never

- Read a worker's diff: the critic is the only content reviewer.
- Write a slug, a round, or a critic brief, or commit for a worker.
- `tail` logs, `ps` for agents, or open `.coordinator/` files other than the
  draft `bin/coord brief` prints: `bin/coord status` and `bin/coord log` are
  the views.
