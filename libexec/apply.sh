#!/usr/bin/env bash
# Apply the user's answers over the proposal, validate, and write config.conf.
#
#   apply.sh [--accept] [--answers "critic.model=… autonomy=auto-merge"]
#     -> OK config=<path>  |  FAIL <field>: <reason>
#
# Answers are literal `key=value` dotted config keys (space-separated). Only
# answers given are overlaid onto the proposal; everything else keeps its
# proposed value.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/cfg.sh"
FILO_HOME="${FILO_HOME:-$HOME/.filo}"
ENV_CONF="${FILO_ENV_CONF:-$FILO_HOME/env.conf}"
PROPOSAL="$FILO_HOME/proposal.conf"
config="${FILO_CONFIG:-$PWD/.filo/config.conf}"
answers=""

while [ $# -gt 0 ]; do
  case "$1" in
    --accept)  shift ;;
    --answers) answers="$2"; shift 2 ;;
    *) echo "apply.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -f "$PROPOSAL" ] || { echo "FAIL proposal: run plan.sh first" >&2; exit 1; }

tmp="$(mktemp "${FILO_HOME}/config.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cp "$PROPOSAL" "$tmp"

for kv in $answers; do
  k="${kv%%=*}"
  v="${kv#*=}"
  "$CFG" set "$tmp" "$k" "$v"
done

# Validate every referenced harness resolves.
for k in critic.harness researcher.harness lane.default.harness lane.strong.harness; do
  h="$("$CFG" get "$tmp" "$k" 2>/dev/null || true)"
  [ -n "$h" ] || continue
  bin="$("$CFG" get "$ENV_CONF" "harness.$h.bin" 2>/dev/null || true)"
  [ -n "$bin" ] || { echo "FAIL $k: no harness.$h.bin in env.conf" >&2; exit 1; }
  case "$bin" in
    */*) [ -x "$bin" ] || { echo "FAIL $k: $bin not executable" >&2; exit 1; } ;;
    *)   command -v "$bin" >/dev/null 2>&1 || { echo "FAIL $k: $bin not on PATH" >&2; exit 1; } ;;
  esac
done

# Validate each model against its harness where the harness can tell.
ROLES="${FILO_ROLES:-$FILO_HOME/roles.conf}"
for p in critic researcher lane.default lane.strong; do
  m="$("$CFG" get "$tmp" "$p.model" 2>/dev/null || true)"
  [ -n "$m" ] || continue
  h="$("$CFG" get "$tmp" "$p.harness" 2>/dev/null || true)"
  [ -n "$h" ] || h="$("$CFG" get "$ROLES" "$p.harness" 2>/dev/null || true)"
  why="$("$HERE/models.sh" "$h" "$m" 2>&1 >/dev/null)" || [ $? = 2 ] || { echo "FAIL $p.model: $why" >&2; exit 1; }
done

mkdir -p "$(dirname "$config")"
mv -T -- "$tmp" "$config"
trap - EXIT
printf 'OK config=%s\n' "$config"
