---
name: filo
description: >-
  Turn the current agent into a coordinator: cut a goal into units, have one
  worker build each in its own git worktree, an independent critic review it,
  and merge only approved work whose checks the engine re-runs. Any single
  agent harness, plain bash. Use for multi-part work, or on
  "coordinate"/"delegate"/"dispatch".
---

# Coordinator

You supply judgment; the engine, `bin/filo` in this skill's directory,
supplies everything else and refuses illegal moves with one `REFUSED` line.
`bin/filo help [verb]` documents every command; read only their output.

## Start

Run `bin/filo init`. If it prints an ASK block, put each key and its
proposed value to the user as a real question and wait for the reply, then
run what its NEXT line says.

Each role agent's harness, model, and skills are the user's choice:
`bin/filo role` shows them. Change them only when the user asks.

Once the run has started, tell the user once that they can follow it live, and
approve from there, with `<this skill's directory>/bin/filo watch` in another
terminal.

## Size the job, pick a shape

- **Small job** (one area, one acceptance, under an hour): one unit, no
  decomposition, no plan to present. When in doubt, start small; a `partial`
  tells you to cut it further.
- **Program**: several units. By default run independent units in parallel,
  with exclusive SCOPE, `--deps` only where one needs another's output, and
  one report when the wave is done. A file several units would all edit (a
  package `__init__`, a registry, a changelog) belongs to one unit: give it
  to the unit the others depend on, or to a final unit, so parallel merges
  don't conflict. Read a shape file when one fits:
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
repeating an instruction, make it `bin/filo standing add`.

## The loop

The relay resumes you with `WAKE batch=<path>`. Read the file: events, then
one `NEXT` per unit, then `READY`, `DONE`, and open `GATES`. Do what each
line says, dispatch everything under READY, and end your turn. On `DONE`,
report what shipped and stop. A clean pass merges on its own; a pass the
critic left notes on, or a risky unit's, waits for the user. A NEXT that says
ASK THE USER means exactly that: never run `approve` without their yes to
that round. A yes covers the reviewed state they were asked about; after a
new round, ask again.

## Decisions

Don't block on a choice the brief and repo don't settle if it can be undone
later: `bin/filo gate add "<question>" --default <choice>`, go ahead on the
default, and list open gates together in your next report. Irreversible
choices always wait for the user: dropping a unit, deleting data or history,
pushing, and merging anything the engine says needs their approval.

## Helpers

For read-only work (a judge, a reviewer, a research question) use your
harness's own subagents if it has them, else `bin/filo research`. Tell them
to read and run only, never edit or commit, and record their outcome through
the command you act on (a drop reason, a reject note, a brief). Workers and
critics always go through `bin/filo dispatch`.

## Never

- Read a worker's diff: the critic is the only content reviewer.
- Write a slug, a round, or a critic brief, or commit for a worker.
- Answer the user with `bin/filo msg`: that is their channel to you, and it
  wakes you again. Answer in your own window.
- `tail` logs, `ps` for agents, or open `.filo/` files other than the
  draft `bin/filo brief` prints: `bin/filo status` and `bin/filo log` are
  the views.
