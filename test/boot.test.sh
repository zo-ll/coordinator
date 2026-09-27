#!/usr/bin/env bash
# coord plan + apply: proposal/ask split, single-harness forcing, validation.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
coord_plan() { "$COORD" plan "$@"; }
coord_apply() { "$COORD" apply "$@"; }
coord_cfg() { "$COORD" cfg "$@"; }


export COORD_HOME="$TMP/coord"
export COORD_ENV_CONF="$TMP/coord/env.conf"
export COORD_CONFIG="$TMP/repo/.coordinator/config.conf"
mkdir -p "$COORD_HOME"


# synthetic env: one spawnable harness
cat > "$COORD_ENV_CONF" <<EOF
current=codex
installed=codex
spawnable=codex
harness.codex.bin=$(command -v sh)
harness.codex.exec=codex|exec|__PROMPT__
harness.codex.resume=codex|exec|resume|__SESSION__|__BATCH__
EOF

out="$(coord_plan)"
assert "$(printf '%s\n' "$out" | sed -n 1p)" \
  "PROPOSE critic=codex researcher=codex lane.default=codex lane.strong=none autonomy=auto-merge"
assert "$(printf '%s\n' "$out" | sed -n 2p)" "ASK"
printf '%s\n' "$out" | grep -qx '  critic.model=' || { echo "  ASK missing critic.model"; exit 1; }
printf '%s\n' "$out" | grep -qx '  autonomy=auto-merge' || { echo "  ASK missing autonomy"; exit 1; }
if printf '%s\n' "$out" | grep -q '  critic.harness='; then echo "  roles should be forced"; exit 1; fi

# apply with answers
assert "$(coord_apply --answers 'autonomy=auto-merge critic.model=gpt-5')" "OK config=$COORD_CONFIG"
assert "$(coord_cfg get "$COORD_CONFIG" critic.harness)" "codex"
assert "$(coord_cfg get "$COORD_CONFIG" autonomy)" "auto-merge"
assert "$(coord_cfg get "$COORD_CONFIG" critic.model)" "gpt-5"

# a model the harness does not list is refused
mkdir -p "$CODEX_HOME"; printf '{"models":[{"slug": "gpt-6-luna"}]}\n' > "$CODEX_HOME/models_cache.json"
rm -f "$COORD_CONFIG"; coord_plan >/dev/null
if coord_apply --answers 'critic.model=sonnet' >/dev/null 2>"$TMP/err"; then echo "  wrong-harness model accepted"; exit 1; fi
grep -q 'FAIL critic.model: "sonnet" is not in codex' "$TMP/err" || { cat "$TMP/err"; exit 1; }
assert "$(coord_apply --answers 'critic.model=gpt-6-luna')" "OK config=$COORD_CONFIG"

# the user's global defaults are not asked again, and stay theirs
printf 'critic.model=gpt-6-luna\n' > "$COORD_ROLES"
rm -f "$COORD_CONFIG"
out="$(coord_plan)"
hasnt "$out" "critic.model="
has "$out" "lane.default.model="
coord_apply --accept >/dev/null
assert "$(coord_cfg get "$COORD_CONFIG" critic.model)" ""
rm -f "$COORD_ROLES"
coord_apply --answers 'autonomy=auto-merge critic.model=gpt-6-luna' >/dev/null

# once configured, plan asks nothing
assert "$(printf '%s\n' "$(coord_plan)" | sed -n 2p)" "ASK"

# invalid harness answer fails loudly
if coord_apply --answers 'critic.harness=ghost' >/dev/null 2>&1; then
  echo "  expected unknown harness to fail"; exit 1
fi

# multi-harness: lane.strong proposed, roles asked
cat > "$COORD_ENV_CONF" <<EOF
current=codex
installed=codex,claude
spawnable=codex,claude
harness.codex.bin=$(command -v sh)
harness.claude.bin=$(command -v sh)
EOF
rm -f "$COORD_CONFIG"
out="$(coord_plan)"
assert "$(printf '%s\n' "$out" | sed -n 1p)" \
  "PROPOSE critic=codex researcher=codex lane.default=codex lane.strong=claude autonomy=auto-merge"
block="$(printf '%s\n' "$out" | tail -n +2)"
case "$block" in *critic.harness=codex*) ;; *) echo "  ASK missing roles"; exit 1 ;; esac
case "$block" in *lane.strong.harness=claude*) ;; *) echo "  ASK missing lane.strong"; exit 1 ;; esac

echo "  boot ok"
