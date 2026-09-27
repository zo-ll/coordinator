# coordinator

A harness-agnostic multi-agent protocol for producing software: a coordinator
agent cuts a goal into typed units, workers build them in isolated git
worktrees, independent critics review them against evidence rules, and the
engine merges only approved work whose checks it re-runs itself.

[SPEC-v2.md](SPEC-v2.md) is the design. The engine is bash (`bin/coord`, with
`lib/` and `libexec/`): nothing to build or install beyond bash 4.4+,
coreutils, util-linux, awk and git. No `tmux`, `python`, or `node`, and one
installed agent harness (codex, claude, pi, opencode, …) is enough.

## How it works

- **Units and playbooks.** `coord unit add <id> --kind feature|bugfix|refactor|chore`.
  The kind's playbook (`playbooks/<kind>.md`, overridable per repo) sets the
  brief fields a worker needs, what worker and critic are told, the evidence a
  pass needs, and the timebox.
- **One event log.** `.coordinator/events.log` is the only state. Every write
  is checked against the unit state machine (`lib/model.awk`); illegal moves
  are refused, not recorded.
- **Dispatch.** `coord dispatch <id> --role worker --brief <file>` validates
  the brief, creates the worktree, computes the round and finish slug, and
  launches the harness detached. `--role critic` writes the critic's brief
  from the worker brief's criteria — never the coordinator's framing.
- **Evidence.** A critic's pass carries a level (`none < typecheck < tests <
  live`), the commands it ran, and flags such as `red-green`; below the
  playbook's floor it becomes a handback.
- **Merge.** `coord merge <id>` needs approval (or `autonomy=auto-merge`), the
  exact reviewed state, and a passing re-run of the brief's VERIFY commands;
  then it commits with the user's identity and merges.
- **Relay.** `coord relay` wakes the coordinator with one batch per wave of
  events, reports dead launches, kills launches past their timebox, and blocks
  a unit that dies twice in a round.
- **Shapes.** `shapes/` holds light recipes the coordinator picks from: swarm
  (parallel units), arena (competing attempts, a judge picks one), interrogate
  (extra reviewers on risky units). Small jobs skip the ceremony, and
  reversible questions become gates with a default instead of blocking.
- `SKILL.md` is what the coordinator agent loads; `agents/` are the role
  preambles; `adapters/` are optional launch overrides (tmux).

## Install

```sh
bin/install.sh              # symlink this repo as <harness>/coordinator
bin/install.sh --uninstall  # remove those symlinks
```

The repo root is the skill, symlinked into every harness skill dir found on
the machine, so edits and `git pull` stay live.

## Tests

```sh
test/run.sh
```

Each `test/*.test.sh` drives `bin/coord` in its own temp repo with a fake
harness; `model.test.sh` is the state machine's transition table. No network,
no real agents.