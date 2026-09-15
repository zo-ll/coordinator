#!/usr/bin/env bash
# Detect the environment and write $COORD_HOME/env.conf.
#
#   detect.sh   -> DETECT current=<h> installed=<a,b> spawnable=<a,b> tmux=0|1 gh=0|1
#
# Current harness: env sentinel first, else walk the ancestor process chain.
# Installed: command -v over the known list (override with COORD_KNOWN).
# Spawnable: installed AND we know an exec recipe for it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/progress.sh"
progress_start detect
CFG="$HERE/cfg.sh"
COORD_HOME="${COORD_HOME:-$HOME/.coordinator}"
ENV_CONF="${COORD_ENV_CONF:-$COORD_HOME/env.conf}"
mkdir -p "$COORD_HOME"

read -r -a KNOWN <<< "${COORD_KNOWN:-codex claude pi opencode crush goose devin gemini}"

exec_recipe() {
  case "$1" in
    codex)  echo "env|CODEX_HOME=$(readlink -f "${HOME}/.codex" 2>/dev/null || echo "$HOME/.codex")|codex|exec|-C|__CWD__|--dangerously-bypass-approvals-and-sandbox|__PROMPT__" ;;
    claude) echo 'claude|-p|--dangerously-skip-permissions|__PROMPT__' ;;
    pi)     echo 'pi|__PROMPT__' ;;
    opencode) echo 'opencode|run|--auto|__PROMPT__' ;;
    *) return 1 ;;
  esac
}

resume_recipe() {
  case "$1" in
    codex)  echo 'codex|queue|--thread|__SESSION__|--message|__BATCH__' ;;
    claude) echo 'claude|-p|--resume|__SESSION__|--dangerously-skip-permissions|__BATCH__' ;;
    pi)     echo 'pi|--resume|__SESSION__|__BATCH__' ;;
    opencode) echo 'opencode|run|--attach|__SERVER__|--session|__SESSION__|__BATCH__' ;;
    *) return 1 ;;
  esac
}

join_by() { local IFS="$1"; shift; printf '%s' "$*"; }

# current harness: env sentinels
current=""
source="unknown"
if [ "${OPENCODE:-}" = "1" ]; then
  current=opencode; source=env
elif [ -n "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]; then
  current=claude; source=env
elif [ -n "${PI_CODING_AGENT_SESSION_DIR:-}${PI_SESSION_ID:-}" ]; then
  current=pi; source=env
elif [ -n "${CODEX_HOME:-}" ]; then
  current=codex; source=env
fi

# ancestor-walk fallback
if [ -z "$current" ]; then
  pid="$PPID"
  for _ in $(seq 1 12); do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')" || break
    [ -n "$comm" ] || break
    base="${comm##*/}"
    for h in "${KNOWN[@]}"; do
      if [ "$base" = "$h" ]; then current="$h"; source=ancestor; break 2; fi
    done
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    { [ -n "$pid" ] && [ "$pid" -gt 1 ]; } || break
  done
fi

# installed / spawnable
installed=()
for h in "${KNOWN[@]}"; do
  command -v "$h" >/dev/null 2>&1 && installed+=("$h")
done
spawnable=()
for h in "${installed[@]}"; do
  exec_recipe "$h" >/dev/null 2>&1 && spawnable+=("$h")
done

tmux=0; command -v tmux >/dev/null 2>&1 && tmux=1
tmux_inside=0; [ -n "${TMUX:-}" ] && tmux_inside=1
gh=0; command -v gh >/dev/null 2>&1 && gh=1
glab=0; command -v glab >/dev/null 2>&1 && glab=1
git=0; command -v git >/dev/null 2>&1 && git=1

: > "$ENV_CONF"
"$CFG" set "$ENV_CONF" current "$current"
"$CFG" set "$ENV_CONF" current_source "$source"
"$CFG" set "$ENV_CONF" installed "$(join_by , "${installed[@]:-}")"
"$CFG" set "$ENV_CONF" spawnable "$(join_by , "${spawnable[@]:-}")"
"$CFG" set "$ENV_CONF" tmux "$tmux"
"$CFG" set "$ENV_CONF" tmux_inside "$tmux_inside"
"$CFG" set "$ENV_CONF" gh "$gh"
"$CFG" set "$ENV_CONF" glab "$glab"
"$CFG" set "$ENV_CONF" git "$git"
for h in "${spawnable[@]:-}"; do
  [ -n "$h" ] || continue
  "$CFG" set "$ENV_CONF" "harness.$h.bin" "$(command -v "$h")"
  "$CFG" set "$ENV_CONF" "harness.$h.exec" "$(exec_recipe "$h")"
  "$CFG" set "$ENV_CONF" "harness.$h.resume" "$(resume_recipe "$h")"
done

progress_note="current=${current:-none} installed=$(join_by , "${installed[@]:-}") spawnable=$(join_by , "${spawnable[@]:-}") tmux=$tmux; detection does not prove a real harness turn works"
printf 'DETECT current=%s installed=%s spawnable=%s tmux=%s gh=%s\n' \
  "${current:-none}" "$(join_by , "${installed[@]:-}")" "$(join_by , "${spawnable[@]:-}")" "$tmux" "$gh"
