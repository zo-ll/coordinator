# coordinator

Multi-agent orchestration protocol. See [SPEC.md](SPEC.md) (implemented) and
[SPEC-v2.md](SPEC-v2.md) (draft; migration phases 1–2 done).

## Conventions

- The engine is one Go binary, `cmd/coord` (standard library only, no cgo).
  `scripts/<name>.sh` are shims that exec `bin/coord <verb>` via
  `scripts/lib/exec.sh`, which rebuilds the binary when a Go source is newer.
- Shell files are `#!/usr/bin/env bash` with `set -euo pipefail`.
- Commands print one short line and exit nonzero on failure. No `eval`.
- Config and state are plain files; `coord` is the only parser.
- No `python`, `node`, or `tmux` dependency in the core; Go is needed only to
  build.
- Run state is one append-only log, `<repo>/.coordinator/events.jsonl`
  (`$COORD_EVENTS`); the queue and the ledger are projections of it.
  Machine-local runtime files (role logs, batches, the relay lock) live under
  `$COORD_ROOT` (default `/tmp/coordinator`).

## Tests

```sh
test/run.sh
```

`run.sh` vets and builds `bin/coord`, then each `test/*.test.sh` runs in its own temp dir and asserts on stdout, exit
status, and resulting files. No network, no real agents. Run before committing.
