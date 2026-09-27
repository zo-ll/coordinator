# Design brief: `coord watch` in bash and tmux only

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
with bash and the tools tmux already provides. That is the constraint to design
within, and the reason for this round.

## What each surface can do

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
   tmux prefix; the user returns with tmux's own keys.

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

## Constraints

- bash 4.4+, coreutils, awk, less, tmux 3.2+ (for popups). Nothing else to
  install.
- The panel reads `coord status` / `coord log` output (one line per item);
  every action is a `coord` command, which the engine may refuse.
- Keyboard only.

## Deliverables

Mockups of each surface at real character sizes (panel at 60×40 and 44×40,
popup at 80% of a 132×40 window, menus and status bar as tmux renders them),
the key map, the per-state menu table, and a recommended first version.
