#!/usr/bin/env bash
# Real tmux adapter workflow: a worker is spawned into a real tmux window
# (adapters/tmux.sh), finishes, and relay delivers it. Runs inside a
# dedicated throwaway tmux session so nothing pollutes the caller's session.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN="$HERE/../scripts/spawn.sh"
STATE="$HERE/../scripts/state.sh"
QUEUE="$HERE/../scripts/queue.sh"
RELAY="$HERE/../scripts/relay.sh"
FINISH="$HERE/../scripts/finish.sh"

command -v tmux >/dev/null 2>&1 || { echo "  tmux not available; skipping"; exit 0; }

TMP="$(mktemp -d)"
SESS="coordtest-$$"
trap 'tmux kill-session -t "$SESS" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

# the scenario runs INSIDE the dedicated session, so the adapter's
# `tmux new-window` lands there too
cat > "$TMP/scenario.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export COORD_HOME="$TMP/coord"
export COORD_ENV_CONF="$TMP/coord/env.conf"
export COORD_CONFIG="$TMP/repo/.coordinator/config.conf"
export COORD_ROOT="$TMP/coord"
export COORD_LEDGER="$TMP/repo/.coordinator/ledger.tsv"
export COORD_AGENTS="$TMP/no-agents"
export COORD_ADAPTERS="$HERE/../adapters"
export RELAY_LOG="$TMP/resume.log"
export FINISH="$FINISH"
export PATH="$TMP:\$PATH"

"$STATE" add s1 "the slice" >/dev/null
out="\$("$SPAWN" --role worker --prompt "$TMP/brief" --worktree "$TMP/wt" --slice s1)"
pid="\$("$STATE" get s1 pid)"
sess="\$(tmux display-message -p '#S')"

# 1. the recorded pid must be a live pane in THIS session (list-panes -a:
#    -t <session> would only cover the current window)
tmux list-panes -a -F '#{session_name}:#{pane_pid}' | grep -qx "\$sess:\$pid" \
  || { echo "pid \$pid not a pane in \$sess: \$out" > "$TMP/scenario.err"; exit 90; }
# 2. the window must be named after the role
tmux list-windows -t "\$sess" -F '#{window_name}' | grep -qx 'worker' \
  || { echo "no 'worker' window" > "$TMP/scenario.err"; exit 91; }

# 3. the worker (sleeps 1s, then finishes) must enqueue its event
for _ in \$(seq 1 100); do "$QUEUE" pending && break; sleep 0.1; done
"$QUEUE" pending || { echo "worker never finished" > "$TMP/scenario.err"; exit 92; }

# 4. relay delivers it, like a real coordinator resume
COORD_RESUME="$TMP/fake-resume|__SESSION__|__BATCH__" COORD_SESSION="sess-x" \
  "$RELAY" --once --interval 0.2

[ "\$(wc -l < "\$RELAY_LOG" | tr -d ' ')" = "1" ] || { echo "expected one resume" > "$TMP/scenario.err"; exit 93; }
[ "\$(ls "\$COORD_ROOT/queue/.done" 2>/dev/null | wc -l | tr -d ' ')" = "1" ] || { echo "event not acked" > "$TMP/scenario.err"; exit 94; }
[ "\$("$STATE" get s1 status)" = "dispatched" ] || { echo "ledger wrong" > "$TMP/scenario.err"; exit 95; }

echo ok > "$TMP/scenario.done"
EOF
chmod +x "$TMP/scenario.sh"

# fake worker: stays alive long enough to assert its pane, then finishes
# fake worker: a tmux window does NOT inherit the spawner's env (production
# seeds it inline via `env VAR=...`), so bake the coordinator env in, like a
# real harness bit would. Stays alive long enough to assert its pane, then
# finishes from inside the worktree.
cat > "$TMP/fake-worker" <<EOF
#!/usr/bin/env bash
export COORD_HOME="$TMP/coord" COORD_ROOT="$TMP/coord" \\
  COORD_LEDGER="$TMP/repo/.coordinator/ledger.tsv" \\
  COORD_CONFIG="$TMP/repo/.coordinator/config.conf" \\
  FINISH="$FINISH"
cd "$TMP/wt"
sleep 1
"\$FINISH" --event s1 --role worker --result done --head - --summary "done via tmux"
EOF
chmod +x "$TMP/fake-worker"

# fake coordinator resume: record the batch pointer
cat > "$TMP/fake-resume" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RELAY_LOG"
EOF
chmod +x "$TMP/fake-resume"

mkdir -p "$TMP/coord" "$TMP/repo/.coordinator"
printf 'harness.fake.exec=%s|__PROMPT__\n' "$TMP/fake-worker" > "$TMP/coord/env.conf"
printf 'lane.default.harness=fake\nlane.default.model=\nadapters=tmux\n' > "$TMP/repo/.coordinator/config.conf"

mkdir -p "$TMP/wt"
git -C "$TMP/wt" init -q --initial-branch=main 2>/dev/null || git -C "$TMP/wt" init -q
git -C "$TMP/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf 'do the thing\n' > "$TMP/brief"

tmux new-session -d -s "$SESS"
tmux send-keys -t "$SESS" "bash $TMP/scenario.sh" Enter

# wait for the scenario marker
for _ in $(seq 1 150); do [ -f "$TMP/scenario.done" ] && break; [ -f "$TMP/scenario.err" ] && break; sleep 0.1; done

if [ -f "$TMP/scenario.err" ]; then
  echo "  scenario failed: $(cat "$TMP/scenario.err")"
  exit 1
fi
[ -f "$TMP/scenario.done" ] || { echo "  scenario timed out"; exit 1; }

echo "  tmux adapter workflow ok"