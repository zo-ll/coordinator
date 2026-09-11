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
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/cfg.sh"
COORD_HOME="${COORD_HOME:-$HOME/.coordinator}"
ENV_CONF="${COORD_ENV_CONF:-$COORD_HOME/env.conf}"
COORD_ROOT="${COORD_ROOT:-/tmp/coordinator}"
repo="${COORD_REPO:-$PWD}"

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
printf '%s\n' "$session" > "$repo/.coordinator/session"

printf 'SESSION %s source=%s harness=%s repo=%s\n' "$session" "$sid_src" "$harness" "$repo"

# repo hygiene: workers use `git add -A`, so keep finish markers out of the
# index from the start. Ensure .gitignore ignores .scratch/ and commit it on
# main (worktrees inherit it) with the user's identity — the first commit the
# coordinator authors in the run.
gi="$repo/.gitignore"
if ! grep -qx '.scratch/' "$gi" 2>/dev/null; then
  printf '.scratch/\n' >> "$gi"
  if git -C "$repo" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
    uemail="$(git -C "$repo" config user.email || echo coord@local)"
    uname="$(git -C "$repo" config user.name || echo coordinator)"
    git -C "$repo" add .gitignore
    git -C "$repo" -c user.email="$uemail" -c user.name="$uname" commit -q -m "[coord] ignore .scratch markers"
  fi
fi

if [ "$start_relay" = 1 ]; then
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
fi
