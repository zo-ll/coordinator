# coordinator

Bash-only multi-agent orchestration protocol. See [SPEC.md](SPEC.md).

## Conventions

- Every script is `#!/usr/bin/env bash` with `set -euo pipefail`.
- Scripts print one short line and exit nonzero on failure. No `eval`.
- Config and state are plain files; scripts are the only parsers.
- No `python`, `node`, or `tmux` dependency in the core.
- Machine-local runtime state lives under `$COORD_ROOT` (default `/tmp/coordinator`).

## Tests

```sh
test/run.sh
```

Each `test/*.test.sh` runs in its own temp dir and asserts on stdout, exit
status, and resulting files. No network, no real agents. Run before committing.
