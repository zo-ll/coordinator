#!/usr/bin/env bash
# Launch one role, detached, in its worktree, and record the dispatch.
#
#   spawn.sh --role <critic|researcher|worker> --prompt <brief> --worktree <dir> [--slice <id>]
#     -> SPAWN <role> slice=<id> pid=<pid> wt=<path> log=<path>
#
# Role -> harness/model comes from config.conf (critic.*, researcher.*, or
# lane.default.* for a worker). The argv comes from invoke.sh; this script only
# launches it. Output goes to $COORD_ROOT/log/<role>[.<slice>].log.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/cfg.sh"
INVOKE="$HERE/invoke.sh"
STATE="$HERE/state.sh"
CONFIG="${COORD_CONFIG:-$PWD/.coordinator/config.conf}"
COORD_ROOT="${COORD_ROOT:-/tmp/coordinator}"
adapters_dir="${COORD_ADAPTERS:-$HERE/../adapters}"

role=""; prompt=""; wt=""; slice=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role)     role="$2";   shift 2 ;;
    --prompt)   prompt="$2"; shift 2 ;;
    --worktree) wt="$2";     shift 2 ;;
    --slice)    slice="$2";  shift 2 ;;
    *) echo "spawn.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$role" ] && [ -n "$prompt" ] && [ -n "$wt" ] || {
  echo "spawn.sh: --role, --prompt and --worktree are required" >&2
  exit 2
}
[ -r "$prompt" ] || { echo "spawn.sh: prompt file not readable: $prompt" >&2; exit 1; }

case "$role" in
  critic)     hkey=critic.harness;     mkey=critic.model ;;
  researcher) hkey=researcher.harness; mkey=researcher.model ;;
  worker)     hkey=lane.default.harness; mkey=lane.default.model ;;
  *) echo "spawn.sh: unknown role: $role" >&2; exit 2 ;;
esac

# The finish contract is MECHANICAL: it must not depend on the coordinator
# remembering to write it. Append the exact contract to the brief so every
# worker/critic can always finish — the worker's --event is the slice id
# (plus round), the critic's is <id>.critic with a template it fills in.
if [ -n "$slice" ]; then
  round="$("$STATE" get "$slice" round 2>/dev/null || echo 1)"
  if [ "$round" -gt 1 ] 2>/dev/null; then wslug="$slice.r$round"; else wslug="$slice"; fi
  case "$role" in
    worker)
      cp "$prompt" "$prompt.finish"
      cat >> "$prompt.finish" <<EOF

FINISH CONTRACT (do not skip; this is the completion protocol):
$HERE/finish.sh --event $wslug --role worker --result done --head - --summary "<one line>"
EOF
      prompt="$prompt.finish"
      ;;
    critic)
      cp "$prompt" "$prompt.finish"
      cat >> "$prompt.finish" <<EOF

FINISH CONTRACT (do not skip; this is the completion protocol):
$HERE/finish.sh --event $slice.critic --role critic --result <pass|handback> --head <hash>
where <hash> = git diff HEAD | sha256sum | cut -d' ' -f1, run in this worktree.
EOF
      prompt="$prompt.finish"
      ;;
  esac
fi

h="$("$CFG" get "$CONFIG" "$hkey")" || { echo "spawn.sh: no $hkey in $CONFIG" >&2; exit 1; }
m="$("$CFG" get "$CONFIG" "$mkey" 2>/dev/null || true)"

mapfile -d '' -t argv < <("$INVOKE" "$h" "$role" "$prompt" "$wt" "$m")
[ "${#argv[@]}" -gt 0 ] || {
  echo "spawn.sh: no argv for role '$role' (harness '$h'): check the exec recipe and the brief" >&2
  exit 1
}

logdir="$COORD_ROOT/log"
mkdir -p "$logdir"
log="$logdir/$role${slice:+.$slice}.log"

launch() {
  local wt="$1" log="$2"
  shift 2
  local adapters name a
  adapters="$("$CFG" get "$CONFIG" adapters 2>/dev/null || true)"
  for name in ${adapters//,/ }; do
    [ -z "$name" ] && continue
    [ "$name" = "none" ] && continue
    a="$adapters_dir/$name.sh"
    [ -f "$a" ] || continue
    # shellcheck source=/dev/null
    . "$a"
    if ADAPTER_NAME="$role" adapter_launch "$wt" "$log" "$@"; then return 0; fi
  done
  ( cd "$wt" && setsid "$@" >>"$log" 2>&1 & echo $! )
}

pid="$(launch "$wt" "$log" "${argv[@]}")"

if [ -n "$slice" ]; then
  branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  "$STATE" dispatch "$slice" "$pid" "$wt" "$branch" "$slice" >/dev/null
fi

printf 'SPAWN %s slice=%s pid=%s wt=%s log=%s\n' \
  "$role" "${slice:-none}" "$pid" "$wt" "$log"
