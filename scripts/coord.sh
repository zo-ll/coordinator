#!/usr/bin/env bash
# Start a coordinated run: resolve the harness's REAL session id (never an
# invented one — a resume can only wake a session that actually exists),
# record it, and start the relay.
#
#   coord.sh [--harness H] [--session ID] [--no-relay]
#     -> SESSION <id> source=<user|env|pi-env|codex-sessions> harness=<h> repo=<repo>
#        [+ RELAY pid=<pid>]
#
# Session id resolution order: --session arg, then COORD_SESSION, then the
# harness's own current session (pi: $PI_SESSION_ID; codex: the newest rollout
# in $CODEX_HOME/sessions, i.e. the live TUI session at boot). If none can be
# resolved, coord fails loudly instead of recording a fake id.
#
#   coord.sh approve <id>   -> APPROVED <id>
#
# approve is the ONLY writer of $COORD_ROOT/approvals/<id> (merge.sh's gate).
# It refuses under COORD_HEADLESS=1 — a resumed headless coordinator turn runs
# with that set and can never call it successfully, so a turn cannot record
# approval for its own merge question. Run it from a human's own terminal.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/cfg.sh"
COORD_HOME="${COORD_HOME:-$HOME/.coordinator}"
ENV_CONF="${COORD_ENV_CONF:-$COORD_HOME/env.conf}"
source "$HERE/queue.sh"
source "$HERE/progress.sh"
progress_start coord
repo="${COORD_REPO:-$PWD}"

if [ "${1:-}" = "approve" ]; then
  shift
  slice="${1:?coord.sh approve: slice id required}"
  if [ "${COORD_HEADLESS:-0}" = "1" ]; then
    echo "coord: refusing to record approval for '$slice' — this is a headless resumed turn (COORD_HEADLESS=1); a coordinator turn may never approve its own merge. Run 'coord.sh approve $slice' from a human's own terminal." >&2
    exit 1
  fi
  mkdir -p "$COORD_ROOT/approvals"
  : > "$COORD_ROOT/approvals/$slice"
  progress_note="approval recorded for slice=$slice; this command does not enqueue a wake; coordinator must run merge.sh --slice $slice"
  printf 'APPROVED %s\n' "$slice"
  exit 0
fi

harness=""
session=""
start_relay=1
while [ $# -gt 0 ]; do
  case "$1" in
    --harness)  harness="$2"; shift 2 ;;
    --session)  session="$2"; shift 2 ;;
    --no-relay) start_relay=0; shift ;;
    *) echo "coord.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

resolve_session() { # -> "<id> <source>" on one line ; nonzero if unknown
  [ -n "${1:-}" ] && { printf '%s user\n' "$1"; return 0; }
  [ -n "${COORD_SESSION:-}" ] && { printf '%s env\n' "$COORD_SESSION"; return 0; }
  case "$harness" in
    pi)
      [ -n "${PI_SESSION_ID:-}" ] && { printf '%s pi-env\n' "$PI_SESSION_ID"; return 0; }
      ;;
    codex)
      local dir="${CODEX_HOME:-$HOME/.codex}/sessions" f
      f="$(find "$dir" -name 'rollout-*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)"
      if [ -n "$f" ]; then
        printf '%s codex-sessions\n' \
          "$(basename "$f" .jsonl | awk -F- -v OFS=- '{print $(NF-4),$(NF-3),$(NF-2),$(NF-1),$NF}')"
        return 0
      fi
      ;;
    claude)
      local f
      f="$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" -name '*.jsonl' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)"
      if [ -n "$f" ]; then
        printf '%s claude-projects\n' "$(basename "$f" .jsonl)"
        return 0
      fi
      ;;
    opencode)
      # sessions live in a sqlite store with no reliable read access here;
      # require the coordinator to pass --session explicitly.
      return 1
      ;;
  esac
  return 1
}

[ -n "$harness" ] || harness="$("$CFG" get "$ENV_CONF" current 2>/dev/null || true)"
[ -n "$harness" ] || { echo "coord: no current harness (run detect.sh first)" >&2; exit 1; }

read -r session sid_src < <(resolve_session "$session") || {
  echo "coord: no resumable session id for harness '$harness' — no invented ids." >&2
  echo "  pi:       relies on \$PI_SESSION_ID" >&2
  echo "  codex:    scans \${CODEX_HOME:-~/.codex}/sessions for the live rollout" >&2
  echo "  claude:   scans \${CLAUDE_CONFIG_DIR:-~/.claude}/projects for the live jsonl" >&2
  echo "  opencode: no machine-readable id yet; pass --session from the TUI" >&2
  echo "  fallback: pass --session <the harness's real session id>" >&2
  exit 1
}

mkdir -p "$repo/.coordinator"
# normalize before recording: a codex rollout-derived id can arrive with a
# rollout- prefix or a leading ISO timestamp, which `codex queue --thread`
# rejects ("no active session found"). store the bare id.
session="${session#rollout-}"
session="$(printf '%s' "$session" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}-//')"
printf '%s\n' "$session" > "$repo/.coordinator/session"

printf 'SESSION %s source=%s harness=%s repo=%s\n' "$session" "$sid_src" "$harness" "$repo"
progress_context="harness=$harness session=$session source=$sid_src repo=$repo"
progress_event OK "$progress_context"
case "$sid_src" in
  codex-sessions|claude-projects) progress_event WARN "session chosen from newest file; verify session=$session belongs to this run" ;;
esac
progress_phase hygiene

# repo hygiene: workers use `git add -A`, so keep finish markers out of the
# index from the start. Ensure .gitignore ignores .scratch/ and commit it on
# main (worktrees inherit it) with the user's identity — the first commit the
# coordinator authors in the run.
gi="$repo/.gitignore"
if ! grep -qx '.scratch/' "$gi" 2>/dev/null; then
  printf '.scratch/\n' >> "$gi"
  "$HERE/hygiene-commit.sh" "$repo" .gitignore "[coord] ignore .scratch markers" >/dev/null 2>&1 || progress_event WARN "could not commit .gitignore hygiene; inspect repository state"
fi

# claude repo hygiene: claude grants permissions per process and per allowed
# directory, so auto-resumed coordinator turns and -p workers are write-blocked
# and cannot even reach the coordinator scripts outside the project. A project
# settings file with bypassPermissions makes every claude process in the repo
# run with full permissions — the worker policy, uniformly. Harmless elsewhere.
cs="$repo/.claude/settings.local.json"
if [ -e "$cs" ] && ! grep -q 'bypassPermissions' "$cs"; then
  echo "coord: claude settings exist without bypassPermissions: $cs (merge policy requires full worker perms)" >&2
fi
if [ ! -e "$cs" ]; then
  mkdir -p "$(dirname "$cs")"
  printf '{\n  "permissions": {\n    "defaultMode": "bypassPermissions"\n  }\n}\n' > "$cs"
  "$HERE/hygiene-commit.sh" "$repo" ".claude/settings.local.json" "[coord] claude full permissions" >/dev/null 2>&1 || progress_event WARN "could not commit Claude settings hygiene; inspect repository state"
fi

if [ "$start_relay" = 1 ]; then
  progress_phase relay-launch
  mkdir -p "$COORD_ROOT"
  # pin the resume recipe so the relay never depends on env.conf `current`,
  # which may be unresolved in the coordinator's shell; config is explicit.
  cfgf="$repo/.coordinator/config.conf"
  [ -f "$cfgf" ] || : > "$cfgf"
  rec="$("$CFG" get "$ENV_CONF" "harness.$harness.resume" 2>/dev/null || true)"
  [ -n "$rec" ] && "$CFG" set "$cfgf" relay.resume "$rec"
  COORD_CONFIG="$cfgf" COORD_SESSION="$session" setsid "$HERE/relay.sh" >>"$COORD_ROOT/relay.log" 2>&1 &
  pid="$!"
  printf '%s\n' "$pid" > "$COORD_ROOT/relay.pid"
  printf 'RELAY pid=%s\n' "$pid"
  progress_note="relay launch requested pid=$pid (readiness not yet verified); run $HERE/status.sh --watch; progress=$COORD_ROOT/progress.log"
else
  progress_note="session recorded; relay disabled by --no-relay"
fi
