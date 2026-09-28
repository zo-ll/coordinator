#!/usr/bin/env bash
# filo start: records the real session id, sets up .filo/ hygiene,
# starts the relay with the resume recipe pinned into config.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
unset PI_SESSION_ID FILO_SESSION CODEX_THREAD_ID CLAUDE_CODE_SESSION_ID
printf 'current=codex\nharness.codex.resume=codex|exec|resume|__SESSION__|__BATCH__\n' > "$FILO_ENV_CONF"
cd "$REPO"
printf 'user work\n' > staged.txt
git add staged.txt

out="$("$FILO" start --session test-sess --no-relay)"
assert "$out" "SESSION test-sess source=user harness=codex repo=$REPO"
assert "$(cat .filo/session)" "test-sess"
assert "$(git diff --cached --name-only)" "staged.txt"
if git show HEAD:staged.txt >/dev/null 2>&1; then echo "  boot committed unrelated staged work"; exit 1; fi
# run state is ignored, committed choices are not
git log --oneline | grep -q 'ignore run state in .filo/' || { echo "  .filo/.gitignore not committed"; exit 1; }
git check-ignore -q .filo/events.log || { echo "  event log not ignored"; exit 1; }
git check-ignore -q .filo/worktrees/x/file || { echo "  worktrees not ignored"; exit 1; }
if git check-ignore -q .filo/config.conf; then echo "  config.conf ignored"; exit 1; fi
if git check-ignore -q .filo/playbooks/feature.md; then echo "  playbooks ignored"; exit 1; fi
grep -q bypassPermissions .claude/settings.local.json || { echo "  claude settings missing"; exit 1; }
assert "$(git show --pretty=format: --name-only HEAD | sed '/^$/d')" ".claude/settings.local.json"

# starts a detached relay for this run, pinning the resume recipe
out="$("$FILO" start --session s2)"
has "$out" "RELAY pid="
pid="${out##*RELAY pid=}"
kill -0 "$pid" || { echo "  relay not alive"; exit 1; }
assert "$("$FILO" cfg get .filo/config.conf relay.resume)" "codex|exec|resume|__SESSION__|__BATCH__"
wait_for test -f .filo/relay.pid
has "$("$FILO" status | head -n1)" "relay=$pid alive=1"
kill "$pid"

# a harness's own session variable wins over scanning session files
has "$(CODEX_THREAD_ID=thread-9 "$FILO" start --no-relay)" "SESSION thread-9 source=codex-env"

# no invented ids: an unresolvable session is a loud failure
printf 'current=pi\n' > "$FILO_ENV_CONF"
refuses "no resumable session id" "$FILO" start --no-relay

echo "  start ok"
