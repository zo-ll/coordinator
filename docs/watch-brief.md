# Design brief: `coord watch`, the side panel

Repo: https://github.com/zo-ll/coordinator. Read `SPEC-v2.md` (the engine; see
"Delivery in tmux"), `SKILL.md` (what the coordinator agent does) and
`HARNESSES.md` (how real agent harnesses behave).

This follows your `coord watch v2` design. Keep what worked: the needs-you box
that only exists when something is waiting, rows that read as sentences
("unblocks s4, s5"), honest liveness ("log 4s ago", "quiet 41s"), timebox bars,
the unit tabs (brief, critic, diff, verify, history), keys hidden when the
engine would refuse them, and actions that show the exact command and the
engine's one-line reply. What changed is **where watch lives and what it is not
responsible for**.

## The layout

coordinator is a skill, not an app. The user runs their own agent harness
(claude, codex, opencode, pi) in a tmux pane and loads the skill; that harness
window *is* the coordinator. The user chats with it there, and the engine types
each wake into that same window, so every coordinator turn happens in view.

```
┌ coordinator: the user's harness ──┬ coord watch ─────────────┐
│ the conversation with the         │ this brief               │
│ coordinator; wakes land here      │                          │
└───────────────────────────────────┴──────────────────────────┘
  tmux windows 1..n: one per worker / critic / researcher launch
```

So watch is **a side panel, not the whole screen**, and it **does not show the
coordinator's conversation**: that is already on the left. Watch covers
everything the coordinator window doesn't: the units, the agents working on
them, and what needs the user.

## What watch must show

1. **Needs you**, first, as in v2: a unit that passed and waits for approval, a
   unit the engine blocked, a research report waiting for a decision. The user
   can act from watch (`a`, `r`, …) or just tell the coordinator in chat; both
   end up as the same event, and watch should make that clear.
2. **The coordinator's state, in one line.** Not its words, its status: idle,
   working on a turn, a wake waiting to be delivered, a wake typed but not yet
   acknowledged, or stuck (for example a permission dialog is open in its pane,
   so the wake can't land). Stuck is a needs-you item with the one action that
   fixes it ("switch to the coordinator pane and answer the dialog").
3. **Running agents**, as in v2: unit, goal, role (worker builds, critic
   reviews), round, time against the timebox, liveness, and the latest activity
   line from its stream ("ran go test ./... → 3 failed", "edited retry.go").
4. **Jumping to an agent.** Each launch runs in its own tmux window. Watch needs
   a clear way to go to that window (the harness running live) and to come back.
5. **Up next and done**, compressed, as in v2.
6. **Recent events**, short, newest first. Coordinator decisions appear here
   only as the event they produced ("s2 sent back for a correction round"),
   with at most its one-line note.

## Sizes

- **Side pane**, the main case: about 60 columns wide and full terminal height
  (60×40), next to the coordinator pane.
- **Narrow side pane**: 44×40. What collapses first?
- **Full window** (`coord watch` in its own tmux window, 132×40): the extra
  room goes to more activity lines per agent and the unit tabs open in place.

## States to design

- No units yet (the coordinator is still planning).
- Everything merged (done).
- The relay is down, so nothing will move.
- The coordinator pane is closed or its tmux session is gone.
- A wake could not be delivered after its retry.
- An agent died, or was killed at its timebox; a unit blocked after two deaths.
- Running without tmux: watch in a plain terminal, no windows to jump to.

## Constraints

- Go and Bubble Tea (lipgloss, bubbles), one static binary.
- Keyboard-first; tmux-friendly (don't steal tmux's prefix key).
- Watch only reads `.coordinator/events.jsonl` and launch logs; every action is
  a `coord` command the engine may refuse.

## Deliverables

Wireframes of the side pane at 60×40 and 44×40, and of the full window at
132×40; the unit view inside the side pane; key bindings (including jumping to
an agent's window and back); each state above; and a recommended first version.
