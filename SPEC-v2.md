# coordinator v2 (draft)

Status: draft. v1 ([SPEC.md](SPEC.md)) is what the code implements today.

## Problem Statement

v1 is a reliable delivery layer: ordered queue, serial relay, atomic finish,
a merge gated on the exact reviewed state. It has no opinion about the *work*.
Nothing in the protocol knows what a bug fix needs before it can merge, what a
critic's `pass` must be backed by, how long a worker may run, or what round a
slice is in. Every one of those calls is left to the coordinator model, so runs
drift: briefs vary in quality, passes carry no evidence, a hung worker hangs the
slice, and a handback's round is whatever the coordinator remembers to pass.

The state that would enforce these rules is also the wrong shape. The ledger is
a mutable TSV that accepts any status change; the queue, the ledger, and the
journal are three stores that can disagree; and bash has no data types to hold
a state machine, a dependency graph, or ranked evidence.

## Solution

Keep v1's delivery guarantees and its harness independence. Add a small domain
layer the engine enforces, and move the engine to one static Go binary.

- **Unit.** Today's slice, plus a `kind` and a `risk`. Round and owed finish
  slug are computed by the engine, never passed by the coordinator.
- **Playbook.** One file per unit kind: which brief fields are required, what
  the worker and critic are told, the evidence floor for a merge, the default
  timebox. Playbooks are data, editable without recompiling.
- **Evidence.** A critic's `pass` carries a ranked evidence level and the
  commands run, bound to a state hash the engine computes itself. A pass below
  the playbook's floor is converted to a handback by the engine.
- **Event log.** One append-only `events.jsonl` is the only source of truth.
  Unit state is a replay of it; every append is checked against a transition
  table under one lock, so an illegal transition is refused, not recorded.
- **Mechanical review inputs.** The engine writes the critic's brief from the
  worker brief, so the coordinator's framing never reaches the critic, and
  `coord merge` re-runs the brief's `VERIFY` commands on the exact reviewed
  state before it commits.
- **Scheduler.** The relay becomes a loop with timers: it delivers wake events,
  reports dead launches, and kills launches past their timebox.

The dividing line: **the engine enforces shape; the model supplies judgment.**
Framing, decomposition, brief content, and routing decisions stay in the
coordinator's prose. Required fields, rounds, slugs, evidence floors,
transitions, timeouts, and retry caps are code.

## User Stories

1. As a coordinator, I want to declare a unit's kind, so the right brief
   fields, preambles, evidence floor, and timebox apply without my restating them.
2. As a coordinator, I want a brief missing a field its playbook requires to be
   refused before launch, so an unscoped unit never costs an agent.
3. As a coordinator, I want the engine to compute the round and the owed slug,
   so a handback can never reuse a stale slug or lose a verdict as a duplicate.
4. As a coordinator, I want a pass whose evidence is below the floor to come
   back as a handback with the reason, so "pass" always means "proven enough".
5. As a coordinator, I want a launch that runs past its timebox killed and
   reported, so a hung worker surfaces instead of hanging the unit.
6. As a coordinator, I want a unit that died twice in one round blocked
   automatically, so retries are bounded without my counting them.
7. As a user, I want to add or edit a playbook in my repo, so the protocol fits
   my project without forking it.
8. As a user, I want the whole run reconstructable from one file, so a
   postmortem never depends on the transcript.
9. As a critic, I want `finish` to compute the reviewed-state hash itself, so I
   cannot bind my verdict to the wrong state by mistake.
10. As a maintainer, I want the transition table in one place with table tests,
    so every legal and illegal move is proven, not asserted.
11. As a critic, I want my assignment composed by the engine from the worker
    brief, so I review against the criteria, not the coordinator's framing.
12. As a user, I want the merge to re-run the verify commands on the exact
    reviewed state, so a pass that was never really tested cannot merge.
13. As a maintainer, I want v1's black-box CLI tests to keep running during the
    port, so the rewrite is verified against the behavior it replaces.

## Implementation Decisions

### Runtime and install

One static Go binary, `coord`, with subcommands. Standard library only (no
cgo). `bin/install.sh` builds it when `go` is on `PATH`, otherwise downloads the
release binary for the platform; the repo is still symlinked into each
harness's skill dir, so SKILL.md, playbooks, and agents stay live on `git pull`.
Linux and WSL only, as in v1.

### Storage

| Path | Contents | Writer |
|---|---|---|
| `<repo>/.coordinator/events.jsonl` | append-only event log, the source of truth | `coord` under `events.lock` |
| `<repo>/.coordinator/cursor` | last seq delivered to the coordinator | the relay |
| `<repo>/.coordinator/config.conf` | repo choices (v1 format, committed) | `coord apply` |
| `<repo>/.coordinator/standing.md` | standing orders (committed) | the coordinator / user |
| `<repo>/.coordinator/playbooks/*.md` | repo playbook overrides (committed) | the user |
| `<repo>/.coordinator/session` | coordinator session id | `coord start` |
| `$COORD_ROOT/log/`, `$COORD_ROOT/batch/` | role logs, batch files | `coord` |

`events.jsonl`, `cursor`, and `session` are runtime state and gitignored.
`COORDINATION.md` is generated. The v1 queue, ledger, and journal are gone:
all three are views of the event log.

### Events

Each line is one JSON object: `seq` (1, 2, …, no gaps), `ts` (UTC), `unit`
(empty for run-level events), `type`, and type-specific fields.

| type | fields | written by | wakes coordinator |
|---|---|---|---|
| `unit_added` | `kind`, `goal`, `deps[]`, `risk` | `coord unit add` | no |
| `dispatched` | `role`, `round`, `slug`, `pid`, `worktree`, `branch`, `harness`, `model`, `timebox_s` | `coord dispatch` | no |
| `finished` | `slug`, `role`, `result`, `state`, `evidence`, `summary` | `coord finish` | yes |
| `converted` | `slug`, `from`, `to`, `reason` | engine (evidence below floor) | yes |
| `died` | `slug`, `pid`, `reason` (`exited` \| `timeout`) | relay | yes |
| `approved` / `rejected` | `note` | `coord approve\|reject` (user) | yes |
| `msg` | `text` | `coord msg` (user) | yes |
| `verify_failed` | `command`, `exit`, `log` | `coord merge` | yes |
| `merged` | `sha` | `coord merge` | no |
| `blocked` | `reason` | `coord block`, or engine (retry cap) | yes if by engine |
| `reopened` / `dropped` | `reason` | `coord reopen\|drop` | no |

Appending is one transaction under `flock(events.lock)`: replay the log, check
the transition, allocate `seq`, write the line, `fsync`. A refused append
prints `REFUSED <unit> <type>: <reason>` and exits 1. `finished` is idempotent
by `slug`: a second append with the same slug prints `DUP <slug>` and exits 0.

Replay cost is linear in the log; a run of a few thousand events replays in
milliseconds. Snapshots are out of scope until measured otherwise.

### Unit state machine

States: `todo`, `working`, `built`, `reviewing`, `passed`, `handback`,
`stalled`, `approved`, `merged` (terminal), `blocked`, `dropped` (terminal).
`ready` is not a state: a `todo` unit is ready when every dep is `merged` or
`dropped`.

| from | event | to | guard |
|---|---|---|---|
| — | `unit_added` | `todo` | id unused; deps exist; no cycle; kind has a playbook |
| `todo` | `dispatched` worker | `working` | ready; round = 1 |
| `handback` | `dispatched` worker | `working` | round = previous + 1 |
| `working` | `finished` worker `done` | `built` | slug = owed slug |
| `working` | `finished` worker `partial` | `handback` | slug = owed slug |
| `built` | `dispatched` critic | `reviewing` | same round |
| `reviewing` | `finished` critic `pass` | `passed` | evidence meets the floor; `state` recorded |
| `reviewing` | `finished` critic `pass` | `handback` | evidence below the floor (appends `converted`) |
| `reviewing` | `finished` critic `handback` | `handback` | |
| `working`, `reviewing` | `died` | `stalled` | remembers role and round |
| `stalled` | `dispatched` same role, same round | `working` / `reviewing` | deaths this round < 2 |
| `stalled` | second `died` in a round | `blocked` | engine appends `blocked` |
| `passed` | `approved` | `approved` | `autonomy=approve-merge` |
| `passed` (auto-merge) or `approved` | `verify_failed` | `handback` | |
| `passed` (auto-merge) or `approved` | `merged` | `merged` | worktree state hash = recorded `state`; every VERIFY command passed |
| any non-terminal | `blocked` | `blocked` | |
| `blocked` | `reopened` | `todo` | round resets to the next unused round |
| any non-terminal | `dropped` | `dropped` | |

The owed slug is always `<id>.r<round>.<role>` (`s1.r1.worker`,
`s1.r2.critic`). Slugs are never written by the coordinator.

### Playbooks

`playbooks/<kind>.md` ships in the repo; `<repo>/.coordinator/playbooks/<kind>.md`
replaces it for that repo. Header is flat `key=value` between `---` lines (the
v1 config format, parsed the same way, never executed); the body has optional
`## worker` and `## critic` sections appended to those roles' preambles.

```
---
kind=bugfix
brief.require=GOAL,SCOPE,REPRO,ACCEPTANCE,VERIFY
evidence.floor=tests
evidence.require=red-green
timebox=45m
lane=default
---
## worker
Reproduce first. Write the failing test before the fix; show it failing.

## critic
Run the new test against the base commit and confirm it fails there.
```

v2 ships four kinds:

| kind | brief.require | evidence.floor | evidence.require | timebox |
|---|---|---|---|---|
| `feature` | GOAL SCOPE ACCEPTANCE VERIFY | tests | — | 60m |
| `bugfix` | GOAL SCOPE REPRO ACCEPTANCE VERIFY | tests | red-green | 45m |
| `refactor` | GOAL SCOPE ACCEPTANCE VERIFY | tests | — | 45m |
| `chore` | GOAL SCOPE VERIFY | none | — | 20m |

`lane` is the default lane; a unit's `risk` overrides it through
`routing.<risk>` in config, as in v1. `brief.require` applies to worker
briefs (critic briefs are engine-written); a researcher brief requires `GOAL`.

### Briefs

A brief is a file of `FIELD:` sections, each starting at the beginning of a
line and running to the next field. `coord dispatch` refuses a brief missing
any field the playbook requires, printing `REFUSED <unit> brief: missing
<FIELD…>`. `TIMEBOX:` in the brief overrides the playbook default. The launched
prompt is: role preamble, playbook section for the role, brief, standing
orders, finish contract. The finish contract is generated and last.

`VERIFY:` holds commands, one per line prefixed `$ `; other lines are notes for
the worker. A brief whose `VERIFY` has no `$ ` line is refused. These are the
commands the worker runs, the critic runs, and `coord merge` re-runs.

**Critic briefs are written by the engine.** `coord dispatch <id> --role
critic` takes no brief. The engine composes it from the current round's worker
brief — `GOAL`, `SCOPE`, `ACCEPTANCE`, `VERIFY`, and `REPRO` when present —
plus the playbook's `## critic` section and the instruction to review the
worktree against the unit's base commit. `CONTEXT` and any other coordinator
prose are left out: the critic sees the criteria and the code, never the
coordinator's framing. Stored at `$COORD_ROOT/briefs/<slug>.md` for the log.

### Evidence

Levels, ordered: `none < typecheck < tests < live`.

- `typecheck`: the build and static checks pass.
- `tests`: automated tests covering the change pass.
- `live`: the behavior was exercised on the real surface (the running app,
  CLI, or service), not only in tests.

A critic finishes with `--evidence <level>`, one `--ran "<command>"` per
command it ran, and optional `--flag <name>` for each `evidence.require` item
it proved (`red-green`: a test fails at the base commit and passes at the
reviewed state). `coord finish` computes the state hash itself in the worktree
(`git diff HEAD` over tracked and untracked files outside `.scratch/`, SHA-256)
and records it; the critic no longer passes `--head`.

A `pass` is accepted only if the level is at or above the playbook floor, at
least one `--ran` is given (unless the floor is `none`), and every
`evidence.require` flag is present. Otherwise the engine records the `finished`
event, appends `converted` with the missing item as the reason, and the unit
moves to `handback`. A new state hash voids the evidence: `coord merge`
recomputes the hash and refuses on drift, as in v1.

The critic's evidence is attested, and the engine checks its shape. What the
engine checks for truth is `VERIFY`: before merging, it re-runs those commands
itself (see Merge). A pass whose tests do not actually pass never merges.

### Merge

`coord merge <id>`, in order, refusing at the first failure:

1. Recorded user approval (or `autonomy=auto-merge`).
2. Worktree state hash = the recorded `state`.
3. Each `$ ` command from the brief's `VERIFY`, in order, run with `bash -c` in
   the worktree, output to `$COORD_ROOT/log/<id>.verify.log`, each bounded by
   `verify.timeout` (config, default 10m). A nonzero exit or timeout appends
   `verify_failed` (the unit goes to `handback`) and prints
   `REFUSED <id> merge: verify failed: <command> (exit <n>)`.
4. State hash recomputed: a VERIFY command that changed the tracked or
   untracked non-ignored files refuses the merge (`verify modified the
   worktree`), since the merged state must be the reviewed one.
5. Commit with the user's identity, merge in dependency order, push if
   `origin` exists, append `merged`.

This is the one place the engine executes brief content. The commands are ones
the coordinator wrote and the worker has already run with full permissions in
the same worktree; config values are still never executed.

### Scheduler (the relay)

`coord relay`: one per repo, guarded by `flock` as in v1. Each tick
(`relay.interval`, default 1s):

1. **Liveness.** For each `working`/`reviewing` unit whose pid is gone and whose
   owed slug has no `finished` event, append `died reason=exited`.
2. **Timebox.** For each such unit past `dispatched.ts + timebox_s`, send
   SIGTERM to its process group (launches run under `setsid`), wait 30s, send
   SIGKILL, append `died reason=timeout`.
3. **Delivery.** If any wake event has `seq > cursor`, write them in order to a
   batch file (`EVENT <seq> <unit> <type> <one line>`, then the standing
   orders), resume the coordinator with `WAKE batch=<path>` via the harness
   resume recipe, wait for the turn to exit, then set `cursor` to the batch's
   highest seq. One turn at a time.

Delivery stays at-least-once: a relay crash before the cursor moves means the
batch is delivered again. Resume retries and give-up behavior are v1's.

### CLI

Every command prints one line (or one line per item for listings) and exits
nonzero on failure.

| command | replaces (v1) |
|---|---|
| `coord detect`, `coord plan`, `coord apply` | `detect.sh`, `plan.sh`, `apply.sh` |
| `coord start [--session <id>]` | `coord.sh` |
| `coord unit add <id> --kind <k> --goal "<g>" [--deps a,b] [--risk <r>]` | `state.sh add` |
| `coord unit next` | `state.sh ready` + `next` |
| `coord dispatch <id> --role worker --brief <file>` | `worktree.sh` + `spawn.sh` (creates the worktree if absent) |
| `coord dispatch <id> --role critic` | `spawn.sh --role critic` (engine writes the brief) |
| `coord research --brief <file>` | `spawn.sh --role researcher` |
| `coord finish --result <r> [--evidence <l>] [--ran "<cmd>"]… [--flag <f>]… --summary "<s>"` | `finish.sh` (slug from `COORD_OWES`, set at dispatch) |
| `coord approve\|reject\|msg <id> ["<text>"]` | `coord.sh approve\|reject\|msg` |
| `coord merge <id>` | `merge.sh` |
| `coord block\|reopen\|drop <id> --reason "<r>"` | `state.sh blocked\|drop` |
| `coord status`, `coord render`, `coord log [<id>]`, `coord done` | `status.sh`, `state.sh render\|list\|done` |
| `coord relay` | `relay.sh` |

### Coordinator routing (SKILL.md)

For each event in a batch:

- `finished` worker `done` → `coord dispatch <id> --role critic`.
- `finished` critic `pass` → the unit is `passed`; ask the user, or merge under `auto-merge`.
- `finished` critic `handback`, `converted`, `verify_failed`, or worker
  `partial` → write a correction brief; `coord dispatch <id> --role worker`.
- `died` → `coord status`; dispatch the same role again.
- `blocked` (by the engine) → tell the user.
- `approved` → `coord merge <id>`. `rejected`/`msg` → act on the text.

Then `coord unit next`, dispatch each ready unit, and stop when `coord done`
exits 0.

### Hard rules retained from v1

The coordinator never reads a worker's diff; the critic is the only content
reviewer. Workers stage and never commit; the coordinator authors every commit
with the user's identity after an approved pass on the exact reviewed state.
Workers run with full permissions inside their worktree. One unit, one
worktree, one branch. Adapters change launch only. Config is parsed, never
sourced or executed.

## Testing Decisions

- **Transition table**: Go table tests, one row per legal move and one per
  refused move, asserting the resulting state or the `REFUSED` reason.
- **Replay**: a log replays to the same projection as the incremental state;
  a truncated final line (crash mid-write) is ignored and the next append
  repairs it.
- **Black-box CLI suite**: the v1 approach kept — temp repo, fake harness on
  `PATH`, assertions on exit status, the one output line, and files. The v1
  suite runs against the Go binary unchanged through phase A.
- **Concurrency**: N fake workers finish at once; every `finished` appears once,
  seqs are gapless, and the relay performs one resume containing all N.
- **Evidence**: a pass below the floor, without `--ran`, or missing a required
  flag becomes `handback` with the reason; a pass at the floor becomes `passed`.
- **Timebox**: a fake worker that sleeps past a 1s timebox is killed with its
  process group and reported as `died reason=timeout`.
- **Retry cap**: two deaths in one round block the unit.
- **Playbook override**: a repo playbook replaces the shipped one for its kind.
- **Critic brief**: the composed brief contains the worker brief's GOAL, SCOPE,
  ACCEPTANCE, VERIFY (and REPRO), and never its CONTEXT.
- **Merge verify**: a failing VERIFY command refuses the merge and moves the
  unit to `handback`; a command that writes a new untracked file refuses with
  `verify modified the worktree`; passing commands merge.

## Migration

Callers first, then delete the old path.

1. **Port 1:1.** *(done)* `coord` implements the v1 CLI contracts; `scripts/*.sh` become
   one-line shims (`exec coord <verb> "$@"`). Done when the v1 suite passes
   unchanged against the binary.
2. **Event log.** Replace the queue, ledger, and journal with `events.jsonl`
   behind the same commands. v1 suite still green.
3. **v2 model.** Add kinds, playbooks, evidence, engine-computed rounds and
   slugs, the timebox scheduler, and the v2 CLI. Update SKILL.md and the role
   preambles. Port the tests to the v2 CLI.
4. **Delete v1.** Remove the shims and v1-only tests once SKILL.md and all
   recipes call `coord` directly.

A run in progress is not migrated across phases; finish it on the version that
started it.

## Out of Scope

- **Program** (done predicate, budget, spawn cutoff) and **Gates** (parked
  questions with defaults). Both reuse the scheduler; they come after v2.
- Sub-coordinators and nesting.
- Driving harnesses through SDKs instead of CLI recipes.
- Multiple repos in one run.
- Snapshots of the event log.
- Anything v1 already lists as out of scope.

## Decisions

Settled on review of the draft (2026-09-27):

1. **Critic briefs are engine-written** from the worker brief; the coordinator
   does not author review assignments.
2. **`coord merge` re-runs `VERIFY`** on the reviewed state and refuses on
   failure.
3. **Every unit gets a critic.** No self-review path, including `chore`; the
   critic stays the only content reviewer.
4. **A worker's `partial` goes to `handback`**, like any other correction round.

## Open Questions

None yet.
