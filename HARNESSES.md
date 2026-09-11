# Harness behavior — how each agent runs the coordinator

Field notes from the sandbox runs (no-tmux, single-harness, same todo-CLI
mission) at `/tmp/coord-sandbox`. Each section: how the skill surfaced, how the
coordinator's session identity was discovered, how the relay woke it, its git
permission model, loop quirks, and a verdict. Updated as runs complete.

## Common harness-agnostic mechanics (per SPEC)

- Queue + relay + resume, no tmux; workers are detached processes, `setsid`.
- Review is producer-severed (critic sees only diff + criteria), reviewed-state
  binding (`git diff HEAD | sha256sum`), approval-gated merge, coordinator
  authors commits (workers only stage).
- **Workers run with full permissions** (per-harness native bypass flag in the
  exec recipe): the worktree + the brief confine the worker; the gate is the
  critic review and the approval-gated coordinator merge — not worker
  permissions.
- Per-harness differences below are **config data** (`env.conf` recipes +
  discovery), never code forks — one core, four shells.

---

## codex  ✅ (full loop completed)

**Skill install & selection.** `~/.codex/skills/coordinator` (symlink, live).
The sandbox run picked the protocol up via `AGENTS.md` in the repo root (codex
reads it at session start); the skill dir is secondary. No `/skill` menu
observed; description matching or the `AGENTS.md` pointer is what engaged it.

**Session identity.** `coord.sh` discovers the *newest* rollout JSONL under
`~/.codex/sessions/YYYY/MM/DD/` and extracts the thread UUID from the filename
(`rollout-<ts>-<uuid>.jsonl`); `SESSION <uuid> source=codex-sessions`.

**Wake.** Two-channel story:
- `codex exec resume <id>` — **fails for this model of coordinator.**
  Invented ids → `no rollout found`. Real TUI thread → `thread ... already has
  an active writer (code -32600)` — you cannot externally resume a thread the
  live TUI holds open.
- `codex queue --thread <id> --message "WAKE batch=…"` — **works.** Pushes
  into the live session; the coordinator processes the message as its next
  turn. This is the delivery that closed the loop (all three slices merged).

**Git permissions.** The TUI runs untrusted workspaces read-only: the model was
told *"this workspace permits reading .git but not writing its index"* and
refused to start. Fix: launch codex with `-s workspace-write` (or trust the
project). Worker exec already runs with
`--dangerously-bypass-approvals-and-sandbox`.

**Loop quirks observed.**
- Slugs: the coordinator decorated event slugs with the worktree suffix
  (`cli-cli` for slice `cli`) → normalized by the task→slice canonicalization
  rule. Repeated across runs, so treat it as codex's default behavior.
- Workers staged `.scratch/` marker files before the gitignore hygiene landed;
  now excluded via boot `.gitignore`.
- Agent shells re-source the user profile: sandbox PATH leak (claude appeared
  in `detect`), so "single-harness" was not strictly true inside codex.
- The `[coord] ignore .scratch markers` boot commit is authored by the
  coordinator — first commit of the run.

**Verdict.** Fully works on the live-session model, once the TUI is in
`workspace-write`. Wake-via-`queue` is the pattern to replicate elsewhere.

---

## claude  ⏳ in progress

_Skill install_: `~/.claude/skills/coordinator` (symlink); claude resolves
custom skills via `/coordinator` slash command, per its own help.

**Session identity**: `coord.sh` takes the newest `*.jsonl` under
`~/.claude/projects/*/` (project-dir per workspace); `SESSION <uuid>
source=claude-projects`. Verified live.

**Git permissions**: claude's permission mode is **per-directory-tree and
per-process**. The TUI coordinator was trusted and wrote fine (worktrees,
boot commit), but the non-interactive `claude -p` worker ran with cwd = the
worktree subtree (not the trusted project) and had *no permission state* —
Write/Edit tools and bash redirection were all blocked ("you haven't granted
it yet" / "blocked... allowed working directories"). Fix (uniform with the
other harnesses' worker recipes): claude exec now runs with
`--dangerously-skip-permissions`.

**Loop quirks observed.**
- Decomposed the mission into ONE slice (`todo` = CLI + tests + README)
  where codex used three. Behavior difference, not an error.
- Worker reports are verbose prose to the log (it wrote a full obstruction
  report the first run instead of fabricating — good refusal).
- **The coordinator omits the concrete `finish.sh` line from briefs** — twice,
  consistently. First run the worker was also write-blocked (fixed by the
  per-process permission flag); second run the worker did all the work,
  staged it, and could not finish because the brief had no finish command.
  Decided fix (harness-agnostic): the finish contract is now APPENDED
  mechanically by spawn.sh, so no coordinator can skip it.

**Verdict: ✅ works, fully headless.** After three fixes the loop closed
end-to-end: session discovery (claude-projects) → resume wake with full
permissions → worker (stage-only, finish via the appended contract) → critic
(slice-bound, state-hash verdict) → approval → coordinator-authored commit →
merge; `test_todo.sh` passes on main. Cost of admission:

- resume recipe and exec recipe carry `--dangerously-skip-permissions`;
- repo `.claude/settings.local.json` (bypassPermissions) authored at boot;
- the coordinator turn runs OUTSIDE the visible TUI — claude has no
  `queue`-into-live like codex; every wake is a hidden background process,
  so **the user sees nothing** beyond the ledger (status.sh). The approval
  question was answered entirely inside the headless session (approvals/<id>
  recorded). Visibility is the outstanding gap (separate issue).

---

## opencode  ⏳ pending

_Discovery_: none yet — session store is sqlite without `sqlite3`; `opencode
session list` is not machine-readable here; expect `--session` handoff.

pencil: pending run

---

## pi  ⏳ pending

_Identity_: `$PI_SESSION_ID`; can also pin at launch with `--session-id`.
_Wake_: `pi --resume <id>`.

pencil: pending run

---

## Difference table  (filled as runs complete)

| | codex | claude | opencode | pi |
|---|---|---|---|---|
| skill surface | AGENTS.md / skills dir | `/coordinator` | config instructions | pi skills |
| session discovery | newest rollout | newest project jsonl | manual `--session` | `PI_SESSION_ID` |
| wake | `codex queue` (live push) | resume (headless, invisible) | `run --session` | `--resume` — pending |
| git perms | `-s workspace-write` / trust | `--dangerously-skip-permissions` + repo settings | `--auto` (workers) | pending |
| loop quirks | slug suffixing, profile PATH leak | one-slice decomposition; missing-finish brief; headless | pending | pending |