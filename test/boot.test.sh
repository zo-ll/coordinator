#!/usr/bin/env bash
# plan.sh + apply.sh: proposal/ask split, single-harness forcing, validation.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN="$HERE/../scripts/plan.sh"
APPLY="$HERE/../scripts/apply.sh"
CFG="$HERE/../scripts/cfg.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export COORD_HOME="$TMP/coord"
export COORD_ENV_CONF="$TMP/coord/env.conf"
export COORD_CONFIG="$TMP/repo/.coordinator/config.conf"
mkdir -p "$COORD_HOME"

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }

# synthetic env: one spawnable harness, no tmux, no gh
cat > "$COORD_ENV_CONF" <<EOF
current=codex
installed=codex
spawnable=codex
tmux=0
gh=0
harness.codex.bin=$(command -v sh)
harness.codex.exec=codex|exec|__PROMPT__
harness.codex.resume=codex|exec|resume|__SESSION__|__BATCH__
EOF

out="$("$PLAN")"
assert "$(printf '%s\n' "$out" | sed -n 1p)" \
  "PROPOSE critic=codex researcher=codex lane.default=codex lane.strong=none autonomy=approve-merge tracker=local adapters=none"
assert "$(printf '%s\n' "$out" | sed -n 2p)" "ASK models autonomy"

# apply with answers
assert "$("$APPLY" --answers 'autonomy=auto-merge critic.model=gpt-5')" "OK config=$COORD_CONFIG"
assert "$("$CFG" get "$COORD_CONFIG" critic.harness)" "codex"
assert "$("$CFG" get "$COORD_CONFIG" autonomy)" "auto-merge"
assert "$("$CFG" get "$COORD_CONFIG" critic.model)" "gpt-5"
assert "$("$CFG" get "$COORD_CONFIG" tracker)" "local"

# once configured, plan asks nothing
assert "$(printf '%s\n' "$("$PLAN")" | sed -n 2p)" "ASK"

# invalid harness answer fails loudly
if "$APPLY" --answers 'critic.harness=ghost' >/dev/null 2>&1; then
  echo "  expected unknown harness to fail"; exit 1
fi

# multi-harness: lane.strong proposed, role/adapters/tracker asked
cat > "$COORD_ENV_CONF" <<EOF
current=codex
installed=codex,claude
spawnable=codex,claude
tmux=1
gh=1
harness.codex.bin=$(command -v sh)
harness.claude.bin=$(command -v sh)
EOF
rm -f "$COORD_CONFIG"
out="$("$PLAN")"
assert "$(printf '%s\n' "$out" | sed -n 1p)" \
  "PROPOSE critic=codex researcher=codex lane.default=codex lane.strong=claude autonomy=approve-merge tracker=local adapters=none"
ask="$(printf '%s\n' "$out" | sed -n 2p)"
case "$ask" in
  *roles*adapters*tracker*) ;;
  *) echo "  multi-harness ASK missing fields: $ask"; exit 1 ;;
esac

echo "  boot ok"
