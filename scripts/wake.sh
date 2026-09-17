#!/usr/bin/env bash
# wake.sh <root> <batch>  -> assembled coordinator brief on stdout
#
# The routing counter to the fat host session: instead of waking a long-lived
# TUI with a one-line pointer (its whole transcript gets re-fed every turn —
# ~96% of host tokens were cache reads in measurement), the relay can hand a
# FRESH headless session a self-contained brief: the events + ledger + state +
# compact routing rules. Continuity lives in files, not the transcript.
#
# Modes: BOOT (no ledger yet -> plan + dispatch instructions + the task) or
# ROUTE (events -> route each per the protocol). Set RELAY_BRIEF=1 and a
# fresh-session resume recipe (__WAKE__/__REPO__ placeholders) in the relay.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${1:?root}"
batch="${2:?batch}"

# coordinator repo, same derivation as watch.sh
repo="${COORD_REPO:-}"
if [ -z "$repo" ]; then
  repo="$(dirname "$root")/tinyproj"
  [ -d "$repo/.coordinator" ] || repo="$(dirname "$(dirname "$root")")"
fi
ledger="$repo/.coordinator/ledger.tsv"
task_file="$repo/.coordinator/task"

{
  printf 'COORDINATOR WAKE %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'root=%s repo=%s\n\n' "$root" "$repo"
  printf '%s\n' '---- events ----'
  sed 's/^/  /' "$batch" 2>/dev/null || true

  if [ ! -s "$ledger" ]; then
    # ---- BOOT: first wake, nothing planned yet ----
    printf '\n%s\n' '---- mode: BOOT (plan + dispatch) ----'
    if [ -f "$task_file" ]; then
      printf 'task: %s\n' "$(cat "$task_file")"
    else
      printf '%s\n' 'task: (no .coordinator/task file found)'
    fi
    cat <<'EOF'

You are the coordinator for a bash-only multi-agent protocol. There is no
ledger yet. Plan this run into small vertical slices now:
1. Read the task above; split it into 2-4 small slices.
2. For each slice write a worker brief at .coordinator/<id>.prompt
   (self-contained: goal, output contract, and REPEAT the exact finish.sh
   command at the bottom of the brief).
3. Register each slice: scripts/state.sh add <id> "<goal>".
4. run scripts/state.sh ready, then dispatch the FIRST slice:
   scripts/spawn.sh --role worker --prompt .coordinator/<id>.prompt
   --worktree .coordinator/worktrees/<id>-<id> --slice <id>
5. git add -A and commit nothing else; end the turn.
EOF
  else
    # ---- ROUTE ----
    printf '\n%s\n' '---- mode: ROUTE ----'
    env COORD_ROOT="$root" "$HERE/status.sh" 2>/dev/null \
      | grep -E 'STATUS|QUEUE|STALE|HEALTH' | sed 's/^/  /' || true
    COORD_LEDGER="$ledger" "$HERE/state.sh" list 2>/dev/null | sed 's/^/  /' || true
    autonomy="$(env COORD_ROOT="$root" "$HERE/cfg.sh" get "$repo/.coordinator/config.conf" autonomy 2>/dev/null || true)"
    [ "$autonomy" = auto-merge ] && merge_note="merge directly (autonomy=auto-merge, pre-authorized)" \
      || merge_note="record the verdict; surface the merge decision for the human (never decide it here)"
    cat <<EOF

You are the coordinator, routing events for this run. State lives in files:
$repo/.coordinator (ledger.tsv, briefs/*.prompt, worktrees/). Act only in
that repo; never invent state.

Task->slice: run  scripts/state.sh resolve <task>  (exact id; else a trailing
-<suffix> or .<round> stripped; else exit 1). Never guess.

For EACH event in the batch:
- DONE <task>: done -> the worker produced work in its worktree. Write a
  critic assignment file .coordinator/<id>.critic.prompt (independent critic;
  review ONLY the staged changes in the worktree; read-only; must call the
  finish.sh contract), then dispatch:
    scripts/spawn.sh --role critic --prompt <that file> --worktree .coordinator/worktrees/<id>-<id> --slice <id>
  Never re-dispatch a slice already 'reviewing' in the ledger.
- VERDICT <task>: pass @ <hash> -> scripts/state.sh verdict <id> <round> pass <hash>;
  then $merge_note: scripts/merge.sh --slice <id> (authors, merges, pushes).
- VERDICT <task>: handback -> write a correction brief .coordinator/<id>.r2.prompt
  and respawn the SAME worker with the round-2 slug via spawn.sh --slice <id>.
- Unknown task: run scripts/state.sh resolve <task>; if it fails, report the
  error and end the turn — never guess.

git add -A anything you write. End your turn after routing every event.
EOF
  fi
} | tr -d '\r'