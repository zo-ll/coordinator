# coordinator

A harness-agnostic, script-driven, barebones multi-agent orchestration protocol.

[SPEC.md](SPEC.md) is the design; the implementation is one static Go binary,
`bin/coord` (built from `cmd/coord`), behind the `scripts/*.sh` contracts — no
`tmux`, `python`, or `node` required. One installed harness is enough.
[SPEC-v2.md](SPEC-v2.md) is the draft of what comes next.

## How it works

- `scripts/detect.sh` / `plan.sh` / `apply.sh` — boot: detect the environment,
  propose a config, ask only what detection cannot decide, validate, write.
- `scripts/queue.sh` + `finish.sh` — finished work is a recovery marker plus an
  ordered, de-duplicated ping in the run's event log
  (`.coordinator/events.jsonl`), the single source of truth.
- `scripts/relay.sh` — the serial consumer: batches everything pending and
  resumes the coordinator session via a config-driven command (`wake`).
- `scripts/state.sh` — the slice ledger (a projection of the event log);
  `render` writes `COORDINATION.md`.
- `scripts/worktree.sh`, `invoke.sh`, `spawn.sh` — dispatch a role detached.
- `scripts/merge.sh` — HEAD-bound, approval-gated merge.
- `scripts/coord.sh` — launcher: pins the session id and starts the relay.
- `agents/` — role preambles; `adapters/` — optional launch overrides.
- `SKILL.md` — the dispatcher an agent loads.

## Install

```sh
bin/install.sh              # build bin/coord (needs go), symlink this repo as <harness>/coordinator
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
