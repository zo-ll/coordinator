# help.sh: `coord help [verb]` (sourced by bin/coord; needs no repo).

help_index() {
  cat <<'EOF'
coord: the coordinator engine. One line out per result; a refusal is
"REFUSED <unit> <event>: <reason>". `coord help <verb>` for details.

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
  detect, plan, apply, start, relay, cfg, unit next, done
EOF
}

help_verb() {
  case "$1" in
    init) cat <<'EOF'
coord init [--accept | --answers "key=value ..."] [--harness <h>] [--session <id>]
  Detects the harnesses; in an unconfigured repo prints PROPOSE and an ASK
  block and stops: ask the user, then re-run with --accept or --answers.
  Then starts the run: SESSION ... and RELAY pid=... If no session id can be
  found, pass --session <the harness's real session id>; never invent one.
EOF
    ;;
    brief) cat <<'EOF'
coord brief <id>
  -> BRIEF <id> <path> needs=<fields>
  Writes the unit's next worker brief as a draft: the playbook's fields for a
  first round, the last brief plus CORRECTION for a later one. Replace every
  <fill: ...>; `coord dispatch <id> --role worker` then uses it. VERIFY lines
  start with "$ " and are re-run by the critic and by merge. Calling it again
  returns the same draft.
EOF
    ;;
    gate) cat <<'EOF'
coord gate add "<question>" --default "<choice>" [--options "<a · b>"]
  -> GATE G<n> open default=<choice>      go ahead on the default now
coord gate decide G<n> "<answer>"
  -> GATE G<n> decided: <answer>           (and NEXT when it differs)
coord gate list                           the open gates
EOF
    ;;
    role) cat <<'EOF'
coord role
  -> ROLE <role> harness=<h> model=<m> skills=<a,b>   one line per role
coord role <role> [--global] [--harness <h>] [--model <m>]
                  [--skill <name>]... [--drop-skill <name>]...
  -> ROLE <role> ...   the role after the change
  Roles: worker, worker:<lane> (e.g. worker:strong), critic, researcher.
  Settings live in the repo's .coordinator/config.conf; --global writes your
  defaults in ~/.coordinator/roles.conf, which every repo uses unless it sets
  its own. The model is checked against the harness where it can be; a skill
  must be installed (coord skills <role>). A role's skills are named in every
  prompt it gets, with the SKILL.md path to read.
EOF
    ;;
    skills) echo 'coord skills [<role>]   -> SKILL <name> <path>, the role'"'"'s own harness first (default role: worker)' ;;
    standing) cat <<'EOF'
coord standing add "<rule>"   -> STANDING <n>: <rule>
coord standing                the standing orders
  One constraint per rule; every launch and every batch carries them.
EOF
    ;;
    unit) cat <<'EOF'
coord unit add <id> --kind <kind> --goal "<goal>" [--deps a,b] [--risk <risk>]
  -> ADDED <id> kind=<kind>
  kind picks the playbook (feature, bugfix, refactor, chore, or a repo
  playbook in .coordinator/playbooks/). A unit is ready when its deps are
  merged or dropped. --risk routes the worker to lane routing.<risk>.
  Ids are [A-Za-z0-9_-]+.
coord unit next
  -> the ready ids, space-separated (nothing when none)
EOF
    ;;
    dispatch) cat <<'EOF'
coord dispatch <id> --role worker [--brief <file>]   (default: the coord brief draft)
coord dispatch <id> --role critic
  -> DISPATCHED <id> role=<r> round=<n> slug=<s> pid=<p> wt=<path> log=<path>
  The engine computes the round and slug, creates the worktree, and appends
  the finish contract. A stalled worker redispatched without --brief
  reuses its last brief. The critic's brief is composed from the worker brief; never write it.
EOF
    ;;
    research) cat <<'EOF'
coord research --brief <file>
  -> RESEARCH <slug> pid=<p> report=<path> log=<path>
  The brief needs GOAL: (TIMEBOX: optional). The researcher writes a decision
  brief to the report path and finishes; its event wakes the coordinator.
EOF
    ;;
    finish) cat <<'EOF'
coord finish --result <result> --summary "<one line>" [--slug <slug>]
             [--evidence <level>] [--ran "<command>"]... [--flag <flag>]...
  -> FINISHED <slug> -> <state> | DUP <slug>
  For role agents. Run it once, as the last thing you do: it records your
  result and wakes the coordinator. Your prompt's FINISH CONTRACT gives the
  exact command, with the slug you owe (COORD_OWES); never invent one.
  worker:     --result done|partial
  critic:     --result pass|handback, --evidence none|typecheck|tests|live,
              one --ran per command you ran, --flag only for what you proved
  researcher: --result done, after writing the report
EOF
    ;;
    approve|reject|msg|block|reopen|drop) cat <<'EOF'
coord approve <id> ["<note>"]      the user approved a passed unit
coord reject <id> ["<note>"]       the user rejected it; back to handback
coord msg <id|-> "<text>"          a message for the coordinator (wakes it)
coord block <id> --reason "<r>"    stop the unit (and its live launch)
coord reopen <id> --reason "<r>"   unblock it
coord drop <id> --reason "<r>"     abandon it for good (final); prints READY/DONE like merge
EOF
    ;;
    merge) cat <<'EOF'
coord merge <id>
  -> MERGED <id> sha=<sha>, then READY <ids> and DONE when they apply
  Needs a recorded approval of this round (or autonomy=auto-merge) and the
  exact reviewed state. Commits it with the user's identity, re-runs the
  brief's VERIFY on it (new files VERIFY makes are dropped; edits to reviewed
  files refuse), and merges locally. Pushing is a separate decision.
EOF
    ;;
    status) cat <<'EOF'
coord status
  STATUS relay=<pid> alive=0|1 undelivered=<n> inflight=<n>
  UNIT <id> <state> kind=… round=… ready=… pid=… alive=… goal=…
  LOG <id> <slug> <last line of a live launch's log>
EOF
    ;;
    log) echo 'coord log [<id>]   "<seq> <type> <unit|-> <what>" per event' ;;
    done) echo 'coord done   -> DONE units=<n> (exit 0) | OPEN <ids> (exit 1)' ;;
    detect) echo 'coord detect   -> DETECT current=<h> installed=<a,b> spawnable=<a,b>' ;;
    plan) echo 'coord plan   -> PROPOSE <key=value>... then an ASK block of fields to confirm' ;;
    apply) echo 'coord apply --accept | --answers "key=value ..."   -> OK config=<path> | FAIL <field>: <reason>' ;;
    start) cat <<'EOF'
coord start [--harness <h>] [--session <id>] [--no-relay]
  -> SESSION <id> source=<...> harness=<h> repo=<repo>  [RELAY pid=<pid>]
EOF
    ;;
    relay) echo 'coord relay [--once] [--interval N] [--max-attempts N] [--backoff N]   (started by start)' ;;
    cfg) echo 'coord cfg get|set|unset|keys <file> ...   flat key=value config' ;;
    *) echo "coord: no help for \"$1\"" >&2; return 2 ;;
  esac
}
