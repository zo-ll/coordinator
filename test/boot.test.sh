#!/usr/bin/env bash
# filo plan + apply: proposal/ask split, single-harness forcing, validation.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
filo_plan() { "$ROOT/libexec/plan.sh" "$@"; }
filo_apply() { "$ROOT/libexec/apply.sh" "$@"; }
filo_cfg() { "$FILO" cfg "$@"; }


export FILO_HOME="$TMP/filo"
export FILO_ENV_CONF="$TMP/filo/env.conf"
export FILO_CONFIG="$TMP/repo/.filo/config.conf"
mkdir -p "$FILO_HOME"


# synthetic env: one spawnable harness
cat > "$FILO_ENV_CONF" <<EOF
current=codex
installed=codex
spawnable=codex
harness.codex.bin=$(command -v sh)
harness.codex.exec=codex|exec|__PROMPT__
harness.codex.resume=codex|exec|resume|__SESSION__|__BATCH__
EOF

out="$(filo_plan)"
assert "$(printf '%s\n' "$out" | sed -n 1p)" \
  "PROPOSE critic=codex researcher=codex lane.default=codex lane.strong=none autonomy=auto-merge"
assert "$(printf '%s\n' "$out" | sed -n 2p)" "ASK"
printf '%s\n' "$out" | grep -qx '  critic.model=' || { echo "  ASK missing critic.model"; exit 1; }
printf '%s\n' "$out" | grep -qx '  autonomy=auto-merge' || { echo "  ASK missing autonomy"; exit 1; }
if printf '%s\n' "$out" | grep -q '  critic.harness='; then echo "  roles should be forced"; exit 1; fi

# apply with answers
assert "$(filo_apply --answers 'autonomy=auto-merge critic.model=gpt-5')" "OK config=$FILO_CONFIG"
assert "$(filo_cfg get "$FILO_CONFIG" critic.harness)" "codex"
assert "$(filo_cfg get "$FILO_CONFIG" autonomy)" "auto-merge"
assert "$(filo_cfg get "$FILO_CONFIG" critic.model)" "gpt-5"

# a model the harness does not list is refused
mkdir -p "$CODEX_HOME"; printf '{"models":[{"slug": "gpt-6-luna"}]}\n' > "$CODEX_HOME/models_cache.json"
rm -f "$FILO_CONFIG"; filo_plan >/dev/null
if filo_apply --answers 'critic.model=sonnet' >/dev/null 2>"$TMP/err"; then echo "  wrong-harness model accepted"; exit 1; fi
grep -q 'FAIL critic.model: "sonnet" is not in codex' "$TMP/err" || { cat "$TMP/err"; exit 1; }
assert "$(filo_apply --answers 'critic.model=gpt-6-luna')" "OK config=$FILO_CONFIG"

# the user's global defaults are not asked again, and stay theirs
printf 'critic.model=gpt-6-luna\n' > "$FILO_ROLES"
rm -f "$FILO_CONFIG"
out="$(filo_plan)"
hasnt "$out" "critic.model="
has "$out" "lane.default.model="
filo_apply --accept >/dev/null
assert "$(filo_cfg get "$FILO_CONFIG" critic.model)" ""
rm -f "$FILO_ROLES"
filo_apply --answers 'autonomy=auto-merge critic.model=gpt-6-luna' >/dev/null

# invalid harness answer fails loudly
if filo_apply --answers 'critic.harness=ghost' >/dev/null 2>&1; then
  echo "  expected unknown harness to fail"; exit 1
fi

# multi-harness: lane.strong proposed, roles asked
cat > "$FILO_ENV_CONF" <<EOF
current=codex
installed=codex,claude
spawnable=codex,claude
harness.codex.bin=$(command -v sh)
harness.claude.bin=$(command -v sh)
EOF
rm -f "$FILO_CONFIG"
out="$(filo_plan)"
assert "$(printf '%s\n' "$out" | sed -n 1p)" \
  "PROPOSE critic=codex researcher=codex lane.default=codex lane.strong=claude autonomy=auto-merge"
block="$(printf '%s\n' "$out" | tail -n +2)"
case "$block" in *critic.harness=codex*) ;; *) echo "  ASK missing roles"; exit 1 ;; esac
case "$block" in *lane.strong.harness=claude*) ;; *) echo "  ASK missing lane.strong"; exit 1 ;; esac

echo "  boot ok"
