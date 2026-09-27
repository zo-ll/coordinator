## Problem Statement

The coordinator skill only works on the author's machine. It hardwires `pi` as the coordinator, `tmux` for event delivery, a fixed pane layout (`personal:coordinator.0`), and pi's `subagent` extension. A user who has only Codex, or only Claude, or no `tmux` at all cannot run it: installing the skill reproduces an environment rather than installing a protocol. The relay's push delivery depends on a resident pane in a multiplexer, so there is no way to wake a coordinator that isn't sitting in tmux.

There is also no way to confirm the loop works: its load-bearing correctness — atomic finish, ordered event delivery under concurrent workers, ledger transitions, reviewed-state-bound merge — is untested shell that fails silently.

## Solution

Make the coordinator a barebones, environment-independent loop of **bash** scripts, with the LLM acting only as a thin dispatcher over them. Runtime: bash 4.4+, standard Linux/WSL coreutils (`flock`, `setsid`, `sha256sum`, GNU `mv -T`), and `git`. No `python`, no `node`, no `tmux`.

- **Single-harness, no-`tmux` is the default.** Every role (critic, researcher, workers) runs on whatever single harness is installed; the coordinator is the session where the skill was invoked. Producer-severance comes from a separate process with fresh, starved input — never harness diversity.
- **Finished work is always a file** (a recovery marker plus a queued ping). Every role and every harness can write a file, so delivery never depends on a multiplexer or a live pane.
- **Pings go through an ordered queue.** A worker enqueues its completion; a single long-lived **relay** consumes the queue, coalesces whatever is pending into one batch, and **resumes the coordinator's session** via the configured harness command. Push semantics, and the coordinator stays free (not running) between batches.
- **The coordinator is event-driven.** The boot turn detects/plans/applies, decomposes, dispatches workers, then ends. Thereafter the relay drives turns by resuming the session; the coordinator owns no loop.
- **The user is just another producer.** Merge approvals and other decisions are enqueued as events through the same queue, so human input and worker completions travel identically.
- **Detection and decisions are scripted**, so the LLM reads only compact one-line outputs.
- **`tmux`/`herdr` are optional launch adapters** (visibility/supervision). They never change delivery, routing, review, merge, or the finish protocol.

## User Stories

1. As a developer with only Codex installed, I want to run the coordinator so that the critic, researcher, and every worker are all Codex, so I can use the protocol without installing another agent.
2. As a developer with only Claude installed, I want the same loop to run entirely on Claude, so the protocol is not tied to one vendor.
3. As a developer with no `tmux`, I want the loop to run barebones, so a terminal multiplexer is not a prerequisite.
4. As a developer with no `python` or `node` on the box, I want the protocol to run on bash (4.4+) and the stock Linux/WSL core utilities (`flock`, `setsid`, `sha256sum`, GNU `mv -T`), so there is no runtime dependency.
5. As a developer with `tmux`, I want to optionally launch workers in visible panes, so I can watch a run without changing protocol behavior.
6. As a developer, I want the functionality to be identical regardless of installed tools, so I never have to learn two modes.
7. As a developer booting the skill for the first time, I want it to detect my environment, so I am not asked about things it can determine itself.
8. As a developer, I want to be asked only about choices detection cannot make, so first-run setup is short.
9. As a developer, I want to confirm explicitly whether each role uses its harness's default model, so a model is never silently chosen for me.
10. As a developer, I want my answers persisted for the repo, so I am asked once and never again.
11. As a developer, I want a machine-level record of detected capabilities, so booting in a new repo does not re-detect from scratch.
12. As a developer, I want a clear failure before any work starts when a chosen harness can't be invoked, so I don't discover a broken run hours later.
13. As a developer, I want the coordinator to be resumed in the harness I already chose, so pinging it feels the same no matter which harness I use.
14. As a developer, I want the coordinator to be free between events, so it is not burning a session while workers run.
15. As a developer, I want to approve a merge by sending an event, so human decisions use the same channel as worker completions.
16. As a developer, I want the coordinator's whole picture in files rather than context, so long runs survive context limits.
17. As a developer, I want `COORDINATION.md` generated from a machine-readable ledger, so it cannot drift from reality.
18. As a worker, I want a single `finish.sh` call to record completion and enqueue a ping, so I don't hand-roll queue files.
19. As a worker, I want the marker written before the ping is enqueued, so a crash between the two is recoverable.
20. As a worker, I want concurrent finishes to never lose or double an event, so parallel work is safe.
21. As a worker, I want a retry of my own event to be a no-op, so re-publishing cannot trigger a duplicate action.
22. As a worker, I want a new round of the same task to deliver, so re-review after a handback still wakes the coordinator.
23. As a relay, I want to take a single lock and consume the queue serially, so I never run two coordinator turns at once.
24. As a relay, I want to coalesce everything pending into one batch, so a wave of completions is one turn instead of N.
25. As a relay, I want to process events in queue order, so routing is deterministic.
26. As a relay, I want to wait for the resumed turn to finish before taking the next batch, so turns never overlap.
27. As a coordinator, I want to receive a short pointer to a batch file, so a large batch never becomes a giant prompt.
28. As a coordinator, I want to know when the run is finished, so it stops resuming me.
29. As a coordinator, I want to be told when a dispatched worker died without finishing, so a dead run surfaces instead of hanging.
30. As a coordinator, I want to spawn a role with one call that reads role and model from config, so dispatch contains no environment details.
31. As a coordinator, I want each role's identity injected at spawn, so a harness without per-invocation skill flags still gets the right role behavior.
32. As a coordinator, I want each slice in its own worktree and branch, so parallel workers never collide.
33. As a coordinator, I want to route on the event line and the structured verdict only, so I never read a worker's diff to form a quality judgment.
34. As a coordinator, I want to require a fresh critic verdict for a behavior-changing post-review merge, so approval is always bound to the exact reviewed worktree state (workers only stage; there is no worker commit).
35. As a coordinator, I want merges to require the user's approval by default, so autonomy is opt-in.
36. As a coordinator, I want to record every state transition in a ledger, so the run is reconstructable.
37. As a critic, I want to receive only the diff, acceptance criteria, and design reference, so my review is severed from the producer's framing.
38. As a critic, I want to return a fixed verdict shape whose `head` is a hash of the exact reviewed state (`git diff HEAD | sha256sum`), so the coordinator can bind approval to that state, not to a worker-authored commit.
39. As a researcher, I want to be dispatched only on demand, so research is not part of every run.
40. As a maintainer, I want the config format hidden behind one reader, so the format can change without touching callers.
41. As a maintainer, I want config parsed rather than shell-sourced, so a committed value cannot execute.
42. As a maintainer, I want detection to use env sentinels with an ancestor-process fallback, so the current harness is identified even without a sentinel.
43. As a maintainer, I want an installed-harness count to decide whether the role map is forced, so the single-harness path asks nothing about roles.
44. As a maintainer, I want per-harness resume recipes to be config data, so the workflow code never branches on harness.
45. As a maintainer, I want tests at the scripts' CLI boundary with a fake harness, so the loop is verified deterministically without real agents.
46. As a maintainer, I want a concurrency test where many workers enqueue at once, so the queue's ordering and no-loss/no-double guarantees are proven.
47. As a maintainer, I want the same suite to run with zero, one, and fake-`tmux` setups, so the environment-agnostic claim is proven, not asserted.
48. As a maintainer, I want the core scripts to depend on nothing beyond bash and the standard Linux/WSL core utilities, so the barebones loop runs anywhere those exist.

## Implementation Decisions

**Coordinator identity.** The coordinator is the current session/harness. `detect.sh` records it in `env.conf` as `current` with `current_source` (`env` | `ancestor` | `user`); it is never asked, never configurable, and never spawned. `current` and `spawnable` are separate facts: the role map draws only from spawnable harnesses.

**Config format and access.** Flat `key=value`, dotted keys, two scopes:
- `~/.coordinator/env.conf` — machine-detected, never hand-edited (current identity; installed/spawnable harnesses; per-harness invocation and resume recipes; `tmux`/`gh`/`git` booleans).
- `<repo>/.coordinator/config.conf` — repo choices, committed (role → harness/model; worker lanes; risk routing; autonomy; tracker; enabled adapters; relay wait interval).

All access goes through `cfg.sh` (`get`/`set`/`keys`/`unset`). `get` parses with `read`/`cut` and never sources the file, so committed values cannot execute. Writes are atomic (temp + rename). No caller knows the on-disk format; it is swappable without touching callers.

**Per-harness recipes (data, not workflow).** `env.conf` holds, per harness: the **exec** recipe (build a worker/critic argv), the **resume** recipe (continue the coordinator session with a one-line pointer), the `bin`, workdir flag, permission flags, and model flag. Recipes are `|`-separated argv templates with `{session}` and `{batch}` placeholders, read into arrays and executed directly — **no `eval`**. The workflow scripts never branch on harness name.

**Boot flow.** `detect.sh` → writes `env.conf`, prints one compact line. `plan.sh` → reads `env.conf` (+ any `config.conf`), prints `PROPOSE` plus `ASK` only. Rules: one spawnable harness forces the role map and lanes; absent `tmux` forces adapters empty; absent `gh` forces tracker `local`; **model is always asked** (proposal is "harness default", chosen only if the user affirms). `apply.sh --answers "…"` (or `--accept` when `ASK` is empty) validates each referenced harness (`bin` exists, exec recipe resolves) and writes `config.conf`, printing `OK` or `FAIL <field>: <reason>`.

**Launcher and session identity.**`coord` is a bash launcher: it resolves the harness's REAL session id — `--session`, then `COORD_SESSION`, then the harness's own current session (`pi` via `$PI_SESSION_ID`; `codex` via the newest rollout under `$CODEX_HOME/sessions`), failing loudly rather than inventing a UUID no harness ever created — records it to `<repo>/.coordinator/session`, runs the boot turn, and starts `relay.sh` detached, pinning the harness's resume recipe into config (`relay.resume`) so the relay never depends on `env.conf current`. It also ensures `<repo>/.gitignore` ignores `.scratch/` and commits that (the first commit the coordinator authors in the run), so workers' `git add -A` can never stage finish markers. The relay reads `session` + the resume recipe to resume the coordinator.

**Ping queue.** `${COORD_ROOT}/queue/`, ordered and append-only. Enqueue is ONE atomic transaction under a single `flock`: de-dup check, sequence allocation, publish, and the `.seen` marker — so a concurrent retry of the same slug cannot double-publish, and publication order equals sequence order (a crash before publish leaves a sequence gap, never a reorder). Layout: `*.ping` pending (named `<seq>.<slug>.ping`), `.inflight/` claims, `.done/` acknowledged, `.seen/<slug>` de-dup markers.

**Core CLI contracts** (fixed here because they encode decisions):
- `finish.sh --event <slug> --role … --result … --head … --summary "…"` → writes the marker (`.scratch/status/<slug>.done`) **first**, then enqueues the ping; prints one line. Workers pass `--head -` (they have no commit); critics pass the reviewed-state hash.
- `queue.sh enqueue <slug> <line> | list | pop-batch | done <slug>…` → queue primitives used by `finish.sh`, `relay.sh`, and `coord`.
- `relay.sh` → long-lived serial consumer. Waits until the queue is non-empty (poll on the relay interval, or block on a FIFO). Takes all pending events in order, writes them to one batch file under `COORD_ROOT/batch/`, resumes the coordinator with a one-line pointer to that file, waits for the turn to exit, then moves the batch to `done/`. One turn at a time. On startup, under the single-relay lock, it requeues any events stranded in `.inflight` by a previous crash. Each loop it enqueues `DIED <task>` (slug `<task>.died.<pid>`) for every dispatched/reviewing slice whose pid is gone and whose owed slug was never enqueued, and appends `.coordinator/standing.md` to every batch.
- `state.sh` verbs: `add`, `ready`, `next`, `dispatch`, `review`, `verdict`, `merged`, `blocked`, `drop`, `list [--pids]`, `live`, `done`, `render`; each prints one short line; `done` exits 0 iff every slice is `merged` or `dropped`.
- `spawn.sh --role <r> --prompt <brief> --worktree <dir> [--slice <id>] [--risk <class>]` → refuses a brief missing its role's header fields (worker `GOAL SCOPE ACCEPTANCE VERIFY`, critic `ACCEPTANCE`, researcher `GOAL`); reads role/model from config (a worker's lane is `routing.<risk>`, else `default`); appends `.coordinator/standing.md` and the finish contract; builds argv from the exec recipe, launches detached, records `state.sh dispatch` with the finish slug the launch owes as `task`, prints one line.
- `merge.sh <id>` → recomputes the recorded reviewed-state hash from the worktree, refuses on any drift or unstaged/untracked (outside `.scratch/`) changes, authors the commit on the slice branch with the user's identity, merges in dependency order, pushes if `origin` exists, and records `state.sh merged`; refuses without recorded user approval.

**Event flow.** Worker/critic finish → marker + enqueue. Relay batches and resumes the coordinator. Coordinator routes each event (`DONE` → dispatch critic; `VERDICT pass @ <state-hash>` → record, wait for a user `approve <id>` event, `merge.sh` (authors the commit, merges, pushes); `VERDICT handback` → correction brief to the same worker, new round slug). Event tasks resolve to slice ids deterministically (exact id, else strip the trailing `-…` worktree-suffix segment, else protocol error). User decisions are enqueued via `coord approve|reject|msg <id>`, so the human is an ordinary producer.

**Turn-start invariant.** The coordinator processes the batch file named in its resume pointer at the start of every turn. Because the relay claims the batch only after the turn exits, no event is lost while the relay lives. Delivery is **at-least-once**: if the relay crashes after claiming, the events strand in `.inflight`; on restart, under the single-relay lock, the relay requeues stranded events and redelivers (routing actions must be idempotent, and critics are never re-spawned for a slice already under review).

**Ledger and dashboard.** `<repo>/.coordinator/ledger.tsv` is the machine state, owned by `state.sh` (the only parser; no `jq`/`awk` in the skill). Fields: `id | status | blockers | task | round | worktree | branch | pid | head | verdict | merge | goal` (goal last); `head` holds the reviewed-state hash for a pass. `COORDINATION.md` becomes `state.sh render` output. The journal remains append-only history.

**Adapters (launch only).** `config.conf:adapters` lists enabled adapters (empty = core). Each `adapters/<name>.sh` defines `adapter_launch <argv> <cwd>` echoing a pid; `spawn.sh` sources enabled adapters in order, first handler wins, else core `setsid … &`. Adapters may add visibility/supervision and MUST NOT alter delivery, the finish protocol, routing, review, or merge. Harness resume is config data, not an adapter.

**Hard rules retained in the skill text** (cannot be scripted): route on the event line and verdict only and never read a worker's diff; the critic is the only content reviewer; the coordinator is the only one that manages git — workers stage (`git add -A`) and never commit or push, critics never commit, and the coordinator authors every commit with the user's identity after an approved PASS, then merges; workers run with FULL permissions (each harness's native bypass flag lives in its exec recipe) — the worktree plus the brief confine the worker, and the critic's reviewed-state binding plus the approval-gated merge are the gate; merge only after a recorded PASS on the exact reviewed state plus a recorded user approval; corrections go to the same worker; one issue/worktree/branch per slice, each with exactly one event slug (`<id>`, `<id>.critic`, `<id>.r<N>`) and no other decoration; the user's git identity only.

## Testing Decisions

- **One seam: the scripts' CLI boundary.** Every core script is a black box — args + env in; exit status, one-line stdout, and files (`env.conf`, `config.conf`, `ledger.tsv`, markers, queue) out. Unit tests per script and one end-to-end run all attach here.
- Tests run in a temporary git repo with a synthetic `env.conf` and a **fake harness on `PATH`**: a stub whose exec recipe calls `finish.sh`, and whose resume recipe records its argv and processes the batch file — so the full `detect → plan → apply → finish/queue → relay → state/spawn → merge` loop runs without real agents or network.
- Good tests assert external behavior only: exit status, the single output line, and resulting files/queue/ledger state. Internal shell functions are never tested directly; harness differences are exercised only through stub recipes.
- Modules covered: `cfg`, `detect`, `plan`, `apply`, `invoke`/exec+resume recipes, `spawn`, `queue`, `finish`, `relay`, `state`, `merge`, `coord`; plus the loop integration test.
- **Concurrency test:** N workers call `finish.sh` simultaneously; assert every event is present exactly once, in enqueue order, and that the fake relay performs exactly **one** resume whose batch contains all N.
- **Environment-agnostic assertion:** the same suite is run under zero spawnable harnesses (boot must fail cleanly), exactly one (role map forced, model still asked), and a fake `tmux` launch adapter (behavior otherwise unchanged).
- Prior art: `coordinator/scripts/test-check-aborted.py` is the only existing test and establishes the "exec a script, assert on output/effects" pattern.

## Out of Scope

- Model quality, or any evaluation of what a chosen model returns.
- Validating the correctness of a harness's model catalog (only that the invocation resolves).
- Reimplementing the loop in a language other than bash; any `python`/`node`/`tmux` requirement.
- **Resident live-session push** (typing into a running pty, codex `queue` into a live session). This design deliberately uses resume-per-batch instead, to stay bash-only; live injection may be a later adapter.
- Concurrent user attachment to the coordinator session *during* an active turn; the user interacts between batches by enqueueing events.
- Migrating an existing hand-authored `COORDINATION.md` or its history into the ledger.
- Concrete `herdr` behavior (the adapter contract is defined; only `tmux.sh` is in scope to implement).
- Auto-merge policy semantics beyond recording `autonomy` and honoring `approve-merge`.
- Changing the worker/critic/researcher role contracts; only their preambles move under `agents/`.

## Further Notes

- Related: open issue #2 ("Extend coordinator to supervise external windowed harnesses (shipwright integration)"). This spec subsumes the delivery half of that work: the queue + relay replaces the tmux-bound relay, and windowed harnesses are the optional launch-adapter contract.
- **Revision history.** Two earlier designs were considered and dropped in this discussion: (1) a blocking `drain.sh` pull loop, rejected because it forces the coordinator's turn to span the whole run; (2) a pty-owning launcher that injects wake tokens, rejected because pty injection needs `python`/`node`. The final model is worker-enqueue → ordered queue → serial relay → resume, which is push, keeps the coordinator free, coalesces concurrent finishes, and stays entirely in bash.
- Design principle to preserve through implementation: **environment changes convenience, never semantics.** With every adapter disabled and one harness installed, the core scripts run the loop unchanged.
