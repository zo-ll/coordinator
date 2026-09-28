# core.sh: shared by every filo command (sourced by bin/filo).
#
# A run lives in <repo>/.filo/: the event log (events.log), config,
# standing orders, playbook overrides, and (gitignored) briefs, logs, batches,
# worktrees and the relay's lock. The log is the only state; lib/model.awk is
# its only parser and holds the transition table.

US=$'\037'
MODEL="$SKILL/lib/model.awk"

fail() { # fail <code> <printf args...>: one line to stderr
  local code=$1; shift
  printf "$@" >&2; printf '\n' >&2
  return "$code"
}

# refuse <unit> <type> <reason...>: the engine's refusal line
refuse() {
  local u=${1:--} t=$2; shift 2
  printf 'REFUSED %s %s: %s\n' "$u" "$t" "$*" >&2
  return 1
}

# events_path: $FILO_EVENTS, else the nearest .filo/events.log at or
# above the working directory (a worktree under <repo>/.filo/worktrees
# finds its repo's log), else ./.filo/events.log.
existing_events_path() {
  if [ -n "${FILO_EVENTS:-}" ]; then
    case "$FILO_EVENTS" in /*) printf '%s' "$FILO_EVENTS" ;; *) printf '%s' "$PWD/$FILO_EVENTS" ;; esac
    return 0
  fi
  local d=$PWD
  while :; do
    [ -f "$d/.filo/events.log" ] && { printf '%s' "$d/.filo/events.log"; return 0; }
    [ "$d" = / ] && return 1
    d=$(dirname "$d")
  done
}
events_path() { existing_events_path || printf '%s' "$PWD/.filo/events.log"; }

LOG=$(events_path)
RUN=$(dirname "$LOG")
REPO=$(dirname "$RUN")
CONFIG=${FILO_CONFIG:-$RUN/config.conf}
FILO_HOME=${FILO_HOME:-$HOME/.filo}
ENV_CONF=${FILO_ENV_CONF:-$FILO_HOME/env.conf}

# cfg_get <file> <key>: value of the last assignment; 1 when absent
cfg_get() {
  [ -f "$1" ] || return 1
  awk -v k="$2" 'index($0, k"=") == 1 { v = substr($0, length(k) + 2); f = 1 } END { if (f) print v; else exit 1 }' "$1"
}
cfg_val() { cfg_get "$1" "$2" 2>/dev/null || true; }

# ev <key=value>...: one event line (without seq/ts); tabs and newlines in
# values become spaces so a value can never break the line format.
ev() {
  local out="" kv
  for kv in "$@"; do
    kv=${kv//$'\t'/ }; kv=${kv//$'\n'/ }; kv=${kv//$'\r'/ }
    out+="${out:+$'\t'}$kv"
  done
  printf '%s\n' "$out" >> "$CAND"
}

# model <mode> [awk -v assignments...]: query the folded run
model() {
  local mode=$1; shift
  [ -f "$LOG" ] || { [ "$mode" = lastseq ] && echo 0; return 0; }
  awk -v mode="$mode" "$@" -f "$MODEL" "$LOG"
}

# repair: under the lock, cut a torn final line so the next record starts clean
repair() {
  [ -s "$LOG" ] || return 0
  [ -z "$(tail -c1 "$LOG")" ] && return 0
  local size torn
  size=$(stat -c %s "$LOG")
  torn=$(tail -n1 "$LOG" | wc -c)
  truncate -s $(( size - torn )) "$LOG"
}

# commit <builder> [args...]: run the builder under the log's lock (it may
# query the model and writes events with `ev`), check every event it wrote
# against the state machine, and append them atomically. Returns 0 on append
# (or nothing to append), 3 on DUP, 1 on refusal (REFUSED line on stderr).
commit() {
  mkdir -p "$RUN"
  local lock rc=0 seq ts line tmp res
  exec {lock}>>"$LOG.lock"
  flock "$lock"
  COMMIT_LOCK=$lock   # launch closes it so no agent inherits the lock
  touch "$LOG"
  repair
  CAND=$(mktemp "$RUN/.cand.XXXXXX")
  "$@" || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$CAND" ]; then
    rm -f "$CAND"; exec {lock}>&-; COMMIT_LOCK=""; return "$rc"
  fi
  seq=$(model lastseq)
  ts=$(date +%s.%N)
  tmp=$(mktemp "$RUN/.stamped.XXXXXX")
  while IFS= read -r line; do
    seq=$((seq + 1))
    printf 'seq=%s\tts=%s\t%s\t.\n' "$seq" "$ts" "$line" >> "$tmp"
  done < "$CAND"
  res=$(awk -v mode=check -v cand="$tmp" -f "$MODEL" "$LOG" "$tmp") || rc=$?
  if [ "$res" = OK ]; then
    cat "$tmp" >> "$LOG"
    COMMITTED_SEQ=$seq
  elif [ "$res" = DUP ]; then
    rc=3
  else
    IFS=$'\t' read -r _ u t why <<< "$res"
    printf 'REFUSED %s %s: %s\n' "$u" "$t" "$why" >&2
    rc=1
  fi
  rm -f "$CAND" "$tmp"
  exec {lock}>&-
  COMMIT_LOCK=""
  return "$rc"
}

# one_event <key=value>...: commit exactly these fields
one_event() { commit ev "$@"; }

# unit_row <id>: sets U_* from the units projection; 1 if unknown
unit_row() {
  local line
  line=$(model units | awk -F"$US" -v id="$1" '$1 == id')
  [ -n "$line" ] || return 1
  IFS=$US read -r U_ID U_STATE U_KIND U_ROUND U_ROLE U_OWES U_PID U_WT U_BRANCH U_BASE \
    U_BRIEF U_LOG U_DISP U_TB U_DEATHS U_PASS U_LEVEL U_SHA U_READY U_DEPS U_RISK U_GOAL U_NOTES <<< "$line"
}

alive() { [[ ${1:-} =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ] && kill -0 "$1" 2>/dev/null; }

# kill_group <pid> <signal>: launches run under setsid; signal the group
kill_group() {
  alive "$1" || return 0
  kill -"$2" -- "-$1" 2>/dev/null || kill -"$2" "$1" 2>/dev/null || true
}

# dur <text>: seconds for 45m, 1h30m, 20s; fails otherwise or on zero
dur() {
  local s=$1 total=0
  [[ $s =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s)?$ && -n $s ]] || return 1
  [ -n "${BASH_REMATCH[1]}" ] && total=$(( total + ${BASH_REMATCH[1]%h} * 3600 ))
  [ -n "${BASH_REMATCH[2]}" ] && total=$(( total + ${BASH_REMATCH[2]%m} * 60 ))
  [ -n "${BASH_REMATCH[3]}" ] && total=$(( total + ${BASH_REMATCH[3]%s} ))
  [ "$total" -gt 0 ] || return 1
  printf '%s' "$total"
}

LEVELS="none typecheck tests live"
rank() { # rank <level>: 0..3, or -1 if unknown
  local i=0 l
  for l in $LEVELS; do [ "$l" = "$1" ] && { echo "$i"; return; }; i=$((i + 1)); done
  echo -1
}

# identity <repo>: the user's git identity, with the coordinator's fallback
identity() {
  ID_EMAIL=$(git -C "$1" config user.email 2>/dev/null) || ID_EMAIL=""
  ID_NAME=$(git -C "$1" config user.name 2>/dev/null) || ID_NAME=""
  [ -n "$ID_EMAIL" ] || ID_EMAIL=filo@local
  [ -n "$ID_NAME" ] || ID_NAME=filo
}

# state_hash <worktree>: SHA-256 of the whole working tree (tracked changes
# and untracked, non-ignored files, outside .scratch/) against HEAD, through a
# throwaway index so it never depends on, or touches, what was staged.
state_hash() {
  local d rc=0 sum
  d=$(mktemp -d) || return 1
  export GIT_INDEX_FILE="$d/index"
  { git -C "$1" read-tree HEAD && git -C "$1" add -A -- . ':(exclude).scratch'; } >/dev/null 2>&1 || rc=1
  if [ "$rc" = 0 ]; then
    sum=$(git -C "$1" diff --cached --binary HEAD | sha256sum) || rc=1
  fi
  unset GIT_INDEX_FILE
  rm -rf "$d"
  [ "$rc" = 0 ] || return 1
  printf '%s' "${sum%% *}"
}

# build_argv <harness> <role> <prompt-file> <cwd> <model>: fills ARGV from the
# harness's env.conf exec recipe ('|'-separated; __CWD__, __PROMPT__ (role
# preamble + prompt), __MODEL__ (dropped with its flag when empty)).
build_argv() {
  local h=$1 role=$2 prompt=$3 cwd=$4 mdl=$5 recipe text t agents
  ARGV=()
  [ -r "$prompt" ] || { fail 1 'invoke: prompt file not readable: %s' "$prompt"; return 1; }
  recipe=$(cfg_get "$ENV_CONF" "harness.$h.exec") || {
    fail 1 "invoke: no exec recipe for harness '%s' in %s" "$h" "$ENV_CONF"; return 1; }
  text=$(cat "$prompt")
  agents=${FILO_AGENTS:-$SKILL/agents}
  [ -f "$agents/$role.md" ] && text="$(cat "$agents/$role.md")"$'\n\n'"$text"
  local IFS='|'
  read -r -a toks <<< "$recipe"
  for t in "${toks[@]}"; do
    case "$t" in
      __CWD__) ARGV+=("$cwd") ;;
      __PROMPT__) ARGV+=("$text") ;;
      __MODEL__)
        if [ -n "$mdl" ]; then ARGV+=("$mdl")
        elif [ "${#ARGV[@]}" -gt 0 ]; then unset 'ARGV[${#ARGV[@]}-1]'; fi ;;
      *) ARGV+=("$t") ;;
    esac
  done
  [ "${#ARGV[@]}" -gt 0 ]
}

# launch <role> <cwd> <logfile> <slug> <argv...>: run a role detached in its
# own session under setsid, output appended to the log. Prints the pid.
launch() {
  local role=$1 cwd=$2 logf=$3 slug=$4; shift 4
  mkdir -p "$(dirname "$logf")"
  command -v "$1" >/dev/null 2>&1 || { fail 1 'cannot launch %s: not found' "$1"; return 1; }
  (
    # never hand a held lock to a long-lived agent
    [ -z "${COMMIT_LOCK:-}" ] || exec {COMMIT_LOCK}>&-
    [ -z "${RELAY_LOCK:-}" ] || exec {RELAY_LOCK}>&-
    export FILO_EVENTS="$LOG" FILO_OWES="$slug"
    cd "$cwd" || exit 1
    setsid "$@" >>"$logf" 2>&1 </dev/null &
    echo $!
  )
}

# playbook <kind>: loads PB_* from the repo override, else the shipped one
playbook() {
  local kind=$1 f="" d out
  [[ $kind =~ ^[a-z][a-z0-9_-]*$ ]] || { PB_ERR="invalid kind \"$kind\""; return 1; }
  for d in "$RUN/playbooks" "$SKILL/playbooks"; do
    [ -f "$d/$kind.md" ] && { f="$d/$kind.md"; break; }
  done
  [ -n "$f" ] || { PB_ERR="no playbook for kind \"$kind\""; return 1; }
  out=$(awk -v want="$kind" '
    function bad(m) { err = m; exit }
    NR == 1 { if ($0 != "---") bad("missing --- header"); next }
    !done && $0 == "---" { done = 1; next }
    !done {
      t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t)
      if (t == "" || t ~ /^#/) next
      p = index(t, "="); if (!p) bad("header line \"" t "\" is not key=value")
      k = substr(t, 1, p - 1); v = substr(t, p + 1); h[k] = v
      if (k != "kind" && k != "brief.require" && k != "evidence.floor" && k != "evidence.require" && k != "timebox" && k != "lane")
        bad("unknown header key \"" k "\"")
      next
    }
    END {
      if (err != "") { print "ERR " err; exit }
      if (!done) { print "ERR unterminated --- header"; exit }
      if (h["kind"] == "") { print "ERR kind is required"; exit }
      if (h["kind"] != want) { print "ERR kind=\"" h["kind"] "\", want \"" want "\""; exit }
      gsub(/,/, " ", h["brief.require"]); gsub(/,/, " ", h["evidence.require"])
      print "OK\037" h["brief.require"] "\037" (("evidence.floor" in h) ? h["evidence.floor"] : "none") "\037" h["evidence.require"] "\037" (("timebox" in h) ? h["timebox"] : "30m") "\037" (("lane" in h) ? h["lane"] : "default")
    }' "$f") || true
  case "$out" in
    OK*) ;;
    ERR*) PB_ERR="$f: ${out#ERR }"; return 1 ;;
    *) PB_ERR="$f: unterminated --- header"; return 1 ;;
  esac
  IFS=$US read -r _ PB_REQUIRE PB_FLOOR PB_NEED PB_TIMEBOX_TXT PB_LANE <<< "$out"
  local -a words
  read -r -a words <<< "$PB_REQUIRE"; PB_REQUIRE="${words[*]}"
  read -r -a words <<< "$PB_NEED"; PB_NEED="${words[*]}"
  [ "$(rank "$PB_FLOOR")" -ge 0 ] || { PB_ERR="$f: evidence.floor \"$PB_FLOOR\" is not one of ${LEVELS// /,}"; return 1; }
  PB_TIMEBOX=$(dur "$PB_TIMEBOX_TXT") || { PB_ERR="$f: timebox \"$PB_TIMEBOX_TXT\" is not a duration"; return 1; }
  PB_KIND=$kind PB_PATH=$f
}

# pb_section <role>: the playbook's "## <role>" text
pb_section() {
  awk -v want="$1" '
    NR == 1 && $0 == "---" { inh = 1; next }
    inh { if ($0 == "---") inh = 0; next }
    /^## / { s = $0; sub(/^## /, "", s); gsub(/[ \t]+$/, "", s); on = (tolower(s) == want); next }
    on { buf = buf $0 "\n" }
    END { gsub(/^[ \t\n]+|[ \t\n]+$/, "", buf); printf "%s", buf }' "$PB_PATH"
}

# brief <file> <mode> [field]: fields (names present), get FIELD (trimmed
# text), verify ("$ " commands in VERIFY). Fields start a line as FIELD:.
brief() {
  awk -v mode="$2" -v want="${3:-}" '
    function flush() { if (cur != "" || buf ~ /[^ \t\n]/) { t = buf; gsub(/^[ \t\n]+|[ \t\n]+$/, "", t); if (!(cur in has)) { order[++n] = cur; body[cur] = t } else body[cur] = body[cur] "\n" t; has[cur] = 1 } }
    { sub(/\r$/, "") }
    match($0, /^[A-Z][A-Z_]*:/) { flush(); cur = substr($0, 1, RLENGTH - 1); buf = substr($0, RLENGTH + 1); next }
    { buf = buf "\n" $0 }
    END {
      flush()
      if (mode == "fields") { for (i = 1; i <= n; i++) if (order[i] != "") print order[i] }
      else if (mode == "get") { if (want in has) printf "%s", body[want]; else exit 1 }
      else if (mode == "verify") {
        m = split(body["VERIFY"], L, "\n")
        for (i = 1; i <= m; i++) { l = L[i]; gsub(/^[ \t]+|[ \t]+$/, "", l); if (substr(l, 1, 2) == "$ ") { c = substr(l, 3); gsub(/^[ \t]+|[ \t]+$/, "", c); if (c != "") print c } }
      }
    }' "$1"
}
