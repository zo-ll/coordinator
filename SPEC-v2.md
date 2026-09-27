# coordinator v2

Status: implemented; the migration from v1 is complete (the v1 design is in
git history).
Decisions made during implementation are recorded under Decisions.

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
layer the engine enforces, in bash (see Decisions 11).

- **Unit.** Today's slice, plus a `kind` and a `risk`. Round and owed finish
  slug are computed by the engine, never passed by the coordinator.
- **Playbook.** One file per unit kind: which brief fields are required, what
  the worker and critic are told, the evidence floor for a merge, the default
  timebox. Playbooks are data, editable without recompiling.
- **Evidence.** A critic's `pass` carries a ranked evidence level and the
  commands run, bound to a state hash the engine computes itself. A pass below
  the playbook's floor is converted to a handback by the engine.
- **Event log.** One append-only `events.log` is the only source of truth.
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

`bin/coord`, a bash script with subcommands: `lib/core.sh` (paths, the locked
append, queries, launch, the state hash), `lib/cmd.sh` (the commands),
`lib/model.awk` (the state machine), `libexec/` (cfg, detect, plan, apply).
Runtime: bash 4.4+, coreutils, util-linux (`flock`, `setsid`), awk, git; nothing
to build. The repo is symlinked into each harness's skill dir, so everything
stays live on `git pull`.
Linux and WSL only, as in v1.

### Storage

Everything a run creates lives in `<repo>/.coordinator/`:

| Path | Contents | Writer |
|---|---|---|
| `events.log` | append-only event log, the source of truth, including delivery state | `coord` under `events.log.lock` |
| `config.conf` | repo choices (v1 format, committed) | `coord init` |
| `standing.md` | standing orders (committed) | `coord standing add` |
| `playbooks/*.md` | repo playbook overrides (committed) | the user |
| `.gitignore` | ignores everything here except the three above | `coord init` |
| `session` | coordinator session id | `coord init` |
| `gates.tsv` | gates: id, status, question, options, default, answer | `coord gate` |
| `briefs/<id>.draft.md` | the unit's next worker brief being filled in | `coord brief` |
| `briefs/<slug>.md`, `briefs/<slug>.brief.md` | each launch's full prompt; each worker's raw brief | `coord dispatch` |
| `worktrees/<id>/` | the unit's worktree, branch `coord/<id>` | `coord dispatch` |
| `log/<slug>.log`, `log/<id>.verify.log`, `log/relay.log` | launch output, merge VERIFY output, relay output | `coord` |
| `batch/`, `research/` | batch files, researcher reports | relay, researchers |
| `relay.lock`, `relay.pid` | one relay per run | `coord relay` |

The log is found as `$COORD_EVENTS`, else the nearest
`.coordinator/events.log` at or above the working directory, else
`./.coordinator/events.log`. Dispatch passes `COORD_EVENTS` to every role,
in its environment and in the finish-contract line; `finish` never creates a
log it was not pointed at.
The v1 queue, ledger, and journal are gone: all three are views of the event
log.

### Events

Each line is one event: tab-separated `key=value` fields — `seq` (1, 2, …, no
gaps), `ts` (epoch seconds), `type`, `unit` (empty for run-level events), then
the type's fields (repeated keys, e.g. `ran=`, form lists) — ending with a lone
`.` field. A line without the terminator is a torn write: readers skip it and
the next append cuts it off. Values never contain tabs or newlines (the writer
replaces them with spaces). Fields (was: one JSON object each): `seq`, `ts`, `unit`
(empty for run-level events), `type`, and type-specific fields.

| type | fields | written by | wakes coordinator |
|---|---|---|---|
| `unit_added` | `kind`, `goal`, `deps[]`, `risk` | `coord unit add` | no |
| `dispatched` | `role`, `round`, `slug`, `pid`, `worktree`, `branch`, `harness`, `model`, `timebox_s` | `coord dispatch` | no |
| `finished` | `slug`, `role`, `result`, `state`, `evidence`, `summary` | `coord finish` | yes |
| `converted` | `slug`, `from`, `to`, `reason` | engine (evidence below floor) | yes |
| `died` | `slug`, `pid`, `reason` (`exited` \| `timeout`) | relay | yes |
| `approved` / `rejected` | `text` (`by: engine` for a merge conflict) | `coord approve\|reject` (user), `coord merge` (engine) | yes |
| `msg` | `text` | `coord msg` (user) | yes |
| `verify_failed` | `command`, `exit`, `log`, `reason` | `coord merge` | yes |
| `claimed` / `acked` / `nacked` | `seqs`, `batch` | the relay (delivery of wake events) | no |
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
| `passed` | `approved` | `approved` | |
| `passed`, `approved` | `rejected` | `handback` | by the user, or by the engine on a merge conflict |
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
<FIELD…>`, and one that still holds a `<fill: …>` placeholder. `coord brief
<id>` drafts the next one: the playbook's fields as placeholders for a first
round, the last brief plus `CORRECTION:` for a later one; `dispatch --role
worker` without `--brief` uses the draft and removes it once launched. `TIMEBOX:` in the brief overrides the playbook default. The launched
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
coordinator's framing. Stored at `.coordinator/briefs/<slug>.md` for the log.

### Evidence

Levels, ordered: `none < typecheck < tests < live`.

- `typecheck`: the build and static checks pass.
- `tests`: automated tests covering the change pass.
- `live`: the behavior was exercised on the real surface (the running app,
  CLI, or service), not only in tests.

A critic finishes with `--evidence <level>`, one `--ran "<command>"` per
command it ran, and optional `--flag <name>` for each `evidence.require` item
it proved (`red-green`: a test fails at the base commit and passes at the
reviewed state). `coord finish` computes the state hash itself in the unit's
worktree and records it; the critic no longer passes `--head`. The hash is the
SHA-256 of `git diff --cached --binary HEAD` over a throwaway index holding the
whole working tree (tracked changes and untracked, non-ignored files, outside
`.scratch/`), so it does not depend on what the worker staged.

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
2. The repo is on the base branch, and the worktree state hash = the recorded `state`.
3. Each `$ ` command from the brief's `VERIFY`, in order, run with `bash -c` in
   the worktree, output to `.coordinator/log/<id>.verify.log`, each bounded by
   `verify.timeout` (config, default 10m). A nonzero exit or timeout appends
   `verify_failed` (the unit goes to `handback`) and prints
   `REFUSED <id> merge: verify failed: <command> (exit <n>)`.
4. State hash recomputed: a VERIFY command that changed the tracked or
   untracked non-ignored files refuses the merge (`verify modified the
   worktree`, recorded as `verify_failed`), since the merged state must be the
   reviewed one.
5. Stage the reviewed state and commit it with the user's identity, merge
   `coord/<id>` with `--no-ff`, then append `merged`. Publishing is a separate
   `git push` decision. On conflict, abort the merge, undo the commit, and
   append `rejected` (by engine), returning the unit to `handback` for a
   correction round.

This is the one place the engine executes brief content. The commands are ones
the coordinator wrote and the worker has already run with full permissions in
the same worktree; config values are still never executed.

### Scheduler (the relay)

`coord relay`: one per repo, guarded by `flock` as in v1. Each tick
(`relay.interval`, default 1s):

1. **Liveness.** For each `working`/`reviewing` unit whose pid is gone and whose
   owed slug has no `finished` event, append `died reason=exited`.
2. **Timebox.** For each such unit past `dispatched.ts + timebox_s`, send
   SIGTERM to its process group (launches run under `setsid`); once it exits,
   or after `timebox.grace` (config, default 30s) with SIGKILL, append `died
   reason=timeout`. Waiting never blocks the tick. A second death in one round
   also appends `blocked` (by engine).
3. **Delivery.** If any wake event is undelivered, write them in order to a
   batch file (`EVENT <seq> <unit> <type> <one line>`, then the standing
   orders) and append `claimed {batch, seqs}`; resume the coordinator with
   `WAKE batch=<path>` via the harness resume recipe, wait for the turn to
   exit, then append `acked`. One turn at a time.

Delivery stays at-least-once: a relay crash between `claimed` and `acked`
leaves the batch claimed; on restart the relay appends `nacked` and
delivers it again. Resume retries and give-up behavior are v1's.

### Delivery in tmux (planned; the default once built)

The coordinator is the user's own harness session, and its window is the
coordinator's UI. The headless resume above wakes it in a hidden background
process, so after boot the visible window goes stale. With tmux (the default
when `coord start` runs inside tmux), wakes land in that window instead:

- `coord start` records the coordinator's tmux pane id (`%12`, not a window
  name) in `.coordinator/`.
- The relay delivers a batch by typing one line into that pane:
  `tmux send-keys -t <pane> -l 'WAKE batch=<path>'`, then `Enter`. It types
  only when the pane's input line is empty (`tmux capture-pane`), so it never
  garbles what the user is typing.
- **Delivery is acknowledged by the coordinator**, not by a process exit: the
  first command of every turn is `coord ack <batch>`, which appends `acked`.
  With no ack within `relay.ack_timeout` (default 30s), the relay inspects the
  pane; a dialog on screen becomes a needs-you event, otherwise it retypes
  once, then nacks and reports. A missing pane is reported the same way.
- Each worker, critic, and researcher launch runs headless in its own tmux
  window, output streaming to its log as today, so attaching is
  `tmux select-window`.
- `coord watch` runs in a pane beside the coordinator: everything that is not
  the coordinator (units, launches, what needs the user).

Without tmux (CI, native Windows), delivery falls back to the headless resume.

### Optional capabilities

The engine requires nothing but bash and a harness that can run headless.
Two capabilities make it lighter when present, and each has a fallback so no
harness or tool becomes a dependency:

- **A terminal multiplexer** (tmux, zellij, wezterm, kitty, screen, …),
  through a per-multiplexer adapter: wakes typed into the coordinator's pane,
  agents in their own panes, the watch panel's popups and menus. Fallback:
  headless resume and a panel-only watch (see `docs/watch-bash-brief.md`).
- **Native subagents** in the coordinator's harness (Claude Code's Task tool,
  opencode subagents, pi's subagent extension): used only for short,
  read-only helpers (an arena judge, interrogation reviewers, research
  questions), whose answers return inside the coordinator's turn. Fallback:
  `coord research`. Workers and critics always go through `coord dispatch`,
  because they need a worktree, outlive the turn, and are gated by evidence
  and merge. A helper's outcome reaches the log through the command the
  coordinator acts with (a drop reason, a reject note, a correction brief).

### CLI

Every command prints one line (or one line per item for listings) and exits
nonzero on failure. `coord help [<verb>]` documents each one; it is the
reference, so SKILL.md does not repeat flags or output formats.

- Coordinator: `init`, `unit add`, `brief`, `dispatch`, `research`,
  `approve`, `reject`, `msg`, `block`, `reopen`, `drop`, `merge`, `gate`,
  `standing`, `status`, `log`.
- Role agents: `finish`, the only way a worker, critic, or researcher reports
  and wakes the coordinator.
- Plumbing, used by `init` and the relay: `detect`, `plan`, `apply`, `start`,
  `relay`, `cfg`, `unit next`, `done`.

### Next steps (the engine routes, the coordinator acts)

A batch lists its events, then what to do now:

- `NEXT <unit>: <action>`, one per unit in the batch, from the unit's
  **current** state rather than the event, so a redelivered event never
  repeats a step: `built` → dispatch the critic; `passed` → ask the user
  (merge directly under `auto-merge`); `approved` → merge; `handback` →
  `coord brief` for a correction, then dispatch the worker; `stalled` →
  dispatch the same role; `blocked` → tell the user. The engine never tells
  the coordinator to approve without asking.
- `NEXT <seq>: …` for a unit-less event (a research report, a message).
- `READY <ids>`, `DONE`, and `GATES <ids> open`.

`merge` and `drop` also print `READY` and `DONE`: the readiness or completion
they cause is not a wake event, so without it a run would stall after a merge.

### Hard rules retained from v1

The coordinator never reads a worker's diff; the critic is the only content
reviewer. Workers stage and never commit; the coordinator authors every commit
with the user's identity after an approved pass on the exact reviewed state.
Workers run with full permissions inside their worktree. One unit, one
worktree, one branch. Adapters change launch only. Config is parsed, never
sourced or executed.

## Testing Decisions

- **Transition table**: `test/model.test.sh`, one row per legal move and one per
  refused move, asserting the resulting state or the `REFUSED` reason.
- **Replay**: a log replays to the same projection as the incremental state;
  a truncated final line (crash mid-write) is ignored and the next append
  repairs it.
- **Black-box CLI suite**: the v1 approach kept — temp repo, fake harness on
  `PATH`, assertions on exit status, the one output line, and files. The v1
  suite ran against the Go binary unchanged through phase A, and against the bash engine after the port back.
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
2. **Event log.** *(done)* Replace the queue, ledger, and journal with `events.log`
   behind the same commands. v1 suite still green. (Queue delivery is the
   `enqueued`/`claimed`/`acked`/`nacked` events; tests that read queue files
   now assert through `queue depth` and batch contents; `ENQUEUED` prints
   `seq=<n>` instead of a file name.)
3. **v2 model.** *(done)* Add kinds, playbooks, evidence, engine-computed rounds and
   slugs, the timebox scheduler, and the v2 CLI. Update SKILL.md and the role
   preambles. Port the tests to the v2 CLI.
4. **Delete v1.** *(done)* Remove the shims and v1-only tests once SKILL.md and all
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

Made during implementation (2026-09-27):

5. **One directory per run.** All run state lives in `<repo>/.coordinator/`
   (see Storage); `$COORD_ROOT` is gone, so there is one relay per repo, not
   per machine.
6. **The state hash ignores staging** (see Evidence); workers no longer need
   to stage, and merge stages the reviewed state itself.
7. **Every refusal has a way forward.** `rejected` (user) and a merge conflict
   (`rejected` by engine) return the unit to `handback`, and so does a VERIFY
   that modifies the worktree (`verify_failed`).
8. **Researchers are unit-less launches** (`coord research`): slug
   `research.<n>`, a report path under `.coordinator/research/`, and a
   `finished` event that wakes the coordinator.
9. **A launch the state machine refuses to record is killed.** `dispatch`
   launches, then commits the `dispatched` event; if a concurrent change makes
   it illegal, the new process group gets SIGTERM.

10. **tmux is the default delivery** (planned; see Delivery in tmux): the
    harness window stays the coordinator for the whole run, wakes are typed
    into it and acknowledged with `coord ack`, and launches get their own tmux
    windows. Headless resume stays as the fallback.

11. **The engine is bash, not Go.** After the v2 model was built in Go, the
    engine was ported back to bash so the skill needs nothing but tools already
    on a Linux system and stays editable in place. The CLI contract was kept
    exactly, so the same black-box suite verifies it; the log became
    line-based (`events.log`, see Events) so awk can parse it; the state
    machine lives in `lib/model.awk`. Dispatch launches the agent inside the
    log transaction that records it, so a fast agent's `finish` can never
    arrive before its `dispatched`.

12. **Native subagents are an optional capability for read-only helpers**
    (see Optional capabilities). This recovers most of the lightness of
    platforms that provide spawning and notification (pstack on Cursor)
    without depending on any harness.

13. **The CLI carries the protocol; the skill carries judgment.** Routing,
    boot, brief fields, gates, and standing orders moved from SKILL.md into
    `coord` (next steps in each batch, `init`, `brief`, `gate`, `standing`,
    `help`), so the skill is only what the engine cannot decide. `render` was
    dropped; `status` is the view.

## Open Questions

None yet.
