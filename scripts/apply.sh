#!/usr/bin/env bash
# Apply the user's answers over the proposal, validate, and write config.conf.
#
#   apply.sh [--accept] [--answers "critic.model=… autonomy=auto-merge"] [--config PATH]
#     -> OK config=<path>  |  FAIL <field>: <reason>
#
# Answers are literal `key=value` dotted config keys (space-separated). Only
# answers given are overlaid onto the proposal; everything else keeps its
# proposed value.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/progress.sh"
progress_start apply
CFG="$HERE/cfg.sh"
COORD_HOME="${COORD_HOME:-$HOME/.coordinator}"
ENV_CONF="${COORD_ENV_CONF:-$COORD_HOME/env.conf}"
PROPOSAL="${COORD_PROPOSAL:-$COORD_HOME/proposal.conf}"
config="${COORD_CONFIG:-$PWD/.coordinator/config.conf}"
answers=""

while [ $# -gt 0 ]; do
  case "$1" in
    --accept)  shift ;;
    --answers) answers="$2"; shift 2 ;;
    --config)  config="$2"; shift 2 ;;
    *) echo "apply.sh: unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -f "$PROPOSAL" ] || { echo "FAIL proposal: run plan.sh first" >&2; exit 1; }

tmp="$(mktemp "${COORD_HOME}/config.XXXXXX")"
progress_cleanup() { rm -f "$tmp"; }
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

mkdir -p "$(dirname "$config")"
mv -T -- "$tmp" "$config"
progress_note="config=$config written; harness binaries resolved (real execution not yet verified)"
printf 'OK config=%s\n' "$config"
