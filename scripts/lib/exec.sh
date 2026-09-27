# Sourced by every scripts/*.sh shim as: . lib/exec.sh <verb> "$@"
# Runs bin/coord <verb>, rebuilding it first when a Go source is newer than
# the binary and `go` is on PATH, so a `git pull` stays live.
coord_scripts="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
coord_root="${coord_scripts%/*}"
coord_bin="${COORD_BIN:-$coord_root/bin/coord}"

if [ -z "${COORD_BIN:-}" ]; then
  coord_stale=0
  if [ ! -x "$coord_bin" ]; then
    coord_stale=1
  else
    for f in "$coord_root"/go.mod "$coord_root"/cmd/coord/*.go "$coord_root"/internal/*/*.go; do
      if [ "$f" -nt "$coord_bin" ]; then coord_stale=1; break; fi
    done
  fi
  if [ "$coord_stale" = 1 ]; then
    if command -v go >/dev/null 2>&1; then
      (cd "$coord_root" && go build -o "$coord_bin.$$" ./cmd/coord && mv -f "$coord_bin.$$" "$coord_bin") >&2 || {
        echo "coordinator: go build failed" >&2; exit 1; }
    elif [ ! -x "$coord_bin" ]; then
      echo "coordinator: $coord_bin is missing and go is not on PATH; run bin/install.sh" >&2
      exit 1
    fi
  fi
fi

export COORD_SCRIPTS="$coord_scripts"
exec "$coord_bin" "$@"
