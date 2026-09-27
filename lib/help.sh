# help.sh: `coord help [verb]` (sourced by bin/coord; needs no repo).

help_index() {
  cat <<'EOF'
coord: the coordinator engine. One line out per result; a refusal is
"REFUSED <unit> <event>: <reason>". `coord help <verb>` for details.

coordinator:
  unit add <id> ...        add a unit of work
  unit next                ids ready to dispatch
  dispatch <id> ...        launch a worker or critic for a unit
  research --brief <file>  launch a read-only researcher (no unit)
  approve|reject <id>      record the user's decision on a passed unit
  merge <id>               merge an approved unit (re-runs VERIFY)
  msg|block|reopen|drop    other decisions
  status                   the run at a glance
  log [<id>]               full event history
  done                     DONE when every unit is merged or dropped

role agents (worker, critic, researcher):
  finish ...               report the result; this wakes the coordinator

boot and plumbing:
  detect, plan, apply, start, relay, cfg, render
EOF
}

help_verb() {
  case "$1" in
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
coord dispatch <id> --role worker [--brief <file>]
coord dispatch <id> --role critic
  -> DISPATCHED <id> role=<r> round=<n> slug=<s> pid=<p> wt=<path> log=<path>
  The engine computes the round and slug, creates the worktree, and appends
  the finish contract. A worker redispatch without --brief reuses the last
  brief. The critic's brief is composed from the worker brief; never write it.
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
  Needs a recorded approval (or autonomy=auto-merge) and the exact reviewed
  state; re-runs the brief's VERIFY, commits with the user's identity, and
  merges locally. Pushing is a separate decision.
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
    detect) echo 'coord detect   -> DETECT current=<h> installed=<a,b> spawnable=<a,b> tmux=0|1 gh=0|1' ;;
    plan) echo 'coord plan   -> PROPOSE <key=value>... then an ASK block of fields to confirm' ;;
    apply) echo 'coord apply --accept | --answers "key=value ..."   -> OK config=<path> | FAIL <field>: <reason>' ;;
    start) cat <<'EOF'
coord start [--harness <h>] [--session <id>] [--no-relay]
  -> SESSION <id> source=<...> harness=<h> repo=<repo>  [RELAY pid=<pid>]
EOF
    ;;
    relay) echo 'coord relay [--once] [--interval N] [--max-attempts N] [--backoff N]   (started by start)' ;;
    cfg) echo 'coord cfg get|set|unset|keys <file> ...   flat key=value config' ;;
    render) echo 'coord render   -> RENDERED <path>   writes COORDINATION.md' ;;
    *) echo "coord: no help for \"$1\"" >&2; return 2 ;;
  esac
}
