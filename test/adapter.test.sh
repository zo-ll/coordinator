#!/usr/bin/env bash
# An enabled launch adapter runs the role and its pid is the one recorded.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"
export COORD_ADAPTERS="$TMP/adapters" ADAPTER_LOG="$TMP/adapter.log"
mkdir -p "$COORD_ADAPTERS"
cat > "$COORD_ADAPTERS/foo.sh" <<'A'
adapter_launch() {
  local cwd="$1" log="$2"
  shift 2
  printf 'cwd=%s name=%s owes=%s\n' "$cwd" "$ADAPTER_NAME" "$COORD_OWES" >> "$ADAPTER_LOG"
  printf '4242'
}
A
printf 'adapters=foo\n' >> "$REPO/.coordinator/config.conf"

"$COORD" unit add a --kind feature --goal one >/dev/null
has "$("$COORD" dispatch a --role worker --brief "$TMP/brief")" "pid=4242"
assert "$(cat "$ADAPTER_LOG")" "cwd=$REPO/.coordinator/worktrees/a name=worker owes=a.r1.worker"

echo "  adapter ok"
