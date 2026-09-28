# help.sh: `filo help [verb]` (sourced by bin/filo; needs no repo).

help_index() {
  cat <<'EOF'
filo: the coordinator engine. One line out per result; a refusal is
"REFUSED <unit> <event>: <reason>". `filo help <verb>` for details.

you:
  watch                    follow the run live and act on what waits for you

coordinator:
  init                     set up the run (asks the user once), start the relay
  unit add <id> ...        add a unit of work
  brief <id>               draft the unit's next worker brief to fill in
  dispatch <id> ...        launch a worker or critic for a unit
  research --brief <file>  launch a read-only researcher (no unit)
  approve|reject <id>      record the user's decision on a passed unit
  merge <id>               merge an approved unit (re-runs VERIFY)
  msg|block|reopen|drop    other decisions
  gate add|decide|list     reversible choices made on a default
  standing [add "<rule>"]  standing orders every launch and batch carries
  role [<role> ...]        each role agent's harness, model, and skills
  skills [<role>]          skills a role's harness can use
  status                   the run at a glance
  log [<id>]               full event history

role agents (worker, critic, researcher):
  finish ...               report the result; this wakes the coordinator

plumbing (init and the relay use these):
  start, relay, cfg, unit next, done
EOF
}

help_verb() {
  case "$1" in
    watch) cat <<'EOF'
filo watch                                 the live view (in its own terminal)
filo watch --once [--width N] [--height N] [--open <unit> [--tab <tab>]]
                                           one frame on stdout, then exit
  The only command meant for people. It shows whether the coordinator is
  moving, one "needs you" line when something waits on you, and WORK: every
  unit in progress with its agent (role, round, time, liveness, latest
  output), its branch, worktree and changed files, and the critic's notes;
  open decisions and research reports; then up next, done, and recent events.
  It redraws once a second; clean passes merge on their own. A unit shows
  "needs you" when the critic left notes, the unit is marked risky, or it
  is blocked; open decisions and unread reports need you too.

  Moving
    j / k, ↓ / ↑, tab   select the next / previous item in WORK

  On the ▸ selected item
    a       approve a passed unit and merge it (re-running its checks)
    r       send a passed unit back, with a note
    o / x   reopen / drop a blocked unit (drop asks first; it is final)
    c / d   confirm / change an open decision
    v       read a research report
    ↵       open it: a unit in its own view (below); a report; a
            researcher's output. With nothing selected, asks which unit.

  In a unit's view
    1-6, ← / →   the tab: brief, findings, diff, log (the merge's checks),
                 output, history
    j / k, space scroll; the output of a running agent follows its tail
                 until you scroll up
    n / N        next / previous file in the diff
    [ / ]        an earlier / later round's output
    p            this tab in $PAGER
    esc          back to the main screen
    a / r        approve / reject, when the unit passed

  Anywhere
    m       send the coordinator a message
    w       restart the wake process, when it is down
    ?       this page
    q       quit (the run keeps going)

  Mouse
    click an item to select it, the selected one again to open it; click a
    "needs you" entry to jump to it, a unit in up next or done to open it,
    a key in the bottom bar to press it. The wheel moves the selection over
    WORK and scrolls RECENT back. In a unit's view, click a tab to show it
    or "esc ‹" to go back; the wheel scrolls it.
    In a prompt: ↵ or ✓ send sends, esc or ✗ cancel cancels. Shift-drag
    selects text in most terminals while watch has the mouse.

  NO_COLOR turns colors off.
EOF
    ;;
    init) cat <<'EOF'
filo init [--accept | --answers "key=value ..."] [--harness <h>] [--session <id>]
  Detects the harnesses; in an unconfigured repo prints PROPOSE and an ASK
  block and stops: ask the user, then re-run with --accept or --answers.
  Then starts the run: SESSION ... and RELAY pid=... If no session id can be
  found, pass --session <the harness's real session id>; never invent one.
EOF
    ;;
    brief) cat <<'EOF'
filo brief <id>
  -> BRIEF <id> <path> needs=<fields>
  Writes the unit's next worker brief as a draft: the playbook's fields for a
  first round, the last brief plus CORRECTION for a later one. Replace every
  <fill: ...>; `filo dispatch <id> --role worker` then uses it. VERIFY lines
  start with "$ " and are re-run by the critic and by merge. Calling it again
  returns the same draft.
EOF
    ;;
    gate) cat <<'EOF'
filo gate add "<question>" --default "<choice>" [--options "<a · b>"]
  -> GATE G<n> open default=<choice>      go ahead on the default now
filo gate decide G<n> "<answer>"
  -> GATE G<n> decided: <answer>           (and NEXT when it differs)
filo gate list                           the open gates
EOF
    ;;
    role) cat <<'EOF'
filo role
  -> ROLE <role> harness=<h> model=<m> skills=<a,b>   one line per role
filo role <role> [--global] [--harness <h>] [--model <m>]
                 [--skill <name>]... [--drop-skill <name>]...
  -> ROLE <role> ...   the role after the change
  Roles: worker, worker:<lane> (e.g. worker:strong), critic, researcher.
  Settings live in the repo's .filo/config.conf; --global writes your
  defaults in ~/.filo/roles.conf, which every repo uses unless it sets
  its own. The model is checked against the harness where it can be; a skill
  must be installed (filo skills <role>). A role's skills are named in every
  prompt it gets, with the SKILL.md path to read.
EOF
    ;;
    skills) echo 'filo skills [<role>]   -> SKILL <name> <path>, the role'"'"'s own harness first (default role: worker)' ;;
    standing) cat <<'EOF'
filo standing add "<rule>"   -> STANDING <n>: <rule>
filo standing                the standing orders
  One constraint per rule; every launch and every batch carries them.
EOF
    ;;
    unit) cat <<'EOF'
filo unit add <id> --kind <kind> --goal "<goal>" [--deps a,b] [--risk <risk>]
  -> ADDED <id> kind=<kind>
  kind picks the playbook (feature, bugfix, refactor, chore, or a repo
  playbook in .filo/playbooks/). A unit is ready when its deps are
  merged or dropped. --risk routes the worker to lane routing.<risk>.
  Ids are [A-Za-z0-9_-]+.
filo unit next
  -> the ready ids, space-separated (nothing when none)
EOF
    ;;
    dispatch) cat <<'EOF'
filo dispatch <id> --role worker [--brief <file>]   (default: the filo brief draft)
filo dispatch <id> --role critic
  -> DISPATCHED <id> role=<r> round=<n> slug=<s> pid=<p> wt=<path> log=<path>
  The engine computes the round and slug, creates the worktree, and appends
  the finish contract. A stalled worker redispatched without --brief
  reuses its last brief. The critic's brief is composed from the worker brief; never write it.
EOF
    ;;
    research) cat <<'EOF'
filo research --brief <file>
  -> RESEARCH <slug> pid=<p> report=<path> log=<path>
  The brief needs GOAL: (TIMEBOX: optional). The researcher writes a decision
  brief to the report path and finishes; its event wakes the coordinator.
EOF
    ;;
    finish) cat <<'EOF'
filo finish --result <result> --summary "<one line>" [--slug <slug>]
            [--evidence <level>] [--ran "<command>"]... [--flag <flag>]...
  -> FINISHED <slug> -> <state> | DUP <slug>
  For role agents. Run it once, as the last thing you do: it records your
  result and wakes the coordinator. Your prompt's FINISH CONTRACT gives the
  exact command, with the slug you owe (FILO_OWES); never invent one.
  worker:     --result done|partial
  critic:     --result pass|handback, --evidence none|typecheck|tests|live,
              one --ran per command you ran, --flag only for what you proved,
              --note for anything the user should see before it merges
              (a pass with no notes merges on its own under auto-merge)
  researcher: --result done, after writing the report
EOF
    ;;
    approve|reject|msg|block|reopen|drop) cat <<'EOF'
filo approve <id> ["<note>"]      the user approved a passed unit
filo reject <id> ["<note>"]       the user rejected it; back to handback
filo msg <id|-> "<text>"          a message for the coordinator (wakes it)
filo block <id> --reason "<r>"    stop the unit (and its live launch)
filo reopen <id> --reason "<r>"   unblock it
filo drop <id> --reason "<r>"     abandon it for good (final); prints READY/DONE like merge
EOF
    ;;
    merge) cat <<'EOF'
filo merge <id>
  -> MERGED <id> sha=<sha>, then READY <ids> and DONE when they apply
  Needs a recorded approval of this round, or, under autonomy=auto-merge (the
  default), a clean pass: no critic notes and no --risk. finish starts that
  merge itself (--auto). Needs the exact reviewed state. Commits it with the user's identity, re-runs the
  brief's VERIFY on it (new files VERIFY makes are dropped; edits to reviewed
  files refuse), and merges locally. Pushing is a separate decision.
EOF
    ;;
    status) cat <<'EOF'
filo status
  STATUS relay=<pid> alive=0|1 undelivered=<n> inflight=<n>
  UNIT <id> <state> kind=… round=… ready=… pid=… alive=… goal=…
  LOG <id> <slug> <last line of a live launch's log>
EOF
    ;;
    log) echo 'filo log [<id>]   "<seq> <type> <unit|-> <what>" per event' ;;
    done) echo 'filo done   -> DONE units=<n> (exit 0) | OPEN <ids> (exit 1)' ;;
    start) cat <<'EOF'
filo start [--harness <h>] [--session <id>] [--no-relay]
  -> SESSION <id> source=<...> harness=<h> repo=<repo>  [RELAY pid=<pid>]
EOF
    ;;
    relay) cat <<'EOF'
filo relay [--once] [--interval N] [--max-attempts N] [--backoff N]   (started by init)
filo relay --detach   restart this run's relay in the background, unless one is alive
filo relay --stop     stop this run's relay (a coordinator turn in flight finishes)
EOF
    ;;
    cfg) echo 'filo cfg get|set|unset|keys <file> ...   flat key=value config' ;;
    *) echo "filo: no help for \"$1\"" >&2; return 2 ;;
  esac
}
