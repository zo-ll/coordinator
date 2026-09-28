#!/usr/bin/env bash
# Config matrix under a controlled PATH:
#   one harness  -> role map forced, no "roles" asked
#   zero harness -> boot fails cleanly
#   two harnesses-> role map asked, lane.strong proposed
set -euo pipefail
. "$(dirname "$0")/lib.sh"
filo_detect() { "$FILO" detect "$@"; }
filo_plan() { "$FILO" plan "$@"; }
filo_apply() { "$FILO" apply "$@"; }
filo_cfg() { "$FILO" cfg "$@"; }


ORIG_PATH="$PATH"
tool() { PATH="$ORIG_PATH" command -v "$1"; }

# unset any harness sentinels inherited from the test runner
unset OPENCODE CLAUDECODE CLAUDE_CODE_ENTRYPOINT PI_CODING_AGENT_SESSION_DIR PI_SESSION_ID CODEX_HOME
# pin the current harness (opencode is never spawnable here), so the
# ancestor walk cannot pick up whatever harness runs the tests
export FILO_CURRENT=opencode

make_bin() { # make_bin <harness...>  -> minimal PATH with core tools (+ fakes)
  rm -rf "$TMP/bin"
  mkdir -p "$TMP/bin"
  local c p
  for c in bash ps tr seq awk mktemp mv cat cp dirname mkdir; do
    p="$(tool "$c")" && ln -s "$p" "$TMP/bin/$c"
  done
  local h
  for h in "$@"; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bin/$h"
    chmod +x "$TMP/bin/$h"
  done
}

fresh() { # fresh <name>
  export FILO_HOME="$TMP/$1/filo"
  export FILO_ENV_CONF="$TMP/$1/filo/env.conf"
  export FILO_CONFIG="$TMP/$1/repo/.filo/config.conf"
  mkdir -p "$FILO_HOME"
}


# --- one harness: everything forced, only models/autonomy asked
make_bin codex
export FILO_KNOWN="codex"
fresh one
# current is the pinned sentinel; the matrix case only cares that the role map
# is forced.
out="$(PATH="$TMP/bin" filo_detect)"
assert "$(printf '%s\n' "$out" | sed -E 's/current=[^ ]+ //')" \
  "DETECT installed=codex spawnable=codex"
out="$(PATH="$TMP/bin" filo_plan)"
assert "$(printf '%s\n' "$out" | sed -n 1p)" \
  "PROPOSE critic=codex researcher=codex lane.default=codex lane.strong=none autonomy=auto-merge"
assert "$(printf '%s\n' "$out" | sed -n 2p)" "ASK"
printf '%s\n' "$out" | grep -qx '  critic.model=' || { echo "  ASK missing critic.model"; exit 1; }
if printf '%s\n' "$out" | grep -q '  critic.harness='; then echo "  roles should be forced"; exit 1; fi
PATH="$TMP/bin" filo_apply --accept >/dev/null
assert "$(filo_cfg get "$FILO_CONFIG" critic.harness)" "codex"
assert "$(filo_cfg get "$FILO_CONFIG" lane.default.harness)" "codex"

# --- zero harnesses: plan fails cleanly
make_bin
fresh zero
PATH="$TMP/bin" filo_detect >/dev/null
if PATH="$TMP/bin" filo_plan >/dev/null 2>&1; then echo "  plan should fail with no spawnable harness"; exit 1; fi

# --- two harnesses: role map asked, lane.strong proposed
make_bin codex claude
export FILO_KNOWN="codex claude"
fresh two
PATH="$TMP/bin" filo_detect >/dev/null
out="$(PATH="$TMP/bin" filo_plan)"
assert "$(printf '%s\n' "$out" | sed -n 1p)" \
  "PROPOSE critic=codex researcher=codex lane.default=codex lane.strong=claude autonomy=auto-merge"
case "$(printf '%s\n' "$out" | tail -n +2)" in
  *critic.harness=codex*lane.strong.harness=claude*) ;;
  *) echo "  multi-harness ASK missing roles"; exit 1 ;;
esac

echo "  matrix ok"
