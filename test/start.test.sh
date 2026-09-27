#!/usr/bin/env bash
# coord start: records the real session id, sets up .coordinator/ hygiene,
# starts the relay with the resume recipe pinned into config.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
unset PI_SESSION_ID COORD_SESSION
printf 'current=codex\nharness.codex.resume=codex|exec|resume|__SESSION__|__BATCH__\n' > "$COORD_ENV_CONF"
cd "$REPO"

out="$("$COORD" start --session test-sess --no-relay)"
assert "$out" "SESSION test-sess source=user harness=codex repo=$REPO"
assert "$(cat .coordinator/session)" "test-sess"
# run state is ignored, committed choices are not
git log --oneline | grep -q 'ignore run state in .coordinator/' || { echo "  .coordinator/.gitignore not committed"; exit 1; }
git check-ignore -q .coordinator/events.jsonl || { echo "  event log not ignored"; exit 1; }
git check-ignore -q .coordinator/worktrees/x/file || { echo "  worktrees not ignored"; exit 1; }
if git check-ignore -q .coordinator/config.conf; then echo "  config.conf ignored"; exit 1; fi
if git check-ignore -q .coordinator/playbooks/feature.md; then echo "  playbooks ignored"; exit 1; fi
grep -q bypassPermissions .claude/settings.local.json || { echo "  claude settings missing"; exit 1; }

# starts a detached relay for this run, pinning the resume recipe
out="$("$COORD" start --session s2)"
has "$out" "RELAY pid="
pid="${out##*RELAY pid=}"
kill -0 "$pid" || { echo "  relay not alive"; exit 1; }
assert "$("$COORD" cfg get .coordinator/config.conf relay.resume)" "codex|exec|resume|__SESSION__|__BATCH__"
wait_for test -f .coordinator/relay.pid
has "$("$COORD" status | head -n1)" "relay=$pid alive=1"
kill "$pid"

# no invented ids: an unresolvable session is a loud failure
printf 'current=pi\n' > "$COORD_ENV_CONF"
refuses "no resumable session id" "$COORD" start --no-relay

echo "  start ok"
