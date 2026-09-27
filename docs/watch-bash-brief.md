# Design brief: `coord watch` in bash, on any terminal multiplexer

Repo: https://github.com/zo-ll/coordinator. Read `docs/watch-brief.md` (the
panel's job) and `SKILL.md` (what the coordinator does).

Your v3 side panel is the target experience; keep its vocabulary: the needs-you
box that only exists when something waits, rows that read as sentences
("unblocks s4, s5"), the one-line coordinator status (idle, working, wake
queued, wake typed awaiting ack, stuck), liveness ("log 4s ago", "quiet 41s"),
timebox bars, the window column with `g` (go to an agent's window) and `c` (go
to the coordinator pane), keys shown only when the engine would accept them,
and every action shown as its exact `coord` command plus the one-line reply.

**What changed: no Go, no TUI library.** The whole interface must be buildable
with bash and what the user's terminal multiplexer provides. That is the
constraint to design within, and the reason for this round.

**And no multiplexer is required, tmux included.** coordinator talks to the
multiplexer only through an adapter, one bash file per multiplexer
(`adapters/tmux.sh`, `adapters/zellij.sh`, …, or none at all). tmux is just
the first adapter. The design must not depend on anything a particular
multiplexer offers; it depends on *capabilities* an adapter may or may not have.

## Two tiers

Every surface below is either **core** (always available, drawn by bash in the
panel) or **optional** (a capability the adapter reports). Design both tiers:

- **Tier 1, full:** an adapter with every optional capability, e.g. tmux. Your
  Turn 2 design is this tier.
- **Tier 2, panel-only:** the baseline for every other case: a multiplexer
  that can only open and focus panes (zellij, wezterm, kitty, GNU screen), or
  no multiplexer at all. Everything tier 1 does must still be possible, drawn
  inside the panel.

The adapter capabilities:

| capability | what it gives | if missing (tier 2) |
|---|---|---|
| `send`, `capture`, `alive` | type the wake into the coordinator pane, read what it shows | coordinator falls back to headless resume |
| `spawn`, `focus` | each agent in its own pane or window; `g` and `c` jump there | agents run in the background; `l` follows a log in the panel |
| `popup` | an overlay running `less` | the panel pauses and runs `less` full-screen; `q` returns |
| `menu` | a native menu with shortcut keys | the menu is drawn over the panel's footer rows |
| `prompt` | a one-line input outside the panel | `read -e` on the panel's bottom row |
| `status` | a short segment visible from every window | a line at the top of the panel, plus the bell |
| `message` | a transient notice visible from every window | the panel's reply line, plus the bell |

`spawn`/`focus` and the rest are independent: a multiplexer may have `focus`
but no `popup` (wezterm, kitty), so tier 2 can still have `g` and `c`.

## What each surface can do (the tmux adapter, for tier 1)

1. **The side panel** is a bash loop that clears and redraws the pane about
   once a second. It can use colour (16 or 256), bold, dim, reverse video and
   Unicode box drawing; it knows the pane's width and height; it reads one key
   at a time. It cannot scroll inside itself, animate smoothly, or take mouse
   input. Everything on it must fit the pane; anything longer goes elsewhere.
2. **Popups** (`tmux display-popup`): a floating box over the current window,
   sized as a percentage, running any command. Detail views are plain text
   documents opened in `less` inside a popup: scrollable, searchable, `q` to
   close. Design these as documents (headings, sections, colour via ANSI), not
   as widgets. One popup at a time.
3. **Menus** (`tmux display-menu`): tmux's own menu, a titled list of items,
   each with a shortcut key, separators allowed. Its look is fixed by tmux;
   design the titles, items, order, keys, and which items appear in which unit
   state.
4. **Prompts** (`tmux command-prompt`): a one-line text input in the tmux
   status line, with a label. Used for notes and reasons ("reject s2: …").
5. **The status bar** (`status-right`): a short segment, visible from every
   tmux window, including while the user is inside an agent's window. Good for
   a needs-you count and relay health.
6. **Messages** (`tmux display-message`): a transient one-line notice in the
   status line, plus the terminal bell.
7. **Navigation**: `select-window` and `select-pane`, as in v3. Never bind the
   multiplexer's prefix; the user returns with the multiplexer's own keys, so
   the key map must say "your multiplexer's back key", not `prefix l`.

## What to design

1. **The side panel** at 60×40 and 44×40, as v3, within surface 1: which
   parts stay, what the redraw-only constraint changes (no scrolling list, so
   what happens with 12 units?), and how selection works with one key at a
   time.
2. **The unit popup**: the text document for one unit (header, state, the
   critic's verdict and evidence, the brief, history by round, the diff), and
   how the user moves between those sections inside `less` (search, marks, or
   one popup per section).
3. **The unit menu**: opened with enter on a unit. Items per state (passed:
   approve, reject, open critic report; blocked: reopen, drop, history; running:
   go to window, peek, block), with shortcut keys.
4. **Prompts** for reject, block, drop, reopen and message: labels and default
   text.
5. **The status bar segment**: calm, something needs you, relay down, and
   coordinator stuck, in at most about 30 characters.
6. **Messages**: the wording for an approval sent, a refusal from the engine,
   and a new needs-you item arriving while the user is in another window.
7. **The states** from v3, in these surfaces: planning (no units), all merged,
   relay down, coordinator pane gone, wake undelivered, coordinator stuck on a
   dialog, a unit blocked after two deaths, and no tmux at all (then only the
   panel exists: what replaces popups and menus?).

## For this round

Your Turn 2 is a strong tier 1 and already sketches no-tmux fallbacks. Now:

1. Label every surface in Turn 2 with the capability it needs.
2. Design tier 2 as a first-class baseline, not a fallback footnote: the panel
   with its in-panel menu, prompt, status line and reply line; `less`
   full-screen instead of a popup; and the two sub-cases, with `focus` (`g`,
   `c` still jump) and without (`l` follows logs in place).
3. Make the key map multiplexer-neutral: panel keys are the same in both
   tiers; "back" is described per multiplexer.
4. Show what changes when a user moves the same run from tmux to a
   panel-only multiplexer: nothing about the run, only the surfaces.

## Constraints

- bash 4.4+, coreutils, awk, less. A multiplexer is optional; tier 1 on tmux
  needs tmux 3.2+ (for popups). Nothing else to install.
- The panel reads `coord status` / `coord log` output (one line per item);
  every action is a `coord` command, which the engine may refuse.
- Keyboard only.

## Deliverables

Mockups of each surface at real character sizes, for both tiers (panel at 60×40
and 44×40; tier 1 popup at 80% of a 132×40 window, menus and status bar as tmux
renders them; tier 2 in-panel menu, prompt and full-screen `less`), the
capability label on each surface, the multiplexer-neutral key map, the per-state
menu table, and a recommended first version.
