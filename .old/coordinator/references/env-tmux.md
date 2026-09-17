# Coordinator — Tmux environment runbook

Load this file when the active environment is **tmux** (`tmux list-sessions`
succeeds). This is the coordinator's environment runbook.

## Working environment

Standard layout, one tmux session (`personal`; attach: `tmux attach -t personal`):

| # | Window | Runs | Spec |
|---|--------|------|------|
| 0 | coordinator | pi | the coordinator's own pane; state lives in COORDINATION.md; model from `config.coordinator` (see startup recipes) |
| 1 | critic | pi | the `critic` skill loaded and NO other skills; model from `config.critic` (pass the FULL id — a bare pattern can match a keyless variant) |
| 2 | claude lane | claude | worker: UI lane; model/effort from `config.workers.claude` |
| 3 | codex lane | codex | worker: engine/CLI/infra lane; model from `config.workers.codex` |

The CRITIC window must show ONLY the critic skill — never a plain shell,
never a full-skill pi (both have broken takeovers).

## Startup recipes (used exactly)

Every model is taken from `<repo>/.coordinator/config.json` (never a harness
default). Substitute the configured values:

- coordinator = `pi --provider <cfg.coordinator.provider> --model <cfg.coordinator.model>`
- critic = `pi --provider <cfg.critic.provider> --model <cfg.critic.model> --skill <critic SKILL.md> -n critic "$(cat critic-boot)"`
- claude = `claude --model <cfg.workers.claude.model> --effort <cfg.workers.claude.effort> --dangerously-skip-permissions`
- codex = `codex -m <cfg.workers.codex.model> -c model_reasoning_effort=<cfg.workers.codex.reasoning_effort> -s danger-full-access -a never --no-alt-screen`

## On-demand researcher (NOT part of the default env)

Spawn ONLY when the user asks to research a feature:

```bash
tmux new-window -d -t personal -n researcher -c <repo> \
  'pi --provider <cfg.researcher.provider> --model <cfg.researcher.model> --skill <researcher SKILL.md> -n researcher "$(cat researcher-boot)"'
```

then dispatch via the research protocol (`references/research-protocol.md`).
Kill the window when the brief lands (`tmux kill-window -t personal:4`) — the
researcher is never standing. Other on-demand windows (horizon daemons, etc.)
follow the same rule: create when needed, remove when done.

## Delivery (finish protocol)

- The relay must be running detached, from coordinator skill `scripts/relay.sh`
  (default target `personal:coordinator.0`; override with
  `RELAY_COORD_PANE`). Pings arrive in the inbox
  (`/tmp/shipwright/inbox/<task>.ping`) and are typed into the coordinator
  pane when its foreground command is `pi` and not in copy mode; otherwise
  DEFER+retry. The relay COALESCES: after a quiet window (default 6s,
  `RELAY_COALESCE`) it types all pending events as ONE line (`EVENTS n: …`), so
  one turn drains a wave. `RELAY_INBOX`, `RELAY_LOG`, `RELAY_LOCK`, and
  `RELAY_INTERVAL` also override. See `references/finish-protocol.md`.

## Dispatch capture (tmux)

For provider stalls, run `bash scripts/check-aborted.sh personal` from the
coordinator skill directory and follow [provider recovery](provider-recovery.md).
The helper is read-only; its status is a triage hint, not a completion gate.

After prompt-target + Enter, ALWAYS capture the pane:

- `tmux display-message -p -t <pane> '#{pane_current_command}'` identifies
  WHICH application is open. `codex`/`claude` alone does not prove a turn
  was accepted; either can be idle at its prompt.
- Capture with `tmux capture-pane -p -t <pane>` and look for an actual
  Working/thinking indicator for the submitted turn, or an explicit task
  acknowledgment. Only then treat dispatch as accepted. An ambiguous
  capture calls for another observation, not another Enter.
- Pointer still at the prompt (unsubmitted) → ONE more Enter (lost-Enter race);
  never a second Enter while the pane shows Working (twin-ping duplicate).
- pi panes receive prompts ONLY as a SINGLE LINE pointer to a file — never
  multi-line content pasted into a pi composer (pi fragments pasted newlines).
