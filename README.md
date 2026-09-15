# coordinator

A harness-agnostic, script-driven, barebones multi-agent orchestration protocol.

[SPEC.md](SPEC.md) is the design; the implementation lives in `scripts/` and is
entirely **bash** — no `tmux`, `python`, or `node` required. One installed
harness is enough.

Normal use is one terminal and one harness for every role. Installing more
harnesses does not add another worker lane. The simultaneous multi-harness
sandboxes in `bin/create-sandbox.sh` are compatibility tests. Launch adapters
such as tmux remain opt-in; existing saved role choices are preserved.

## See each step

Lifecycle commands print `[COORD] START`, `OK`, `WAIT`, `WARN`, or `FAIL` to
stderr and append the same timestamped records to `$COORD_ROOT/progress.log`.
Records identify the script, phase, process, and available slice/role context.
Their normal stdout remains machine-readable. A failed command includes its
exit code and last phase; the original error remains on stderr or in its role
log. No prompts or command arguments are copied into the progress log.

In another plain terminal, from the same project and with the same `COORD_ROOT`
override if you set one:

```sh
/path/to/coordinator/scripts/status.sh --watch
```

Snapshots update when something changes (checked every two seconds).
`--watch --interval 1` checks every second. Ctrl-C stops the viewer; it does
not stop the run. `status.sh` without arguments prints one snapshot and exits
nonzero for a liveness/staleness alarm. It includes recent progress, the last
recorded failure (explicitly labelled as history), and role log tails even
when a process has died. Historical failures are not cleared by later output.

| Step | Evidence shown | What happens next |
|---|---|---|
| Detect | Current and installed harnesses; whether binaries have recipes | Propose setup. Detection does not test a real model turn. |
| Plan | One harness for all roles; `WAIT` for setup answers | Present the `ASK` fields to the user. |
| Apply | Config written; referenced harness binaries resolve | Start coordination. |
| Start | Session ID and its source; relay launch requested | Check relay liveness. A guessed newest session gets a warning. |
| Slice/worktree | Ledger transition, branch, and worktree path | Dispatch the worker. |
| Launch | Role, harness, model, launcher, PID, and log path | Wait for completion; launch success does not mean work succeeded. |
| Worker/critic exits | Exit code; missing completion marker is a failure | Inspect the role log or process its published completion. |
| Finish | Marker written, then event enqueued; duplicates get a warning | Relay claims the pending event. |
| Relay | Batch claimed, wake attempt, retries, command return, queue acknowledgement | Verify that the coordinator updated the slice ledger. |
| Review | PASS or handback recorded in the ledger | Request approval or dispatch corrections. |
| Approval | Approval file recorded; status shows the merge action | Coordinator runs the merge command. Approval currently does not enqueue a wake. |
| Merge | Review/approval gates, state verification, commit, merge, and push | Report local merge and publication separately. A failed push gets `WARN`. |

`WAIT` is an expected pause. `WARN` needs inspection. `FAIL` means the named
step failed. A missing relay with pending events is reported immediately;
stalled delivery and dead slice processes also produce prominent health alarms.
The viewer must be open to see background progress live; the timeline remains
available afterward, and the coordinator checks `status.sh` on each turn.

The relay still acknowledges on a successful wake-command exit. These messages
make that boundary visible; they do not establish that an asynchronous wake
has finished routing the batch. Likewise, a healthy process is not proof of
correct work. The critic and merge checks remain separate steps.

## How it works

- `scripts/detect.sh` / `plan.sh` / `apply.sh` — boot: detect the environment,
  propose a config, ask only what detection cannot decide, validate, write.
- `scripts/queue.sh` + `finish.sh` — finished work is a recovery marker plus an
  ordered, de-duplicated ping.
- `scripts/relay.sh` — the serial consumer: batches everything pending and
  resumes the coordinator session via a config-driven command (`wake`).
- `scripts/state.sh` — the slice ledger; `render` writes `COORDINATION.md`.
- `scripts/worktree.sh`, `invoke.sh`, `spawn.sh` — dispatch a role detached.
- `scripts/merge.sh` — HEAD-bound, approval-gated merge.
- `scripts/coord.sh` — launcher: pins the session id and starts the relay.
- `agents/` — role preambles; `adapters/` — optional launch overrides.
- `SKILL.md` — the dispatcher an agent loads.

## Install

```sh
bin/install.sh              # symlink this repo as <harness>/coordinator
bin/install.sh --uninstall  # remove those symlinks
```

The repo root is the skill, so it is symlinked as a directory into every harness
skill dir found on the machine (pi, `.agents`, claude, codex, opencode, …).
Edits and `git pull` stay live.

## Tests

```sh
test/run.sh
```

Each `test/*.test.sh` runs in its own temp dir and asserts on stdout, exit
status, and resulting files. No network, no real agents.
