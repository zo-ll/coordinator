# cmd.sh: the coord subcommands (sourced by bin/coord after core.sh).

declare -gA F FM

# parse_args <prog> "<value flags>" "<list flags>" "<bool flags>" args...:
# --name value into F[name], repeatable --name value into FM[name]
# (newline-separated), --name into F[name]=1.
parse_args() {
  local prog=$1 vals=" $2 " lists=" $3 " bools=" $4 " a n
  shift 4
  F=(); FM=()
  while [ $# -gt 0 ]; do
    a=$1 n=${1#--}
    if [[ $a == --* && $bools == *" $n "* ]]; then F[$n]=1; shift; continue; fi
    if [[ $a == --* && ( $vals == *" $n "* || $lists == *" $n "* ) ]]; then
      [ $# -ge 2 ] || { fail 2 '%s: %s needs a value' "$prog" "$a"; return; }
      if [[ $lists == *" $n "* ]]; then FM[$n]+="$2"$'\n'; else F[$n]=$2; fi
      shift 2; continue
    fi
    fail 2 '%s: unknown arg: %s' "$prog" "$a"; return
  done
}

# ---------------------------------------------------------------- units

#   unit add <id> --kind <k> --goal "<g>" [--deps a,b] [--risk <r>]  -> ADDED <id> kind=<k>
#   unit next                                                     -> ready ids
cmd_unit() {
  local sub=${1:-}; [ $# -gt 0 ] && shift
  case "$sub" in
    add)
      local id=${1:-}
      [[ -n $id && $id != --* ]] || { fail 2 'unit add: <id> is required'; return; }
      shift
      parse_args "unit add" "kind goal deps risk" "" "" "$@"
      local kind=${F[kind]:-} goal=${F[goal]:-} risk=${F[risk]:-} deps="" d
      [ -n "$kind" ] && [ -n "$goal" ] || { fail 2 'unit add: --kind and --goal are required'; return; }
      playbook "$kind" || { refuse "$id" unit_added "$PB_ERR"; return; }
      local IFS=,
      for d in ${F[deps]:-}; do
        d=${d// /}; [ -n "$d" ] && deps+="${deps:+,}$d"
      done
      unset IFS
      one_event type=unit_added unit="$id" kind="$kind" goal="$goal" deps="$deps" risk="$risk" || return
      echo "ADDED $id kind=$kind"
      ;;
    next)
      local ids
      ids=$(model units | awk -F"$US" '$19 == 1 { print $1 }' | paste -sd' ' -)
      [ -z "$ids" ] || echo "$ids"
      ;;
    *) fail 2 'usage: coord unit add|next ...' ;;
  esac
}

# ---------------------------------------------------------------- dispatch

# next_round <role>: from U_*, the round this dispatch must carry (NR), or
# NR_ERR with the reason it can't be dispatched now.
next_round() {
  NR_ERR=""
  case "$1:$U_STATE" in
    worker:todo)
      [ "$U_READY" = 1 ] || { NR_ERR="not ready (deps $U_DEPS)"; return 1; }
      NR=$((U_ROUND + 1)) ;;
    worker:handback) NR=$((U_ROUND + 1)) ;;
    critic:built) NR=$U_ROUND ;;
    *)
      if [ "$U_STATE" = stalled ] && [ "$U_ROLE" = "$1" ]; then
        [ "$U_DEATHS" -lt 2 ] || { NR_ERR="died 2 times in round $U_ROUND"; return 1; }
        NR=$U_ROUND
      else
        NR_ERR="cannot dispatch a $1 from $U_STATE"; return 1
      fi ;;
  esac
}

# make_worktree <id>: <run>/worktrees/<id> on coord/<id> off the base
# (config merge.base, else main), reusing the branch if it exists. Sets
# WT_PATH WT_BRANCH WT_BASE, or WT_ERR.
make_worktree() {
  local id=$1 baseref cur
  baseref=$(cfg_val "$CONFIG" merge.base); baseref=${baseref:-main}
  WT_BASE=$(git -C "$REPO" rev-parse --verify --quiet "$baseref^{commit}" 2>/dev/null) || {
    WT_ERR="base \"$baseref\" not found in $REPO"; return 1; }
  WT_PATH="$RUN/worktrees/$id" WT_BRANCH="coord/$id"
  if [ -e "$WT_PATH" ] || [ -L "$WT_PATH" ]; then
    # left by a dispatch that never got recorded: reuse it if it is ours
    cur=$(git -C "$WT_PATH" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
    [ "$cur" = "$WT_BRANCH" ] && return 0
    WT_ERR="worktree path already exists: $WT_PATH"; return 1
  fi
  mkdir -p "$(dirname "$WT_PATH")"
  if git -C "$REPO" rev-parse --verify --quiet "refs/heads/$WT_BRANCH" >/dev/null 2>&1; then
    git -C "$REPO" worktree add -q "$WT_PATH" "$WT_BRANCH" >&2 || { WT_ERR="git worktree add failed for $WT_BRANCH"; return 1; }
  else
    git -C "$REPO" worktree add -q -b "$WT_BRANCH" "$WT_PATH" "$WT_BASE" >&2 || { WT_ERR="git worktree add failed for $WT_BRANCH"; return 1; }
  fi
}

# critic_brief <round> <worker brief>: the critic's assignment, composed from
# the worker brief's criteria only; CONTEXT and other coordinator prose never
# reach the critic.
critic_brief() {
  local round=$1 wb=$2 f
  printf 'Review unit %s (%s), round %s, in the worktree %s.\n' "$U_ID" "$U_KIND" "$round" "$U_WT"
  printf 'The change under review is the whole working tree against HEAD: `git diff HEAD`\n'
  printf 'plus untracked files (the worker never commits). Judge it against these\n'
  printf "criteria only; you do not see the worker's or the coordinator's reasoning.\n\n"
  for f in GOAL SCOPE REPRO ACCEPTANCE VERIFY; do
    if brief "$wb" get "$f" >/dev/null 2>&1; then
      printf '%s: %s\n\n' "$f" "$(brief "$wb" get "$f")"
    fi
  done
  printf 'Do not edit tracked files, commit, push, or merge. Run the checks yourself.\n'
}

# finish_contract <role> <slug> [report]: the generated last section of a prompt
finish_contract() {
  local role=$1 slug=$2 report=${3:-} call f
  call="COORD_EVENTS=$LOG COORD_OWES=$slug $SELF finish"
  echo "FINISH CONTRACT (do not skip; this is the completion protocol):"
  case "$role" in
    worker)
      echo "$call --result done --summary \"<one line>\""
      echo "If you cannot complete it (out of time, blocked, brief conflicts with the repo),"
      echo "finish with --result partial and say what is left in the summary."
      ;;
    critic)
      printf '%s --result pass|handback --evidence <%s> --ran "<command>" [--ran "<command>"]...' "$call" "${LEVELS// /|}"
      for f in $PB_NEED; do printf ' --flag %s' "$f"; done
      printf ' --summary "<one line>"\n'
      printf 'Evidence is the strongest level you proved yourself (%s). This unit needs at\n' "${LEVELS// / < }"
      printf 'least %s' "$PB_FLOOR"
      [ "$PB_FLOOR" = none ] || printf ', with every command you ran as --ran'
      for f in $PB_NEED; do printf ', and --flag %s only if you proved it' "$f"; done
      printf '. A pass below that comes back as a handback.\n'
      ;;
    researcher)
      echo "Write your decision brief to $report, then:"
      echo "$call --result done --summary \"<one line>\""
      ;;
  esac
}

# compose <section> <body file> <contract> > prompt: playbook section, body,
# standing orders, contract; parts separated by blank lines.
compose() {
  local section=$1 body=$2 contract=$3
  [ -n "$section" ] && printf '%s\n\n' "$section"
  printf '%s\n' "$(cat "$body")"
  if [ -s "$RUN/standing.md" ]; then
    printf '\nSTANDING ORDERS (apply to everything you do):\n%s\n' "$(cat "$RUN/standing.md")"
  fi
  printf '\n%s\n' "$contract"
}

#   dispatch <id> --role worker --brief <file>
#   dispatch <id> --role critic
#     -> DISPATCHED <id> role=<r> round=<n> slug=<s> pid=<p> wt=<path> log=<path>
cmd_dispatch() {
  local id=${1:-}
  [[ -n $id && $id != --* ]] || { fail 2 'dispatch: <id> is required'; return; }
  shift
  parse_args dispatch "role brief" "" "" "$@"
  local role=${F[role]:-} briefp=${F[brief]:-}
  [ "$role" = worker ] || [ "$role" = critic ] || { fail 2 'dispatch: --role worker|critic is required'; return; }
  unit_row "$id" || { refuse "$id" dispatched "unknown unit"; return; }
  playbook "$U_KIND" || { refuse "$id" dispatched "$PB_ERR"; return; }
  next_round "$role" || { refuse "$id" dispatched "$NR_ERR"; return; }
  local round=$NR slug="$id.r$NR.$role" rawbrief="" timebox=$PB_TIMEBOX body fields f missing tb
  mkdir -p "$RUN/briefs" "$RUN/log"
  body=$(mktemp "$RUN/.body.XXXXXX")
  if [ "$role" = worker ]; then
    [ -n "$briefp" ] || { [ "$U_STATE" = stalled ] && briefp=$U_BRIEF; }
    [ -n "$briefp" ] || { rm -f "$body"; fail 2 'dispatch: a worker needs --brief <file>'; return; }
    [ -r "$briefp" ] || { rm -f "$body"; refuse "$id" brief "not readable: $briefp"; return; }
    fields=" $(brief "$briefp" fields | paste -sd' ' -) "
    missing=""
    for f in $PB_REQUIRE; do [[ $fields == *" $f "* ]] || missing+="${missing:+ }$f"; done
    if [ -n "$missing" ]; then
      rm -f "$body"; refuse "$id" brief "missing $missing (a $U_KIND brief needs: $PB_REQUIRE)"; return
    fi
    if [[ $fields == *" VERIFY "* ]] && [ -z "$(brief "$briefp" verify)" ]; then
      rm -f "$body"; refuse "$id" brief 'VERIFY has no "$ " command'; return
    fi
    tb=$(brief "$briefp" get TIMEBOX 2>/dev/null | awk '{ print $1; exit }' || true)
    if [ -n "$tb" ]; then
      timebox=$(dur "$tb") || { rm -f "$body"; refuse "$id" brief "TIMEBOX \"$tb\" is not a duration (e.g. 45m)"; return; }
    fi
    rawbrief="$RUN/briefs/$slug.brief.md"
    [ "$briefp" -ef "$rawbrief" ] || cp "$briefp" "$rawbrief"
    cp "$briefp" "$body"
  else
    [ -z "$briefp" ] || { rm -f "$body"; fail 2 "dispatch: a critic's brief is written by the engine; drop --brief"; return; }
    [ -r "$U_BRIEF" ] || { rm -f "$body"; refuse "$id" dispatched "worker brief unreadable: $U_BRIEF"; return; }
    critic_brief "$round" "$U_BRIEF" > "$body"
  fi

  # harness: critic.*; a worker's lane is routing.<risk>, else the playbook's
  local hkey=critic.harness mkey=critic.model lane harness mdl
  if [ "$role" = worker ]; then
    lane=$PB_LANE
    if [ -n "$U_RISK" ]; then
      lane=$(cfg_get "$CONFIG" "routing.$U_RISK") || { rm -f "$body"; refuse "$id" dispatched "no routing.$U_RISK in $CONFIG"; return; }
    fi
    hkey="lane.$lane.harness" mkey="lane.$lane.model"
  fi
  harness=$(cfg_val "$CONFIG" "$hkey")
  [ -n "$harness" ] || { rm -f "$body"; refuse "$id" dispatched "no $hkey in $CONFIG"; return; }
  mdl=$(cfg_val "$CONFIG" "$mkey")

  # the worktree: created on the unit's first worker round, reused after
  local wt=$U_WT fresh=0
  if [ -z "$wt" ]; then
    make_worktree "$id" || { rm -f "$body"; refuse "$id" dispatched "$WT_ERR"; return; }
    wt=$WT_PATH fresh=1
  fi
  U_WT=$wt

  local section prompt="$RUN/briefs/$slug.md" logf="$RUN/log/$slug.log" pid
  section=$(pb_section "$role")
  compose "$section" "$body" "$(finish_contract "$role" "$slug")" > "$prompt"
  rm -f "$body"
  build_argv "$harness" "$role" "$prompt" "$wt" "$mdl" || { refuse "$id" dispatched "no argv for harness \"$harness\""; return; }

  # launch and record in one transaction: the launch's own finish waits on
  # the log's lock, so it always finds its dispatch recorded
  local extra=()
  [ "$fresh" = 1 ] && extra=(worktree="$WT_PATH" branch="$WT_BRANCH" base="$WT_BASE")
  LAUNCHED=""
  dispatch_events() {
    LAUNCHED=$(launch "$role" "$wt" "$logf" "$slug" "${ARGV[@]}") || { refuse "$id" dispatched "cannot launch ${ARGV[0]}"; return 1; }
    ev type=dispatched unit="$id" role="$role" round="$round" slug="$slug" pid="$LAUNCHED" \
      harness="$harness" model="$mdl" timebox="$timebox" log="$logf" brief="$rawbrief" "${extra[@]}"
  }
  if ! commit dispatch_events; then
    kill_group "$LAUNCHED" TERM   # refused: never leave an unrecorded launch running
    return 1
  fi
  echo "DISPATCHED $id role=$role round=$round slug=$slug pid=$LAUNCHED wt=$wt log=$logf"
}

#   research --brief <file>  -> RESEARCH <slug> pid=<p> report=<path> log=<path>
cmd_research() {
  parse_args research "brief" "" "" "$@"
  local briefp=${F[brief]:-} timebox=1800 tb harness n slug report prompt logf pid body
  [ -n "$briefp" ] && [ -r "$briefp" ] || { fail 2 'research: --brief <file> is required and readable'; return; }
  [[ " $(brief "$briefp" fields | paste -sd' ' -) " == *" GOAL "* ]] || { refuse "" brief "missing GOAL (a research brief needs: GOAL)"; return; }
  tb=$(brief "$briefp" get TIMEBOX 2>/dev/null | awk '{ print $1; exit }' || true)
  if [ -n "$tb" ]; then timebox=$(dur "$tb") || { refuse "" brief "TIMEBOX \"$tb\" is not a duration (e.g. 45m)"; return; }; fi
  harness=$(cfg_val "$CONFIG" researcher.harness)
  [ -n "$harness" ] || { refuse "" dispatched "no researcher.harness in $CONFIG"; return; }
  n=$(grep -cE $'\ttype=dispatched\t(.*\t)?role=researcher\t' "$LOG" 2>/dev/null || true)
  n=$(( ${n:-0} + 1 ))
  slug="research.$n" report="$RUN/research/$n.md" prompt="$RUN/briefs/$slug.md" logf="$RUN/log/$slug.log"
  mkdir -p "$RUN/research" "$RUN/briefs"
  compose "" "$briefp" "$(finish_contract researcher "$slug" "$report")" > "$prompt"
  build_argv "$harness" researcher "$prompt" "$REPO" "$(cfg_val "$CONFIG" researcher.model)" || {
    refuse "" dispatched "no argv for harness \"$harness\""; return; }
  LAUNCHED=""
  research_events() {
    LAUNCHED=$(launch researcher "$REPO" "$logf" "$slug" "${ARGV[@]}") || { refuse "" dispatched "cannot launch ${ARGV[0]}"; return 1; }
    ev type=dispatched role=researcher slug="$slug" pid="$LAUNCHED" report="$report" \
      harness="$harness" timebox="$timebox" log="$logf"
  }
  if ! commit research_events; then kill_group "$LAUNCHED" TERM; return 1; fi
  echo "RESEARCH $slug pid=$LAUNCHED report=$report log=$logf"
}

# ---------------------------------------------------------------- finish

# shortfall: why the evidence does not meet the playbook, or empty
shortfall() {
  local level=$1 ran=$2 flags=$3 why="" need
  [ "$(rank "$level")" -ge "$(rank "$PB_FLOOR")" ] || why="evidence $level is below the $PB_KIND floor $PB_FLOOR"
  if [ "$PB_FLOOR" != none ] && [ -z "$ran" ]; then why+="${why:+; }no --ran command recorded"; fi
  for need in $PB_NEED; do
    grep -qxF -- "$need" <<< "$flags" || why+="${why:+; }missing --flag $need"
  done
  printf '%s' "$why"
}

#   finish --result <r> [--evidence <l>] [--ran "<cmd>"]... [--flag <f>]... --summary "<s>" [--slug <s>]
#     -> FINISHED <slug> -> <state> | DUP <slug>
cmd_finish() {
  parse_args finish "result evidence summary slug" "ran flag" "" "$@"
  local slug=${F[slug]:-${COORD_OWES:-}} result=${F[result]:-} level=${F[evidence]:-} summary=${F[summary]:-}
  local ran=${FM[ran]:-} flags=${FM[flag]:-} o kind id="" role="" report="" state="" conv="" r
  [ -n "$slug" ] && [ -n "$result" ] || { fail 2 'finish: --result and the owed slug (--slug or COORD_OWES) are required'; return; }
  existing_events_path >/dev/null || { fail 1 'finish: no event log (set COORD_EVENTS, or run inside the repo or its worktrees)'; return; }
  o=$(model owner -v slug="$slug")
  if [ "$o" = none ]; then
    # the dispatch that owes this slug may still be recording it (it launches
    # inside the log's lock): wait for the lock once, then look again
    flock "$LOG.lock" true
    o=$(model owner -v slug="$slug")
  fi
  IFS=$US read -r kind id report <<< "$o"
  case "$kind" in
    finished) echo "DUP $slug"; return 0 ;;
    research) role=researcher; slug=$id; id="" ;;
    none) refuse "" finished "slug \"$slug\" is not owed by any live launch"; return ;;
    unit)
      unit_row "$id"; role=$U_ROLE; report=""
      if [ "$role" = critic ] && [ "$result" = pass ]; then
        playbook "$U_KIND" || { refuse "$id" finished "$PB_ERR"; return; }
        level=${level:-none}
        [ "$(rank "$level")" -ge 0 ] || { fail 2 'finish: --evidence "%s" is not one of %s' "$level" "${LEVELS// /,}"; return; }
        state=$(state_hash "$U_WT") || { fail 1 'finish: cannot hash the reviewed state in %s' "$U_WT"; return; }
        conv=$(shortfall "$level" "$ran" "$flags")
      fi ;;
  esac
  finish_events() {
    local args=(type=finished unit="$id" role="$role" slug="$slug" result="$result") x
    [ -n "$state" ] && args+=(state="$state" level="$level")
    while IFS= read -r x; do [ -n "$x" ] && args+=(ran="$x"); done <<< "$ran"
    while IFS= read -r x; do [ -n "$x" ] && args+=(flags="$x"); done <<< "$flags"
    args+=(summary="$summary")
    [ -n "$report" ] && args+=(report="$report")
    ev "${args[@]}"
    [ -z "$conv" ] || ev type=converted unit="$id" slug="$slug" from=pass to=handback reason="$conv"
  }
  r=0; commit finish_events || r=$?
  [ "$r" = 3 ] && { echo "DUP $slug"; return 0; }
  [ "$r" = 0 ] || return "$r"
  if [ "$role" = researcher ]; then echo "FINISHED $slug report=$report"
  elif [ -n "$conv" ]; then echo "FINISHED $slug -> handback (converted: $conv)"
  else unit_row "$id"; echo "FINISHED $slug -> $U_STATE"
  fi
}

# ---------------------------------------------------------------- decisions

#   approve|reject <id> ["<note>"]   msg <id|-> "<text>"
#   block|reopen|drop <id> --reason "<r>"   (block and drop stop the live launch)
cmd_decide() {
  local typ=$1 verb=$2; shift 2
  local id=${1:-} text="" reason="" unit
  [[ -n $id && $id != --* ]] || { fail 2 '%s: <id> is required' "$verb"; return; }
  shift
  unit=$id
  case "$typ" in
    approved|rejected|msg)
      text="$*"
      if [ "$typ" = msg ]; then
        [ -n "$text" ] || { fail 2 'msg: <text> is required'; return; }
        [ "$id" = - ] && unit=""
      fi ;;
    *)
      parse_args "$verb" "reason" "" "" "$@"
      reason=${F[reason]:-}
      [ -n "$reason" ] || { fail 2 '%s: --reason is required' "$verb"; return; } ;;
  esac
  STOP=""
  decide_event() {
    if [ "$typ" = blocked ] || [ "$typ" = dropped ]; then
      unit_row "$unit" 2>/dev/null && [ -n "$U_OWES" ] && STOP=$U_PID
    fi
    local args=(type="$typ" unit="$unit")
    [ -n "$text" ] && args+=(text="$text")
    [ -n "$reason" ] && args+=(reason="$reason" by=user)
    ev "${args[@]}"
  }
  commit decide_event || return
  [ -z "$STOP" ] || kill_group "$STOP" TERM
  echo "${typ^^} ${unit:--}"
}

# ---------------------------------------------------------------- merge

# run_verify <wt> <command> <log> <seconds>: exit code (124 on timeout)
run_verify() {
  local rc=0
  printf '$ %s\n' "$2" >> "$3"
  ( cd "$1" && timeout -k 5 "$4" bash -c "$2" ) >> "$3" 2>&1 || rc=$?
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    printf '(timed out after %ss)\n' "$4" >> "$3"; return 124
  fi
  return "$rc"
}

verify_failed() { # <id> <command> <exit> <log> <why>
  one_event type=verify_failed unit="$1" command="$2" exit="$3" log="$4" reason="$5" || return
  refuse "$1" merged "$5 (unit returned to handback; log $4)"
}

#   merge <id>  -> MERGED <id> sha=<sha> [PUSHED origin/<base>]
cmd_merge() {
  local id=${1:-} base cur hash after secs vlog code cmd sha
  [ -n "$id" ] || { fail 2 'merge: <id> is required'; return; }
  unit_row "$id" || { refuse "$id" merged "unknown unit"; return; }
  if ! { [ "$U_STATE" = approved ] || { [ "$U_STATE" = passed ] && [ "$(cfg_val "$CONFIG" autonomy)" = auto-merge ]; }; }; then
    [ "$U_STATE" = passed ] && { refuse "$id" merged "needs the user's approval (coord approve $id)"; return; }
    refuse "$id" merged "cannot merge from $U_STATE"; return
  fi
  base=$(cfg_val "$CONFIG" merge.base); base=${base:-main}
  cur=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
  [ "$cur" = "$base" ] || { refuse "$id" merged "the repo is on \"$cur\", not the base \"$base\""; return; }
  hash=$(state_hash "$U_WT") || { refuse "$id" merged "cannot hash $U_WT"; return; }
  [ "$hash" = "$U_PASS" ] || { refuse "$id" merged "reviewed state $U_PASS != current $hash (re-review required)"; return; }

  # VERIFY, re-run by the engine on the reviewed state
  secs=$(dur "$(cfg_val "$CONFIG" verify.timeout)" 2>/dev/null) || secs=600
  vlog="$RUN/log/$id.verify.log"
  mkdir -p "$RUN/log"; rm -f "$vlog"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    code=0; run_verify "$U_WT" "$cmd" "$vlog" "$secs" || code=$?
    if [ "$code" != 0 ]; then verify_failed "$id" "$cmd" "$code" "$vlog" "verify failed: $cmd (exit $code)"; return; fi
  done < <( [ -r "$U_BRIEF" ] && brief "$U_BRIEF" verify )
  after=$(state_hash "$U_WT") || after=""
  [ "$after" = "$hash" ] || { verify_failed "$id" "(verify modified the worktree)" 0 "$vlog" "verify modified the worktree"; return; }

  identity "$REPO"
  git -C "$U_WT" add -A -- . ':(exclude).scratch' >&2 || { refuse "$id" merged "cannot stage the reviewed state in $U_WT"; return; }
  git -C "$U_WT" -c user.email="$ID_EMAIL" -c user.name="$ID_NAME" commit -q -m "[coord] $U_GOAL" >&2 || {
    refuse "$id" merged "commit failed in $U_WT (nothing to commit?)"; return; }
  if ! git -c user.email="$ID_EMAIL" -c user.name="$ID_NAME" -C "$REPO" merge --no-ff --no-edit "$U_BRANCH" >/dev/null 2>&1; then
    git -C "$REPO" merge --abort >/dev/null 2>&1 || true
    git -C "$U_WT" reset -q --soft HEAD~1 || true
    one_event type=rejected unit="$id" by=engine \
      text="merge into $base conflicted; bring the change up to date with $base in a correction round" || return
    refuse "$id" merged "git merge of $U_BRANCH into $base conflicted (unit returned to handback)"; return
  fi
  sha=$(git -C "$REPO" rev-parse HEAD)
  one_event type=merged unit="$id" sha="$sha" || return
  echo "MERGED $id sha=$sha"
  if git -C "$REPO" remote | grep -qx origin; then
    git -C "$REPO" push origin "$base" >/dev/null 2>&1 && echo "PUSHED origin/$base"
  fi
  return 0
}

# ---------------------------------------------------------------- relay

# The scheduler: the only thing that turns events into coordinator turns.
#   relay [--once] [--interval N] [--max-attempts N] [--backoff N]
# One relay per run. Each tick: report launches that died (exited) or ran
# past their timebox (SIGTERM, SIGKILL after timebox.grace, then died
# timeout; a second death in a round blocks the unit); then write every
# undelivered wake event into one batch file, claim it, resume the
# coordinator with "WAKE batch=<path>", and ack when its turn exits.
cmd_relay() {
  parse_args relay "interval max-attempts backoff" "" "once" "$@"
  local interval=${F[interval]:-${RELAY_INTERVAL:-1}} attempts=${F[max-attempts]:-${RELAY_MAX_ATTEMPTS:-5}}
  local backoff=${F[backoff]:-${RELAY_BACKOFF:-2}} once=${F[once]:-0} pidfile
  [[ $interval =~ ^[0-9]+(\.[0-9]+)?$ && $attempts =~ ^[0-9]+$ && $backoff =~ ^[0-9]+$ ]] || {
    fail 2 'relay: --interval, --max-attempts and --backoff must be numbers'; return; }
  GRACE=$(dur "$(cfg_val "$CONFIG" timebox.grace)" 2>/dev/null) || GRACE=30
  mkdir -p "$RUN/batch"
  exec {RELAY_LOCK}>"$RUN/relay.lock"
  flock -n "$RELAY_LOCK" || { fail 1 'relay: another relay already holds %s; refusing to run two' "$RUN/relay.lock"; return; }
  pidfile="$RUN/relay.pid"
  echo "$$" > "$pidfile"
  trap 'rm -f "'"$pidfile"'"' EXIT
  trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP

  # a batch claimed by a relay that crashed is ours to redeliver
  nack_stranded() { local s; s=$(model inflight); [ -z "$s" ] || ev type=nacked seqs="$s"; }
  commit nack_stranded || true

  declare -gA TERMED=()
  while :; do
    reap
    BATCH="" SEQS=""
    commit claim || { fail 1 'relay: cannot claim a batch'; return; }
    if [ -z "$BATCH" ]; then sleep "$interval"; continue; fi
    deliver "$attempts" "$backoff" || return 1
    [ "$once" = 1 ] && return 0
  done
}

older() { awk -v a="$1" -v b="$2" -v c="$3" 'BEGIN { exit !(a - b > c) }'; }

# reap: report launches that died or ran past their timebox
reap() {
  local now line
  now=$(date +%s.%N)
  while IFS=$US read -r id state kind round role owes pid wt br base wb logf disp tb deaths _; do
    [ -n "$owes" ] && reap_one "$id" "$owes" "$pid" "$disp" "$tb" "$now"
  done < <(model units)
  while IFS=$US read -r slug pid rep logf disp tb; do
    [ -n "$slug" ] && reap_one "" "$slug" "$pid" "$disp" "$tb" "$now"
  done < <(model research)
  return 0
}

reap_one() { # <unit> <slug> <pid> <dispatched> <timebox> <now>
  local unit=$1 slug=$2 pid=$3 disp=$4 tb=$5 now=$6 reason=""
  if [ -n "${TERMED[$slug]:-}" ]; then
    if alive "$pid" && ! older "$now" "${TERMED[$slug]}" "$GRACE"; then return 0; fi
    kill_group "$pid" KILL; reason=timeout
  elif ! alive "$pid"; then
    reason=exited
  elif [ "${tb:-0}" -gt 0 ] && older "$now" "$disp" "$tb"; then
    kill_group "$pid" TERM; TERMED[$slug]=$now; return 0
  fi
  [ -n "$reason" ] || return 0
  unset "TERMED[$slug]"
  died_events() {
    ev type=died unit="$unit" slug="$slug" pid="$pid" reason="$reason"
    if [ -n "$unit" ] && unit_row "$unit" && [ "$U_OWES" = "$slug" ] && [ "$U_PID" = "$pid" ] && [ $((U_DEATHS + 1)) -ge 2 ]; then
      ev type=blocked unit="$unit" by=engine reason="died 2 times in round $U_ROUND"
    fi
  }
  commit died_events || true
}

# claim: write every undelivered wake event into a new batch file and claim
# it (BATCH, SEQS); nothing when there is nothing to deliver.
claim() {
  local wakes
  wakes=$(model undelivered)
  [ -n "$wakes" ] || return 0
  BATCH="$RUN/batch/$(date +%s%N).txt"
  {
    while IFS= read -r l; do printf 'EVENT %s\n' "$l"; done <<< "$wakes"
    if [ -s "$RUN/standing.md" ]; then printf '\nSTANDING ORDERS (apply to everything you do):\n'; cat "$RUN/standing.md"; fi
  } > "$BATCH"
  # the batch is written before the claim: a crash in between leaves the
  # events undelivered, so they are delivered again, never lost
  SEQS=$(awk '{ print $1 }' <<< "$wakes" | paste -sd, -)
  ev type=claimed batch="$BATCH" seqs="$SEQS"
}

# deliver <attempts> <backoff>: resume on the batch with backoff; ack on
# success, nack and stop when the attempts run out.
deliver() {
  local max=$1 wait=$2 attempt
  for (( attempt = 1; ; attempt++ )); do
    if resume "WAKE batch=$BATCH"; then
      one_event type=acked seqs="$SEQS" batch="$BATCH" || true
      return 0
    fi
    if [ "$attempt" -ge "$max" ]; then
      one_event type=nacked seqs="$SEQS" batch="$BATCH" || true
      fail 1 'relay: resume failed %d times for %s; returned the events and stopped (fix the resume recipe, then restart the relay)' "$max" "$BATCH"
      return 1
    fi
    printf 'relay: resume failed (attempt %d/%d), retrying in %ds\n' "$attempt" "$max" "$wait" >&2
    sleep "$wait"
    wait=$(( wait * 2 )); [ "$wait" -le 60 ] || wait=60
  done
}

# resume <pointer>: run the resume recipe (config data, never evaluated) with
# __BATCH__ and __SESSION__ substituted, and wait for the turn to exit.
resume() {
  local recipe session cur i
  recipe=${COORD_RESUME:-$(cfg_val "$CONFIG" relay.resume)}
  if [ -z "$recipe" ]; then
    cur=$(cfg_val "$ENV_CONF" current)
    [ -n "$cur" ] && recipe=$(cfg_val "$ENV_CONF" "harness.$cur.resume")
  fi
  [ -n "$recipe" ] || { echo 'relay: no relay.resume recipe (set COORD_RESUME, config, or env.conf)' >&2; return 1; }
  session=${COORD_SESSION:-$(cfg_val "$CONFIG" relay.session)}
  [ -n "$session" ] || session=$(cat "$RUN/session" 2>/dev/null || true)
  local -a argv
  IFS='|' read -r -a argv <<< "$recipe"
  for i in "${!argv[@]}"; do
    argv[i]=${argv[i]//__BATCH__/$1}
    argv[i]=${argv[i]//__SESSION__/$session}
  done
  (
    # the coordinator's turn must not hold the relay's lock if the relay dies
    [ -z "${RELAY_LOCK:-}" ] || exec {RELAY_LOCK}>&-
    cd "$REPO" && "${argv[@]}"
  )
}

# ---------------------------------------------------------------- views

# status: STATUS / UNIT / LOG / RESEARCH lines (see SKILL.md)
cmd_status() {
  local rpid ra=0 und inflight n=0
  rpid=$(cat "$RUN/relay.pid" 2>/dev/null || true)
  alive "$rpid" && ra=1
  und=$(model undelivered | grep -c . || true)
  inflight=$(model inflight)
  [ -n "$inflight" ] && n=$(tr ',' '\n' <<< "$inflight" | grep -c .)
  echo "STATUS relay=${rpid:--} alive=$ra undelivered=$und inflight=$n"
  local id state kind round role owes pid wt br base wb logf disp tb deaths pass lvl sha ready deps risk goal p a last
  while IFS=$US read -r id state kind round role owes pid wt br base wb logf disp tb deaths pass lvl sha ready deps risk goal; do
    p=- a=0
    if [ -n "$owes" ]; then p=$pid; alive "$pid" && a=1; fi
    echo "UNIT $id $state kind=$kind round=$round ready=$ready pid=$p alive=$a goal=$goal"
    if [ "$a" = 1 ] && [ -f "$logf" ]; then
      last=$(tail -n1 "$logf" | tr -d '\r' | cut -b1-200)
      [ -z "$last" ] || echo "LOG $id $owes $last"
    fi
  done < <(model units)
  while IFS=$US read -r slug pid rep logf disp tb; do
    [ -n "$slug" ] || continue
    a=0; alive "$pid" && a=1
    echo "RESEARCH $slug pid=$pid alive=$a report=$rep"
  done < <(model research)
}

# render: COORDINATION.md at the repo root -> RENDERED <path>
cmd_render() {
  local dash=${COORD_DASHBOARD:-$REPO/COORDINATION.md}
  mkdir -p "$(dirname "$dash")"
  {
    printf '# COORDINATION\n\n'
    printf '| id | kind | state | round | evidence | reviewed state | merge | goal |\n'
    printf '|---|---|---|---|---|---|---|---|\n'
    model units | awk -F"$US" '{ printf "| %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $3, $2, $4, $17, substr($16, 1, 12), $18, $22 }'
  } > "$dash"
  echo "RENDERED $dash"
}

# log [<id>]: "<seq> <type> <unit|-> <what>" per event
cmd_log() { model log -v unit="${1:-}"; }

# done: DONE units=<n> (exit 0) | OPEN <ids> (exit 1)
cmd_done() {
  local open n
  open=$(model units | awk -F"$US" '$2 != "merged" && $2 != "dropped" { print $1 }' | paste -sd' ' -)
  if [ -n "$open" ]; then echo "OPEN $open"; return 1; fi
  n=$(model units | grep -c . || true)
  echo "DONE units=$n"
}

# ---------------------------------------------------------------- start

RUN_IGNORE='# run state of the coordinator: only the committed choices are kept
*
!.gitignore
!config.conf
!standing.md
!playbooks/
!playbooks/*.md'

# newest <dir> <name pattern>: most recently modified matching file
newest() { find "$1" -type f -name "$2" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-; }

#   start [--harness H] [--session ID] [--no-relay]
#     -> SESSION <id> source=<...> harness=<h> repo=<repo>  [RELAY pid=<pid>]
# Records the harness's REAL session id (never an invented one), sets up
# .coordinator/, and starts the relay.
cmd_start() {
  parse_args start "harness session" "" "no-relay" "$@"
  local harness=${F[harness]:-} sid=${F[session]:-} src="" f base rec pid cs
  [ -n "$harness" ] || harness=$(cfg_val "$ENV_CONF" current)
  [ -n "$harness" ] || { fail 1 'start: no current harness (run coord detect first)'; return; }
  if [ -n "$sid" ]; then src=user
  elif [ -n "${COORD_SESSION:-}" ]; then sid=$COORD_SESSION src=env
  else
    case "$harness" in
      pi) [ -n "${PI_SESSION_ID:-}" ] && sid=$PI_SESSION_ID src=pi-env ;;
      codex)
        f=$(newest "${CODEX_HOME:-$HOME/.codex}/sessions" 'rollout-*.jsonl')
        if [ -n "$f" ]; then
          base=$(basename "$f" .jsonl)
          sid=$(awk -F- -v OFS=- 'NF >= 5 { print $(NF-4), $(NF-3), $(NF-2), $(NF-1), $NF; next } { print }' <<< "$base") src=codex-sessions
        fi ;;
      claude)
        f=$(newest "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" '*.jsonl')
        [ -n "$f" ] && sid=$(basename "$f" .jsonl) src=claude-projects ;;
    esac
  fi
  if [ -z "$sid" ]; then
    {
      echo "start: no resumable session id for harness '$harness' — no invented ids."
      echo '  pi:       relies on $PI_SESSION_ID'
      echo '  codex:    scans ${CODEX_HOME:-~/.codex}/sessions for the live rollout'
      echo '  claude:   scans ${CLAUDE_CONFIG_DIR:-~/.claude}/projects for the live jsonl'
      echo '  opencode: no machine-readable id yet; pass --session from the TUI'
      echo "  fallback: pass --session <the harness's real session id>"
    } >&2
    return 1
  fi
  mkdir -p "$RUN"
  echo "$sid" > "$RUN/session"
  [ -f "$LOG" ] || : > "$LOG"
  echo "SESSION $sid source=$src harness=$harness repo=$REPO"

  # repo hygiene: run state is never committed; the first commit the
  # coordinator authors in the run
  if [ ! -f "$RUN/.gitignore" ]; then
    printf '%s\n' "$RUN_IGNORE" > "$RUN/.gitignore"
    hygiene_commit "$REPO" "${RUN#"$REPO"/}/.gitignore" "[coord] ignore run state in .coordinator/"
  fi
  # claude grants permissions per process and per directory: a project
  # settings file with bypassPermissions gives every claude in the repo the
  # worker policy (full permissions), uniformly
  cs="$REPO/.claude/settings.local.json"
  if [ -f "$cs" ]; then
    grep -q bypassPermissions "$cs" || echo "start: claude settings exist without bypassPermissions: $cs (merge policy requires full worker perms)" >&2
  elif [ ! -e "$cs" ]; then
    mkdir -p "$(dirname "$cs")"
    printf '{\n  "permissions": {\n    "defaultMode": "bypassPermissions"\n  }\n}\n' > "$cs"
    hygiene_commit "$REPO" .claude/settings.local.json "[coord] claude full permissions"
  fi

  [ "${F[no-relay]:-0}" = 1 ] && return 0
  # pin the resume recipe so the relay never depends on env.conf current
  [ -f "$CONFIG" ] || : > "$CONFIG"
  rec=$(cfg_val "$ENV_CONF" "harness.$harness.resume")
  [ -z "$rec" ] || "$SKILL/libexec/cfg.sh" set "$CONFIG" relay.resume "$rec"
  mkdir -p "$RUN/log"
  pid=$(
    (
      cd "$REPO" || exit 1
      export COORD_EVENTS="$LOG" COORD_CONFIG="$CONFIG" COORD_SESSION="$sid"
      exec setsid "$SELF" relay
    ) >> "$RUN/log/relay.log" 2>&1 < /dev/null &
    echo $!
  )
  echo "$pid" > "$RUN/relay.pid"
  echo "RELAY pid=$pid"
}
