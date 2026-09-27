# coordinator

Multi-agent protocol for producing software. See [SPEC-v2.md](SPEC-v2.md).

## Conventions

- The engine is one Go binary, `cmd/coord` (standard library only, no cgo).
  `bin/coord` rebuilds itself when a Go source is newer and `go` is on PATH.
- Commands print one short line and exit nonzero on failure; refusals are
  `REFUSED <unit> <event>: <reason>`. No `eval`; config is parsed, never run.
- Run state is one append-only log, `<repo>/.coordinator/events.jsonl`
  (`$COORD_EVENTS`). Every write goes through the state machine in
  `internal/model`; unit and delivery state are projections of the log.
- Everything a run creates lives in `<repo>/.coordinator/`; only `config.conf`,
  `standing.md`, and `playbooks/` there are committed.
- Behavior that is judgment belongs in `SKILL.md`, `agents/`, or `playbooks/`;
  behavior that is shape (fields, rounds, transitions, evidence, timeouts)
  belongs in code with a test.
- Shell files (`bin/install.sh`, `adapters/`, `test/`) are
  `#!/usr/bin/env bash` with `set -euo pipefail`.
- No `python`, `node`, or `tmux` dependency in the core; Go is needed only to build.

## Tests

```sh
test/run.sh
```

`run.sh` vets, builds `bin/coord`, and runs `go test ./...`; then each
`test/*.test.sh` sources `test/lib.sh`, runs in its own temp repo with a fake
harness, and asserts on exit status, the output line, and the event log. No
network, no real agents. Run before committing.
