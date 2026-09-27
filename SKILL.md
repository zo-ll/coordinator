---
name: coordinator
description: >-
  Turn the current agent into a coordinator that decomposes a goal into typed
  units of work, dispatches one worker per unit on an isolated git worktree,
  has an independent critic review each result against evidence rules, and
  merges only approved work whose checks the engine re-runs itself.
  Harness-agnostic, plain bash: a single installed harness is enough,
  and no tmux, python, or node is required. Use for multi-part work spanning
  multiple files/areas, or on "coordinate"/"delegate"/"dispatch".
---

# Coordinator

## Invariant

The engine enforces shape; you supply judgment. You frame the goal, cut it
into units, and write worker briefs. The engine owns rounds, slugs, worktrees,
evidence rules, transitions, timeouts, and retries, and refuses anything
illegal with one `REFUSED <unit> <event>: <reason>` line. The critic is the
only content reviewer: you never read a worker's diff. Every command below is
`bin/coord <verb>` from this skill's directory; read only its one-line output.

## Boot

1. `bin/coord detect` → `DETECT …`; writes `env.conf`.
2. `bin/coord plan` → a `PROPOSE` line and an `ASK` block of `key=value` lines.
3. If the `ASK` block has entries, you MUST pose a real question and WAIT for the
   user's reply — never just list the fields:
   - Present each `key` with its proposed `value`. An empty model value means
     "use that harness's default model"; the user must confirm it.
   - Let the user accept all defaults or change any key.
   Then:
   - accepted everything → `bin/coord apply --accept`
   - changed fields → `bin/coord apply --answers "key=value key=value"`
   If the `ASK` block is empty, run `bin/coord apply --accept`.
   It prints `OK config=…` or `FAIL <field>: <reason>`; on `FAIL`, stop.
4. `bin/coord start` → `SESSION … source=…` + `RELAY …`; sets up
   `.coordinator/` and starts the relay detached. If it fails, no fake ids are
   invented — pass `--session <the-harness-real-session-id>`.
5. Add the units (below), dispatch every id `bin/coord unit next` prints, and
   end your turn. The relay drives every turn after this.

## Units

`bin/coord unit add <id> --kind <kind> --goal "<goal>" [--deps a,b] [--risk risky]`

- `kind` picks the playbook: `feature`, `bugfix`, `refactor`, `chore` (or a
  repo playbook in `.coordinator/playbooks/`). It sets the required brief
  fields, what the worker and critic are told, the evidence a pass needs, and
  the timebox. Pick the kind that matches the work; do not restate its rules.
- `--deps` orders units: a unit is ready when its deps are merged or dropped.
- `--risk` routes the worker to the lane `routing.<risk>` names in config.
- Ids are `[A-Za-z0-9_-]+`. One unit, one worktree, one branch.

## Briefs

A worker brief is a file of `FIELD:` sections, each at the start of a line.
`dispatch` refuses one missing a field its playbook requires. A field you
cannot fill is a unit you have not scoped.

```
GOAL:        one sentence, executable by a stranger with no chat access
SCOPE:       paths it may write, paths it may not
CONTEXT:     files to read; upstream results pasted in full (workers see no siblings)
REPRO:       (bugfix) the steps that show the defect
ACCEPTANCE:  checkable criteria, one per line
VERIFY:      commands, one per line prefixed "$ " — the worker runs them,
             the critic runs them, and merge re-runs them on the reviewed state
TIMEBOX:     optional, e.g. 30m (else the playbook's)
```

You never write the critic's brief: the engine composes it from GOAL, SCOPE,
REPRO, ACCEPTANCE, and VERIFY. CONTEXT is yours and stays with the worker.

`.coordinator/standing.md` holds the run's standing orders: numbered lines, one
constraint each. Every launch and every batch carries them. When you catch
yourself restating an instruction, append it there instead.

## Dispatch

- Worker: `bin/coord dispatch <id> --role worker --brief <file>`
- Critic: `bin/coord dispatch <id> --role critic`
- Research (optional, no unit): `bin/coord research --brief <file>` with a
  `GOAL:`; the researcher writes a decision brief to the report path it prints.

The engine computes the round and the finish slug, creates the worktree, and
appends the finish contract. A correction round is just another worker
dispatch after a handback: write a correction brief (what failed, what to do)
and dispatch; the round advances by itself.

## The loop (the relay drives it; you own no loop)

The relay resumes this session with `WAKE batch=<path>`. At the start of every
resumed turn, read the batch file and route each line
`EVENT <seq> <unit> <type> <details>`:

- `finished` … worker `done` → `bin/coord dispatch <unit> --role critic`.
- `finished` … critic `pass` → the unit is passed. Ask the user; on their
  approval `bin/coord approve <unit>` then `bin/coord merge <unit>`. Under
  `autonomy=auto-merge`, merge directly.
- `finished` … critic `handback`, `converted` (a pass without enough evidence),
  `verify_failed` (merge re-ran VERIFY and it failed), `rejected`, or worker
  `partial` → write a correction brief from the reason and dispatch the worker.
- `died` → `bin/coord status`, then dispatch the same role again (a worker's
  brief is reused if you omit `--brief`). After two deaths in one round the
  engine blocks the unit itself.
- `blocked` (by the engine) → tell the user; `bin/coord reopen <unit> --reason …`
  once the cause is fixed.
- `finished` … researcher → read the report, route the decision to the user.
- `approved` → `bin/coord merge <unit>`. `msg` → act on the text.

Then dispatch every id `bin/coord unit next` prints. When `bin/coord done`
prints `DONE`, report what shipped and stop.

Delivery is at-least-once: after a relay crash an event may come twice. Every
command is safe to repeat — a repeated dispatch or finish is refused or `DUP`,
never doubled.

## User decisions

`bin/coord approve|reject <unit> ["note"]`, `bin/coord msg <unit|-> "text"`,
`bin/coord block|reopen|drop <unit> --reason "…"`. Block and drop stop the
unit's live launch. Merge never happens without a recorded approval unless the
user chose `autonomy=auto-merge`.

## Observe (do not improvise)

`bin/coord status` is the sanctioned view: relay liveness, undelivered events,
every unit with its state, round, readiness, and live pid, and the last log
line of each live launch. `bin/coord log [<unit>]` is the full history;
`bin/coord render` writes `COORDINATION.md`. Never `tail` a role log, `ps` for
agents, or read `.coordinator/` files by hand.

## Hard rules

- Route on the event line only; never read a worker's diff. The critic is the
  only content reviewer.
- Workers never commit; the coordinator's `merge` commits the exact reviewed
  state with the user's git identity, after the engine re-ran VERIFY.
- Workers run with full permissions inside their worktree; the critic's
  evidence, the reviewed-state binding, and the approval-gated merge are the gate.
- Never write a slug, a round, or a critic brief yourself.
- Workers see only their brief; critics see only the criteria and the code.
