# filo

A harness-agnostic multi-agent protocol for producing software: a coordinator
agent cuts a goal into typed units, workers build them in isolated git
worktrees, independent critics review them against evidence rules, and the
engine merges only approved work whose checks it re-runs itself.

[SPEC.md](SPEC.md) is the design; `bin/filo help` is the command
reference. The engine is bash (`bin/filo`, with
`lib/` and `libexec/`): nothing to build or install beyond bash 4.4+,
coreutils, util-linux, awk and git. No `tmux`, `python`, or `node`, and one
installed agent harness (codex, claude, pi, opencode, …) is enough.

## Following a run

`filo watch` is the one command meant for people. Open it in a second
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
  coordinator's judgment; `filo help` documents every command, and every
  wake tells the coordinator what to do next.
- **Units and playbooks.** `filo unit add <id> --kind feature|bugfix|refactor|chore`.
  The kind's playbook (`playbooks/<kind>.md`, overridable per repo) sets the
  brief fields a worker needs, what worker and critic are told, the evidence a
  pass needs, and the timebox.
- **One event log.** `.filo/events.log` is the only state. Every write
  is checked against the unit state machine (`lib/model.awk`); illegal moves
  are refused, not recorded.
- **Dispatch.** `filo brief <id>` drafts the brief to fill in;
  `filo dispatch <id> --role worker` validates it, creates the worktree,
  computes the round and finish slug, and launches the harness detached.
  Every role reports with `filo finish`, which wakes the coordinator. `--role critic` writes the critic's brief
  from the worker brief's criteria — never the coordinator's framing.
- **Roles.** `filo role critic --skill code-review --model <m>` sets a
  role agent's harness, model, and skills, per repo or `--global` for every
  repo; `filo skills` lists what is installed.
- **Evidence.** A critic's pass carries a level (`none < typecheck < tests <
  live`), the commands it ran, and flags such as `red-green`; below the
  playbook's floor it becomes a handback.
- **Merge.** `filo merge <id>` needs approval (or `autonomy=auto-merge`), the
  exact reviewed state, and a passing re-run of the brief's VERIFY commands;
  then it commits with the user's identity and merges locally. Publishing is
  a separate `git push` decision.
- **Relay.** `filo relay` wakes the coordinator with one batch per wave of
  events, each ending in the next step for every unit (`NEXT`, `READY`,
  `DONE`); it reports dead launches, kills launches past their timebox, and
  blocks a unit that dies twice in a round.
- **Shapes.** Independent units run in parallel by default; `shapes/` adds
  arena (competing attempts, a judge picks one) and interrogate (extra
  reviewers on risky units). Small jobs skip the ceremony, and reversible
  questions become gates (`filo gate`) with a default instead of blocking.
- `SKILL.md` is what the coordinator agent loads; `agents/` are the role
  preambles.

## Install

```sh
git clone https://github.com/zo-ll/filo && filo/bin/install.sh
```

That links the skill into every agent harness installed on the machine (pi,
claude, codex, opencode, crush, goose, …: its home dir exists or its command
is on the PATH) and the `filo` command into `~/.local/bin` (`FILO_BIN_DIR` to
change it; it tells you if that dir isn't on your PATH). Run it again any
time: filo links that point at nothing or at another filo checkout are
repointed to this one (the last install wins), and anything else named filo
is left alone. `bin/install.sh --uninstall` removes only its own links (give
it the same `FILO_BIN_DIR` you installed with).

Upgrading from coord: remove any old `<harness>/coordinator` symlinks (the
skill is `filo` now), and move `~/.coordinator/` to `~/.filo/`. A repo's old
`.coordinator/` is not read; set the repo up again with `filo init`.

The repo root is the skill, linked rather than copied, so edits and
`git pull` stay live.

## Tests

```sh
test/run.sh
```

Each `test/*.test.sh` drives `bin/filo` in its own temp repo with a fake
harness; `model.test.sh` is the state machine's transition table. No network,
no real agents.
