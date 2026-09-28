# coordinator

A harness-agnostic multi-agent protocol for producing software: a coordinator
agent cuts a goal into typed units, workers build them in isolated git
worktrees, independent critics review them against evidence rules, and the
engine merges only approved work whose checks it re-runs itself.

[SPEC.md](SPEC.md) is the design; `bin/coord help` is the command
reference. The engine is bash (`bin/coord`, with
`lib/` and `libexec/`): nothing to build or install beyond bash 4.4+,
coreutils, util-linux, awk and git. No `tmux`, `python`, or `node`, and one
installed agent harness (codex, claude, pi, opencode, …) is enough.

## Following a run

`coord watch` is the one command meant for people. Open it in a second
terminal next to your agent: it shows whether the coordinator is moving, the
work in progress (each unit's agent and its latest output, branch, worktree
and changed files), what needs you, and what just happened. Clean critic
passes merge on their own; a pass with notes, a risky unit, a blocked unit, or
an open decision needs you. Select with j/k: `a` approves and merges, `r`
sends back with a note, `m` messages the coordinator, `↵` opens a unit (its
brief, the critic's findings, the diff, the merge's checks, the agent's
output, its history), `?` lists the rest. The mouse works too: click to select and open,
click a key to press it, scroll the feed.

## How it works

- **A lean skill over a self-describing CLI.** `SKILL.md` holds only the
  coordinator's judgment; `coord help` documents every command, and every
  wake tells the coordinator what to do next.
- **Units and playbooks.** `coord unit add <id> --kind feature|bugfix|refactor|chore`.
  The kind's playbook (`playbooks/<kind>.md`, overridable per repo) sets the
  brief fields a worker needs, what worker and critic are told, the evidence a
  pass needs, and the timebox.
- **One event log.** `.coordinator/events.log` is the only state. Every write
  is checked against the unit state machine (`lib/model.awk`); illegal moves
  are refused, not recorded.
- **Dispatch.** `coord brief <id>` drafts the brief to fill in;
  `coord dispatch <id> --role worker` validates it, creates the worktree,
  computes the round and finish slug, and launches the harness detached.
  Every role reports with `coord finish`, which wakes the coordinator. `--role critic` writes the critic's brief
  from the worker brief's criteria — never the coordinator's framing.
- **Roles.** `coord role critic --skill code-review --model <m>` sets a
  role agent's harness, model, and skills, per repo or `--global` for every
  repo; `coord skills` lists what is installed.
- **Evidence.** A critic's pass carries a level (`none < typecheck < tests <
  live`), the commands it ran, and flags such as `red-green`; below the
  playbook's floor it becomes a handback.
- **Merge.** `coord merge <id>` needs approval (or `autonomy=auto-merge`), the
  exact reviewed state, and a passing re-run of the brief's VERIFY commands;
  then it commits with the user's identity and merges locally. Publishing is
  a separate `git push` decision.
- **Relay.** `coord relay` wakes the coordinator with one batch per wave of
  events, each ending in the next step for every unit (`NEXT`, `READY`,
  `DONE`); it reports dead launches, kills launches past their timebox, and
  blocks a unit that dies twice in a round.
- **Shapes.** Independent units run in parallel by default; `shapes/` adds
  arena (competing attempts, a judge picks one) and interrogate (extra
  reviewers on risky units). Small jobs skip the ceremony, and reversible
  questions become gates (`coord gate`) with a default instead of blocking.
- `SKILL.md` is what the coordinator agent loads; `agents/` are the role
  preambles.

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
