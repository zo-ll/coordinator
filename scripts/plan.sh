#!/usr/bin/env bash
# Reduce detected facts to a proposal + the fields to ask about.
#
#   plan.sh -> PROPOSE critic=… researcher=… lane.default=… lane.strong=… autonomy=… tracker=… adapters=…
#              ASK models autonomy [roles] [adapters] [tracker]
#
# Writes $COORD_HOME/proposal.conf (machine-readable) for apply.sh.
# Rules: one spawnable harness forces the role map and lanes; no tmux forces
# adapters=none; no gh forces tracker=local; model is ALWAYS asked (default is
# only chosen if the user affirms it).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$HERE/cfg.sh"
COORD_HOME="${COORD_HOME:-$HOME/.coordinator}"
ENV_CONF="${COORD_ENV_CONF:-$COORD_HOME/env.conf}"
CONFIG="${COORD_CONFIG:-$PWD/.coordinator/config.conf}"
PROPOSAL="${COORD_PROPOSAL:-$COORD_HOME/proposal.conf}"
mkdir -p "$COORD_HOME"

get() { "$CFG" get "$ENV_CONF" "$1" 2>/dev/null || true; }

# already configured -> nothing to ask
if [ -f "$CONFIG" ]; then
  printf 'PROPOSE critic=%s researcher=%s lane.default=%s lane.strong=%s autonomy=%s tracker=%s adapters=%s\n' \
    "$("$CFG" get "$CONFIG" critic.harness 2>/dev/null || echo -)" \
    "$("$CFG" get "$CONFIG" researcher.harness 2>/dev/null || echo -)" \
    "$("$CFG" get "$CONFIG" lane.default.harness 2>/dev/null || echo -)" \
    "$("$CFG" get "$CONFIG" lane.strong.harness 2>/dev/null || echo none)" \
    "$("$CFG" get "$CONFIG" autonomy 2>/dev/null || echo -)" \
    "$("$CFG" get "$CONFIG" tracker 2>/dev/null || echo -)" \
    "$("$CFG" get "$CONFIG" adapters 2>/dev/null || echo -)"
  printf 'ASK\n'
  exit 0
fi

IFS=',' read -r -a sp_raw <<< "$(get spawnable)"
sp=()
for h in "${sp_raw[@]:-}"; do [ -n "$h" ] && sp+=("$h"); done
[ "${#sp[@]}" -gt 0 ] || { echo "plan: no spawnable harness in $ENV_CONF" >&2; exit 2; }

current="$(get current)"
default="${sp[0]}"
for h in "${sp[@]}"; do [ "$h" = "$current" ] && default="$h"; done

critic="$default"; researcher="$default"; lane_default="$default"
lane_strong="" ; routing_risky="default"
if [ "${#sp[@]}" -gt 1 ]; then
  for h in "${sp[@]}"; do [ "$h" != "$default" ] && lane_strong="$h" && break; done
  [ -n "$lane_strong" ] && routing_risky="strong"
fi

tmux="$(get tmux)"; gh="$(get gh)"
tracker="local"; adapters="none"
ask="models autonomy"
[ "${#sp[@]}" -gt 1 ] && ask="roles $ask"
[ "$tmux" = 1 ] && ask="$ask adapters"
[ "$gh" = 1 ] && ask="$ask tracker"

: > "$PROPOSAL"
"$CFG" set "$PROPOSAL" critic.harness "$critic"
"$CFG" set "$PROPOSAL" critic.model ""
"$CFG" set "$PROPOSAL" researcher.harness "$researcher"
"$CFG" set "$PROPOSAL" researcher.model ""
"$CFG" set "$PROPOSAL" lane.default.harness "$lane_default"
"$CFG" set "$PROPOSAL" lane.default.model ""
"$CFG" set "$PROPOSAL" routing.mechanical default
"$CFG" set "$PROPOSAL" routing.risky "$routing_risky"
if [ -n "$lane_strong" ]; then
  "$CFG" set "$PROPOSAL" lane.strong.harness "$lane_strong"
  "$CFG" set "$PROPOSAL" lane.strong.model ""
fi
"$CFG" set "$PROPOSAL" autonomy approve-merge
"$CFG" set "$PROPOSAL" tracker "$tracker"
"$CFG" set "$PROPOSAL" adapters "$adapters"

printf 'PROPOSE critic=%s researcher=%s lane.default=%s lane.strong=%s autonomy=approve-merge tracker=%s adapters=%s\n' \
  "$critic" "$researcher" "$lane_default" "${lane_strong:-none}" "$tracker" "$adapters"
printf 'ASK %s\n' "$ask"
