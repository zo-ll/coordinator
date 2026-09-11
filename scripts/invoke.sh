#!/usr/bin/env bash
# Build a role's argv from the env.conf exec recipe. Prints the argv
# NUL-separated (tokens may contain spaces/newlines), runs nothing.
#
#   invoke.sh <harness> <role> <prompt-file> <cwd> [model]
#
# Recipe: '|'-separated argv template with placeholders
#   __CWD__     -> the role's working directory
#   __PROMPT__  -> role preamble (if present) + brief text
#   __MODEL__   -> the model value; if empty, this token AND the token before it
#                  (the model flag) are dropped
# The role preamble is agents/<role>.md unless COORD_AGENTS overrides the dir.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/cfg.sh"
COORD_HOME="${COORD_HOME:-$HOME/.coordinator}"
ENV_CONF="${COORD_ENV_CONF:-$COORD_HOME/env.conf}"
agents_dir="${COORD_AGENTS:-$HERE/../agents}"

harness="${1:?harness}"
role="${2:?role}"
prompt="${3:?prompt-file}"
cwd="${4:?cwd}"
model="${5:-}"

[ -r "$prompt" ] || { echo "invoke: prompt file not readable: $prompt" >&2; exit 1; }

recipe="$("$CFG" get "$ENV_CONF" "harness.$harness.exec")" || {
  echo "invoke: no exec recipe for harness '$harness' in $ENV_CONF" >&2
  exit 1
}

text="$(cat "$prompt")"
if [ -f "$agents_dir/$role.md" ]; then
  text="$(cat "$agents_dir/$role.md")

$text"
fi

IFS='|' read -r -a toks <<< "$recipe"
out=()
for t in "${toks[@]}"; do
  case "$t" in
    __CWD__)    out+=("$cwd") ;;
    __PROMPT__) out+=("$text") ;;
    __MODEL__)
      if [ -n "$model" ]; then
        out+=("$model")
      elif [ "${#out[@]}" -gt 0 ]; then
        unset "out[$(( ${#out[@]} - 1 ))]"
      fi
      ;;
    *) out+=("$t") ;;
  esac
done

for t in "${out[@]}"; do printf '%s\0' "$t"; done
