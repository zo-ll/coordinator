#!/usr/bin/env bash
# Launch one role, detached, in its worktree, and record the dispatch.
#
#   spawn.sh --role <critic|researcher|worker> --prompt <brief> --worktree <dir>
#            [--slice <id>] [--risk <class>]
#     -> SPAWN <role> slice=<id> pid=<pid> wt=<path> log=<path>
#
# Role -> harness/model comes from config.conf (critic.*, researcher.*, or
# lane.<lane>.* for a worker, where <lane> = routing.<risk>; no --risk means
# lane.default). The argv comes from invoke.sh; this script only launches it.
# Output goes to $COORD_ROOT/log/<role>[.<slice>].log.
#
# The brief is refused unless it carries its role's header lines (`FIELD:` at
# line start): worker GOAL SCOPE ACCEPTANCE VERIFY; critic ACCEPTANCE;
# researcher GOAL. A field you cannot fill is a slice you have not scoped.
#
# The launched prompt is: brief, then the standing orders
# ($COORD_STANDING, default <config dir>/standing.md) verbatim, then the
# finish contract.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/cfg.sh"
INVOKE="$HERE/invoke.sh"
STATE="$HERE/state.sh"
CONFIG="${COORD_CONFIG:-$PWD/.coordinator/config.conf}"
COORD_ROOT="${COORD_ROOT:-/tmp/coordinator}"
adapters_dir="${COORD_ADAPTERS:-$HERE/../adapters}"

STANDING="${COORD_STANDING:-$(dirname "$CONFIG")/standing.md}"

role=""; prompt=""; wt=""; slice=""; risk=""
while [ $# -gt 0 ]; do
  case "$1" in
    --role)     role="$2";   shift 2 ;;
    --prompt)   prompt="$2"; shift 2 ;;
    --worktree) wt="$2";     shift 2 ;;
    --slice)    slice="$2";  shift 2 ;;
    --risk)     risk="$2";   shift 2 ;;
    *) echo "spawn.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$role" ] && [ -n "$prompt" ] && [ -n "$wt" ] || {
  echo "spawn.sh: --role, --prompt and --worktree are required" >&2
  exit 2
}
[ -r "$prompt" ] || { echo "spawn.sh: prompt file not readable: $prompt" >&2; exit 1; }
# a worker or critic IS a slice round; without --slice the finish contract
# cannot be appended and the role cannot be recorded (see issue #5)
if [ "$role" != researcher ] && [ -z "$slice" ]; then
  echo "spawn.sh: --slice is required for role '$role' (finish contract + ledger)" >&2
  exit 2
fi

[ -z "$risk" ] || [ "$role" = worker ] || {
  echo "spawn.sh: --risk applies to workers only" >&2
  exit 2
}

case "$role" in
  critic)     hkey=critic.harness;     mkey=critic.model;     need="ACCEPTANCE" ;;
  researcher) hkey=researcher.harness; mkey=researcher.model; need="GOAL" ;;
  worker)
    lane=default
    if [ -n "$risk" ]; then
      lane="$("$CFG" get "$CONFIG" "routing.$risk" 2>/dev/null)" || {
        echo "spawn.sh: no routing.$risk in $CONFIG" >&2
        exit 1
      }
    fi
    hkey="lane.$lane.harness"; mkey="lane.$lane.model"
    need="GOAL SCOPE ACCEPTANCE VERIFY"
    ;;
  *) echo "spawn.sh: unknown role: $role" >&2; exit 2 ;;
esac

missing=""
for f in $need; do
  grep -q "^$f:" "$prompt" || missing="$missing $f"
done
[ -z "$missing" ] || {
  echo "spawn.sh: brief missing${missing} (a $role brief needs: $need)" >&2
  exit 1
}

# The composed prompt: the brief, the standing orders verbatim (directives
# decay across rounds unless every launch carries them), then the finish
# contract. The finish contract is MECHANICAL: it must not depend on the
# coordinator remembering to write it — the worker's --event is the slice id
# (plus round), the critic's is the same plus .critic, filled in by the critic.
sent="$prompt.sent"
cp "$prompt" "$sent"
if [ -s "$STANDING" ]; then
  { printf '\nSTANDING ORDERS (apply to everything you do):\n'; cat "$STANDING"; } >> "$sent"
fi
prompt="$sent"

fslug=""
if [ -n "$slice" ]; then
  round="$("$STATE" get "$slice" round 2>/dev/null || echo 1)"
  if [ "$round" -gt 1 ] 2>/dev/null; then wslug="$slice.r$round"; else wslug="$slice"; fi
  case "$role" in
    worker)
      fslug="$wslug"
      cat >> "$sent" <<EOF

FINISH CONTRACT (do not skip; this is the completion protocol):
$HERE/finish.sh --event $fslug --role worker --result done --head - --summary "<one line>"
EOF
      ;;
    critic)
      fslug="$wslug.critic"
      cat >> "$sent" <<EOF

FINISH CONTRACT (do not skip; this is the completion protocol):
$HERE/finish.sh --event $fslug --role critic --result <pass|handback> --head <hash>
where <hash> = git diff HEAD | sha256sum | cut -d' ' -f1, run in this worktree.
EOF
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
  # task = the finish slug this launch owes; the relay reports a DIED event
  # when the pid is gone and that slug was never enqueued
  "$STATE" dispatch "$slice" "$pid" "$wt" "$branch" "$fslug" >/dev/null
fi

printf 'SPAWN %s slice=%s pid=%s wt=%s log=%s\n' \
  "$role" "${slice:-none}" "$pid" "$wt" "$log"
