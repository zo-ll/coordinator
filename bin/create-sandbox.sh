#!/usr/bin/env bash
# One-shot harness sandbox factory: creates 4 isolated coordinator test
# environments (codex | claude | opencode | pi), one tmux window per harness,
# injects the todo prompt into each chatbox, and registers a full-context
# timeline per harness under results/.
#
#   bin/create-sandbox.sh [--no-send] [codex|claude|opencode|pi ...]
#
# Layout:
#   /tmp/coord-4x/<harness>/           isolated env (bin farm + home + root + repo)
#   /tmp/coord-4x/results/<harness>.log  watcher timeline (status, git, logs, relay)
#   /tmp/coord-4x/results/manifest.txt   run manifest
#   /tmp/coord-4x/results/prompt.txt     the exact injected prompt
#
# Per-harness details (config data, one core):
#   codex    -s workspace-write (git access)            wake: codex queue
#   claude   /coordinator prelude + project settings    wake: -p --resume + perms
#   opencode instructions-loaded skill, --auto          wake: run --session
#   pi       native skill, $PI_SESSION_ID               wake: --resume
set -euo pipefail

REPO=/home/andrea/personal/coordinator
SCRIPTS="$REPO/scripts"
ROOT=/tmp/coord-4x
RES="$ROOT/results"
HARNESSES="codex claude opencode pi"
SEND=1
SEND_DELAY="${SEND_DELAY:-25}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.6-luna}"
CLAUDE_MODEL="${CLAUDE_MODEL:-sonnet}"

PROMPT='Build a small todo CLI in bash named `todo`: add/list/done with items in ~/.todo, a test script exercising all three commands, and a README. Coordinate it — split into slices, delegate, review, and merge.'

while [ $# -gt 0 ]; do
  case "$1" in
    --no-send) SEND=0; shift ;;
    *) HARNESSES="$1"; shift ;;
  esac
done
for h in $HARNESSES; do
  case "$h" in codex|claude|opencode|pi) ;; *) echo "bad harness: $h" >&2; exit 2 ;; esac
done

rm -rf "$ROOT"
mkdir -p "$RES"

# full permissions: pre-seed trust so TUIs never sit at a dialog (codex via
# config.toml trust_level; claude via ~/.claude.json trustEnabled - the claude
# dialog may still appear, create-sandbox auto-answers it below)
# NOTE: append idempotently - TOML rejects duplicate [projects.*] keys, and a
# duplicate made codex refuse to start on the very first boot.
if ! grep -q "\[projects\.\"$ROOT/" "$HOME/.codex/config.toml" 2>/dev/null; then
  {
    for h in codex claude opencode pi; do
      printf '\n[projects."%s/%s/tinyproj"]\ntrust_level = "trusted"\n' "$ROOT" "$h"
    done
  } >> "$HOME/.codex/config.toml"
fi
python3 - "$ROOT" <<'PY'
import json,sys
p='/home/andrea/.claude.json'
c=json.load(open(p))
proj=c.setdefault('projects',{})
for h in ['codex','claude','opencode','pi']:
    proj.setdefault(f"{sys.argv[1]}/{h}/tinyproj",{}).update({'trustEnabled':True,'allowedTools':[]})
json.dump(c,open(p,'w'),indent=2)
PY

# per-harness watcher: full-context timeline into results/<h>.log
cat > "$ROOT/watch.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
h="\$1"
S="$SCRIPTS"
export COORD_HOME="$ROOT/\$h/home" COORD_ROOT="$ROOT/\$h/root"
export COORD_LEDGER="$ROOT/\$h/tinyproj/.coordinator/ledger.tsv"
export COORD_DASHBOARD="$ROOT/\$h/tinyproj/COORDINATION.md"
LOG="$RES/\$h.log"
cd "$ROOT/\$h/tinyproj"
snap() { {
  echo "=== \$(date +%H:%M:%S) ==="
  "\$S/status.sh" 2>/dev/null || echo "(no coordinator state yet)"
  echo "-- git --"; git log --oneline --all 2>/dev/null | head -8
  git worktree list 2>/dev/null | head -6
  echo "-- files --"; ls 2>/dev/null
  echo "-- logs --"
  for f in "\$COORD_ROOT"/log/*.log; do
    [ -e "\$f" ] && { echo "  \$f:"; tail -4 "\$f" | sed 's/^/    /'; }
  done
  echo "-- relay --"
  [ -f "\$COORD_ROOT/relay.lock" ] && echo "  lock present" || echo "  none"
}; } >> "\$LOG"
for _ in \$(seq 1 1000); do snap; sleep 3; done
EOF
chmod +x "$ROOT/watch.sh"

ts="$(date '+%F %T')"
for h in $HARNESSES; do
  D="$ROOT/$h"
  BIN="$D/bin"
  mkdir -p "$BIN" "$D/home" "$D/root" "$D/tinyproj"

  # symlink farm: system tools minus the hidden harnesses
  for d in /usr/bin /bin /usr/local/bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      b="$(basename "$f")"
      case "$b" in
        tmux|tmux-*|claude*|pi|opencode*gem*) continue ;;
      esac
      [ -e "$BIN/$b" ] || ln -s "$f" "$BIN/$b" 2>/dev/null || true
    done
  done
  OC_SERVER=""
  case "$h" in
    codex)   ln -s "$(command -v codex)"    "$BIN/codex";   ln -s "$(command -v node)" "$BIN/node"; LAUNCH="codex -c model=\"$CODEX_MODEL\""; MODEL="$CODEX_MODEL" ;;
    claude)  ln -s "$(command -v claude)"   "$BIN/claude";  LAUNCH="claude --model $CLAUDE_MODEL"; MODEL="$CLAUDE_MODEL" ;;
    opencode) ln -s "$(command -v opencode)" "$BIN/opencode"; LAUNCH="opencode --auto --port 45111"; OC_SERVER="http://127.0.0.1:45111"; MODEL="" ;;
    pi)      ln -s "$(command -v pi)"       "$BIN/pi"; ln -s "$(command -v node)" "$BIN/node"; LAUNCH="pi"; MODEL="" ;;
  esac

  # per-harness sandbox HOME: every shell the agent spawns reads envpin
  # (BASH_ENV) or .profile/.bashrc, so PATH stays the fake farm and detect.sh
  # can only ever see THIS harness. Agent config/state dirs (incl. credentials
  # under .local/share) are symlinked in, so accounts, trust, models and skills
  # still resolve.
  cat > "$D/home/envpin" <<PIN
export PATH="$BIN"
export COORD_OPENCODE_SERVER="$OC_SERVER"
PIN
  cp "$D/home/envpin" "$D/home/.bashrc"
  cp "$D/home/envpin" "$D/home/.profile"
  for c in .codex .claude .claude.json .agents .pi .opencode .gitconfig .config .local .cache; do
    [ -e "$HOME/$c" ] && ln -sfn "$HOME/$c" "$D/home/$c" 2>/dev/null || true
  done

  # isolated repo with the protocol hook
  ( cd "$D/tinyproj" &&
    git init -q && git config user.name sandbox && git config user.email sandbox@local &&
    printf '%s\n' 'During any multi-part work (coordinate/delegate/dispatch), follow the' \
      'coordinator protocol in /home/andrea/personal/coordinator/SKILL.md exactly.' > AGENTS.md &&
    echo "tiny project" > README.md &&
    mkdir -p .claude &&
    printf '{\n  "permissions": {\n    "defaultMode": "bypassPermissions"\n  }\n}\n' > .claude/settings.local.json &&
    git add -A && git add -f .claude/settings.local.json && git commit -q -m init &&
    git branch -m main )

  printf '%s\n' "$PROMPT" > "$D/prompt.txt"

  # pre-apply the config: full permissions + no prompts. plan.sh sees an
  # existing config -> empty ASK; apply --accept is a no-op re-boot; every
  # merge later is auto (no approval dialogs). The run is fully unattended.
  cd="$D/tinyproj/.coordinator"
  mkdir -p "$cd"
  cat > "$cd/config.conf" <<CFG
critic.harness=$h
critic.model=$MODEL
researcher.harness=$h
researcher.model=$MODEL
lane.default.harness=$h
lane.default.model=$MODEL
routing.mechanical=default
routing.risky=default
autonomy=auto-merge
tracker=local
adapters=none
merge.base=main
CFG

  # one window per harness (apps may retitle - codex sets "node" - so keep the
  # stable index for sending/poking)
  tmux kill-window -t "coord-$h" 2>/dev/null || true
  widx="$(tmux new-window -d -P -F '#{window_index}' -n "coord-$h" -c "$D/tinyproj" \
    "bash --noprofile --norc -c 'printf \"SANDBOX ($h): no tmux, single harness — prompt will be auto-sent\\\\n\\\\n\"; env HOME=$D/home BASH_ENV=$D/home/envpin PATH=$BIN COORD_HOME=$D/home COORD_ROOT=$D/root COORD_OPENCODE_SERVER=$OC_SERVER $LAUNCH'")"
  echo "$widx" > "$RES/$h.window"

  # separate watcher registering results
  setsid nohup bash "$ROOT/watch.sh" "$h" >/dev/null 2>&1 &
  echo "$!" > "$RES/$h.watcher.pid"
done

# manifest: full context entry point
{
  echo "# coordinator harness run manifest"
  echo "created: $ts"
  echo "prompt: $PROMPT"
  echo "windows: $(for h in $HARNESSES; do cat "$RES/$h.window" 2>/dev/null; done | tr '\n' ' ')"
  for h in $HARNESSES; do
    echo "== $h =="
    echo "  window:  index $(cat "$RES/$h.window" 2>/dev/null) (name may be retitled by the app)"
    echo "  dir:     $ROOT/$h"
    echo "  repo:    $ROOT/$h/tinyproj ($(git -C "$ROOT/$h/tinyproj" rev-parse --short HEAD 2>/dev/null) on $(git -C "$ROOT/$h/tinyproj" branch --show-current 2>/dev/null))"
    echo "  timeline: results/$h.log (watcher pid $(cat "$RES/$h.watcher.pid" 2>/dev/null))"
  done
} > "$RES/manifest.txt"
cp "$ROOT/watch.sh" "$RES/watch.sh" 2>/dev/null || true

echo "== sandboxes ready =="
cat "$RES/manifest.txt"

if [ "$SEND" = 1 ]; then
  echo "== waiting ${SEND_DELAY}s for TUIs to boot, then sending the prompt =="
  sleep "$SEND_DELAY"
  for h in $HARNESSES; do
    widx="$(cat "$RES/$h.window" 2>/dev/null || tmux display -t "coord-$h" -p '#{window_index}' 2>/dev/null)"
    if [ "$h" = claude ]; then
      tmux send-keys -t "$widx" Down Enter   # trust dialog: "Yes, I trust this folder"
      sleep 4
      tmux send-keys -t "$widx" -- "/coordinator" Enter
      sleep 4
    elif [ "$h" = codex ]; then
      tmux send-keys -t "$widx" Enter        # trust dialog: "1. Yes, continue"
      sleep 4
    fi
    tmux send-keys -t "$widx" -- "$PROMPT" Enter
    echo "sent prompt to coord-$h (window $widx)"
  done
fi
echo "results: $RES"