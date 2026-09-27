#!/usr/bin/env bash
# Detect the environment and write $COORD_HOME/env.conf.
#
#   detect.sh   -> DETECT current=<h> installed=<a,b> spawnable=<a,b>
#
# Current harness: env sentinel first, else walk the ancestor process chain.
# Installed: command -v over the known list (override with COORD_KNOWN).
# Spawnable: installed AND we know an exec recipe for it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/cfg.sh"
COORD_HOME="${COORD_HOME:-$HOME/.coordinator}"
ENV_CONF="${COORD_ENV_CONF:-$COORD_HOME/env.conf}"
mkdir -p "$COORD_HOME"

read -r -a KNOWN <<< "${COORD_KNOWN:-codex claude pi opencode crush goose devin gemini}"

exec_recipe() {
  case "$1" in
    codex)  echo 'codex|exec|-C|__CWD__|-m|__MODEL__|--dangerously-bypass-approvals-and-sandbox|__PROMPT__' ;;
    claude) echo 'claude|-p|--model|__MODEL__|--dangerously-skip-permissions|__PROMPT__' ;;
    pi)     echo 'pi|-p|--model|__MODEL__|__PROMPT__' ;;
    opencode) echo 'opencode|run|--auto|__PROMPT__' ;;
    *) return 1 ;;
  esac
}

resume_recipe() {
  case "$1" in
    codex)  echo 'codex|queue|--thread|__SESSION__|--message|__BATCH__' ;;
    claude) echo 'claude|-p|--resume|__SESSION__|--dangerously-skip-permissions|__BATCH__' ;;
    pi)     echo 'pi|-p|--session|__SESSION__|__BATCH__' ;;
    opencode) echo 'opencode|run|--session|__SESSION__|--auto|__BATCH__' ;;
    *) return 1 ;;
  esac
}

join_by() { local IFS="$1"; shift; printf '%s' "$*"; }

# current harness: the nearest harness among our ancestors, since env vars
# leak into nested harnesses (codex started from claude still has CLAUDECODE);
# env sentinels only when the walk finds none. COORD_CURRENT overrides both.
current="${COORD_CURRENT:-}"
source="unknown"; [ -z "$current" ] || source=override
pid="$PPID"
for _ in $(seq 1 12); do
  [ -z "$current" ] || break
  comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')" || break
  [ -n "$comm" ] || break
  base="${comm##*/}"
  for h in "${KNOWN[@]}"; do
    if [ "$base" = "$h" ]; then current="$h"; source=ancestor; break 2; fi
  done
  pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  { [ -n "$pid" ] && [ "$pid" -gt 1 ]; } || break
done
if [ -z "$current" ]; then
  if [ "${OPENCODE:-}" = "1" ]; then
    current=opencode; source=env
  elif [ -n "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]; then
    current=claude; source=env
  elif [ -n "${PI_CODING_AGENT_SESSION_DIR:-}${PI_SESSION_ID:-}" ]; then
    current=pi; source=env
  elif [ -n "${CODEX_THREAD_ID:-}${CODEX_HOME:-}" ]; then
    current=codex; source=env
  fi
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

: > "$ENV_CONF"
"$CFG" set "$ENV_CONF" current "$current"
"$CFG" set "$ENV_CONF" current_source "$source"
"$CFG" set "$ENV_CONF" installed "$(join_by , "${installed[@]:-}")"
"$CFG" set "$ENV_CONF" spawnable "$(join_by , "${spawnable[@]:-}")"
for h in "${spawnable[@]:-}"; do
  [ -n "$h" ] || continue
  "$CFG" set "$ENV_CONF" "harness.$h.bin" "$(command -v "$h")"
  "$CFG" set "$ENV_CONF" "harness.$h.exec" "$(exec_recipe "$h")"
  "$CFG" set "$ENV_CONF" "harness.$h.resume" "$(resume_recipe "$h")"
done

printf 'DETECT current=%s installed=%s spawnable=%s\n' \
  "${current:-none}" "$(join_by , "${installed[@]:-}")" "$(join_by , "${spawnable[@]:-}")"
