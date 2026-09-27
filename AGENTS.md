# coordinator

Multi-agent protocol for producing software. See [SPEC-v2.md](SPEC-v2.md).

## Conventions

- The engine is bash: `bin/coord` dispatches to `lib/cmd.sh`; `lib/core.sh`
  holds the shared plumbing; `lib/model.awk` is the state machine; `libexec/`
  holds the boot scripts (cfg, detect, plan, apply). Nothing to build.
- Commands print one short line and exit nonzero on failure; refusals are
  `REFUSED <unit> <event>: <reason>`. No `eval`; config is parsed, never run.
- Run state is one append-only log, `<repo>/.coordinator/events.log`
  (`$COORD_EVENTS`): one event per line, tab-separated `key=value` fields,
  ending in a lone `.` field (a line without it is a torn write and is
  ignored). Every write goes through `commit` in `lib/core.sh`, which checks it
  against `lib/model.awk`; unit and delivery state are projections of the log.
- Everything a run creates lives in `<repo>/.coordinator/`; only `config.conf`,
  `standing.md`, and `playbooks/` there are committed.
- Behavior that is judgment belongs in `SKILL.md`, `agents/`, or `playbooks/`;
  behavior that is shape (fields, rounds, transitions, evidence, timeouts)
  belongs in code with a test.
- bash 4.4+, coreutils, util-linux (`flock`, `setsid`), awk, git. No `python`,
  `node`, or `tmux` dependency in the core; a terminal multiplexer is optional.
- Every shell file is `#!/usr/bin/env bash` with `set -euo pipefail`. Mind
  `pipefail`: a pipeline whose first command may exit nonzero on purpose needs
  `|| true`, or `set -e` ends the command silently.
- A lock's file descriptor must never reach a long-lived child: `launch` and
  `resume` close `COMMIT_LOCK` / `RELAY_LOCK` before starting an agent.

## Tests

```sh
test/run.sh
```

Each `test/*.test.sh` sources `test/lib.sh`, runs in its own temp repo with a
fake harness, and asserts on exit status, the output line, and the event log.
`model.test.sh` is the transition table for `lib/model.awk`. No network, no
real agents. Run before committing.
