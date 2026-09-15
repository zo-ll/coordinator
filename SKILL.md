---
name: coordinator
description: >-
  Turn the current agent into a coordinator that decomposes a goal into small
  vertical slices, publishes them, spawns one worker per slice on an isolated
  git worktree, has an independent critic review each survivor, and merges only
  approved work. Harness-agnostic and bash-only: a single installed harness is
  enough, and no tmux, python, or node is required. Use for multi-part work
  spanning multiple files/areas, or on "coordinate"/"delegate"/"dispatch".
---

# Coordinator

## Invariant

You route protocol; the critic is the only content reviewer. You never read a
worker's diff. All state lives in the scripts' files; read their protocol
outputs and progress diagnostics, and use `status.sh` for the run's health.

Normal operation uses one terminal and one harness for all roles. Multiple
installed harnesses do not require mixed roles. Simultaneous multi-harness
sandboxes are compatibility tests, not the normal workflow. tmux and other
launch adapters are opt-in.

## Make progress visible

Lifecycle scripts emit `[COORD] START`, `OK`, `WAIT`, `WARN`, and `FAIL` to
stderr and persist them in `$COORD_ROOT/progress.log`. Keep these diagnostics
visible when calling detect, plan, apply, coord, worktree, spawn, finish, state
mutations, relay, and merge; do not suppress their stderr.

- Announce the next lifecycle action and slice before calling its script.
- After it returns, report the actual result and next action in one short line.
  A launch is not completion; a finish marker is not processed delivery; a
  successful wake command is not evidence that routing finished.
- Surface `FAIL` and `WARN` to the user with the phase, slice, and diagnostic.
  Do not silently skip a failed step or report the affected slice as complete.
- For `WAIT`, say what is pending: setup answers, worker completion, a critic,
  corrections, or approval. Include the user's next action when needed.
- Run `status.sh` after dispatch, at the start of every resumed turn, and before
  reporting completion. A nonzero status is an alarm to investigate, not a
  successful run. `LAST-FAIL` is historical and may describe a recovered failure.
- At boot, tell the user they can run `scripts/status.sh --watch` from another
  terminal with the same project/root. No launch adapter is required. This is
  a human viewer; the coordinator should use single snapshots, not own a watch
  loop. Background diagnostics become visible through this viewer and the
  coordinator's status checks; they cannot interrupt a stopped session.

## Boot

1. `scripts/detect.sh` → `DETECT …`; writes `env.conf`.
2. `scripts/plan.sh` → a `PROPOSE` line and an `ASK` block of `key=value` lines.
3. If the `ASK` block has entries, you MUST pose a real question and WAIT for the
   user's reply — never just list the fields:
   - Present each `key` with its proposed `value`. An empty model value means
     "use that harness's default model"; the user must confirm it.
   - Let the user accept all defaults or change any key.
   Then:
   - accepted everything → `scripts/apply.sh --accept`
   - changed fields → `scripts/apply.sh --answers "key=value key=value"`
   If the `ASK` block is empty, run `scripts/apply.sh --accept`.
   It prints `OK config=…` or `FAIL <field>: <reason>`; on `FAIL`, stop.
4. `scripts/coord.sh` → `SESSION … source=…` + `RELAY …`; starts the relay
   detached. If it fails, no fake ids are invented — pass `--session
   <the-harness-real-session-id>` (pi uses `$PI_SESSION_ID`, codex the live
   rollout).
5. `scripts/status.sh` → check relay liveness and report the runtime root and
   any warnings. `RELAY pid=…` reports a launch request, not confirmed readiness.

## Slice lifecycle

- Add: `scripts/state.sh add <id> "<goal>" [--blockers 1,2]`
  The event slug IS the slice id: `<id>` for a worker round, `<id>.critic`
  for a critic, `<id>.r<N>` for a re-review. Never decorate it further — one
  brief, one slug per round; worktree.sh names branches from it.
- Worktree: `scripts/worktree.sh --slice <id> --slug <slug>`
- Dispatch a worker:
  `scripts/spawn.sh --role worker --prompt <brief> --worktree <dir> --slice <id>`
- Review: `scripts/spawn.sh --role critic --prompt <assignment>
  --worktree <dir> --slice <id>` (a critic is a review round of a slice).
- Close: after a `pass` bound to the exact reviewed state (the critic's
  `git diff HEAD | sha256sum` of the worktree) and the user's approval,
  `scripts/merge.sh --slice <id>`.

## The loop (the relay drives it; you own no loop)

The relay resumes this session with `WAKE batch=<path>`. At the start of every
resumed turn, read the batch file and route each `EVENT`:

- `DONE <task>: done` → write a review assignment; `spawn.sh --role critic`.
- `VERDICT <task>: pass @ <state-hash>` → `state.sh verdict`; ask the user; on
  approval `merge.sh --slice <id>` (authors the commit with the user's
  identity, merges, pushes).
- `VERDICT <task>: handback` → write a correction brief; respawn the SAME
  worker with a new round slug.

Correlate `DONE <slug>` / `VERDICT <slug>` to the slice whose id is the slug's
task prefix (before the first `.`). Resolve the task to a slice id in this
order: (1) exact ledger id; (2) if the task ends in `-<suffix>`, retry with the
trailing `-…` segment stripped (a worker may carry the worktree suffix);
(3) otherwise it is a protocol error — surface it, do not guess.

Delivery is at-least-once: after a relay crash an event may be redelivered.
Never re-spawn a critic for a slice already `reviewing` (check `state.sh`), and
make every routing action idempotent.

Then `state.sh ready`, dispatch each id from `state.sh next`, and when
`state.sh done` exits 0, report what shipped and stop.

`coord.sh approve <id>` currently records a file without enqueueing a wake.
After approval, the coordinator must be given a turn to call `merge.sh`; do
not tell the user approval automatically restarted coordination. Report a
local merge separately from a successful push.

You implement nothing and review nothing.

## Observe (do not improvise)

`scripts/status.sh` is the sanctioned snapshot of a run: relay liveness, queue
depth, every slice with its pid's liveness, role log tails (including dead
processes), recent progress, and the last historical failure. For live human
observation, use `scripts/status.sh --watch` in a second terminal.
When the loop looks stalled, run `status.sh` and act on the protocol — never
`tail` a role log, `ps` for agents, or read markers by hand. Improvised polling
is how state diverges from the ledger.

## Adapters (optional launch)

`config.conf:adapters` (empty = core `setsid`). Each `adapters/<name>.sh`
defines `adapter_launch <cwd> <log> <argv…>` echoing a pid; `spawn.sh` sources
enabled adapters first, then falls back to core. Adapters may add visibility or
supervision and MUST NOT change delivery, the finish protocol, or routing.

## Hard rules

- Route on the event line and the verdict only; never read a worker's diff.
- The coordinator is the only one that manages git in the repo: workers stage
  (`git add -A`, including new files) and NEVER commit or push; critics never
  commit. The coordinator authors every commit with the user's git identity on
  an approved PASS, then merges and pushes.
- Workers run with FULL permissions (each harness's native bypass flag is in
  its exec recipe). The worktree plus the brief confine the worker; the
  critic's reviewed-state binding and the approval-gated merge are the gate.
- Merge only after a PASS bound to the exact reviewed worktree state plus
  recorded user approval.
- Corrections go to the SAME worker; a new round uses a new slug.
- Observe only through `status.sh`/`state.sh`; never poll logs or processes.
- One issue, one worktree, one branch per slice. The user's git identity only.
- Workers see only their brief; critics see diff + criteria + design ref.
