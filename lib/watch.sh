# watch.sh: filo watch, the one command the user runs (sourced by bin/filo).
# It reads the run's state, draws it on the terminal, redraws only the lines
# that changed, and turns a few keys into filo commands.
#
# Frames are built in a small markup: \001 style \002 text \003, where style is
# d dim, b bold, y yellow, yb bold yellow, r red, rb bold red, g green, gb bold green,
# c cyan, k key (bold cyan), I inverse, u a unit you can click (dim). fit() cuts a line to the width and
# ansi() turns it into escapes (or plain text under NO_COLOR / no terminal).

shopt -s extglob

W_SO=$'\001' W_SM=$'\002' W_SE=$'\003'
m() { printf '%s' "$W_SO$1$W_SM$2$W_SE"; }
# clean <text>: one line of untrusted text, no markup or control characters
clean() { local s=${1//[$'\001'-$'\037']/ }; printf '%s' "${s//$'\177'/}"; }

vis() { local s=${1//$W_SO+([a-zA-Z])$W_SM/}; s=${s//$W_SE/}; printf '%s' "${#s}"; }

# seg: the next segment off $s (the caller's): its style in k ("" for plain
# text), its text in t
seg() {
  if [[ $s == "$W_SO"* ]]; then
    k=${s:1}; k=${k%%"$W_SM"*}; s=${s#*"$W_SM"}; t=${s%%"$W_SE"*}; s=${s#*"$W_SE"}
  else
    k=""; t=${s%%"$W_SO"*}; s=${s:${#t}}
  fi
}

# fit <markup> <width>: exactly <width> visible columns, … where cut
fit() {
  local s=$1 w=$2 out="" n=0 k t room
  while [ -n "$s" ] && [ "$n" -lt "$w" ]; do
    seg
    room=$((w - n))
    if [ "${#t}" -gt "$room" ]; then t="${t:0:room-1}…"; s=""; fi
    if [ -n "$k" ]; then out+="$W_SO$k$W_SM$t$W_SE"; else out+=$t; fi
    n=$((n + ${#t}))
  done
  if [ "$n" -lt "$w" ]; then printf -v t '%*s' $((w - n)) ''; out+=$t; fi
  printf '%s' "$out"
}

ansi() {
  local s=$1 k c
  if [ "$W_COLOR" != 1 ]; then s=${s//$W_SO+([a-zA-Z])$W_SM/}; printf '%s' "${s//$W_SE/}"; return; fi
  for k in yb rb gb d b y r g c k I u; do
    case $k in d|u) c=2 ;; b) c=1 ;; y) c=33 ;; yb) c='1;33' ;; r) c=31 ;; rb) c='1;31' ;;
               g) c=32 ;; gb) c='1;32' ;; c) c=36 ;; k) c='1;36' ;; I) c=7 ;; esac
    s=${s//"$W_SO$k$W_SM"/$'\e['"${c}m"}
  done
  printf '%s' "${s//$W_SE/$'\e[0m'}"
}

# hits <markup> <style>: "from to text" for each <style> segment, in 1-based
# columns; a segment's span runs up to the next one, so it takes its label
hits() {
  local s=$1 n=0 k t from=() txt=() i
  while [ -n "$s" ]; do
    seg
    [ "$k" != "$2" ] || { from+=($((n + 1))); txt+=("$t"); }
    n=$((n + ${#t}))
  done
  for i in "${!from[@]}"; do
    printf '%s %s %s\n' "${from[i]}" "$(( ${from[i + 1]:-$((n + 1))} - 1 ))" "${txt[i]}"
  done
}
# at <x> <"from to value">...: the value whose span holds column x
at() {
  local x=$1 f t v; shift
  for v in "$@"; do read -r f t v <<< "$v"; [ "$x" -lt "$f" ] || [ "$x" -gt "$t" ] || { printf '%s' "$v"; return 0; }; done
  return 1
}

lr() { local l=$1 r=$2 w=$3 gap; gap=$((w - $(vis "$l") - $(vis "$r"))); [ "$gap" -ge 1 ] || gap=1; printf '%s%*s%s' "$l" "$gap" '' "$r"; }
rule() {
  local l r fill
  l="$(m d '─ ')$(m b "$1")$(m d ' ')"; r=${2:+" $2 $(m d ─)"}
  fill=$(( $3 - $(vis "$l") - $(vis "$r") )); [ "$fill" -ge 0 ] || fill=0
  printf '%s%s%s' "$l" "$(m d "$(rep ─ "$fill")")" "$r"
}
rep() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }
hm() { printf '%(%H:%M)T' "$1"; }
span() { local s=$1; if [ "$s" -lt 60 ]; then printf '%ss' "$s"; elif [ "$s" -lt 3600 ]; then printf '%sm' $((s / 60)); else printf '%sh %02dm' $((s / 3600)) $((s % 3600 / 60)); fi; }

# wrap <text> <width> <max lines>: word-wrapped lines on stdout
wrap() { fold -s -w "$2" <<< "$1" | sed 's/ *$//' | head -n "$3"; }

# ---------------------------------------------------------------- state

watch_gather() {
  NOW=$(printf '%(%s)T' -1)
  UNITS=(); FEED=(); ITEMS=(); NEED=(); NEED_IX=()
  declare -gA REASON=() CRITIC=() STATE=() REPORT=()
  RUN_START="" WOKE_TS="" WOKE_FOR="" ACKED=""
  [ -f "$LOG" ] || return 1
  local typ a b c d line id
  while IFS=$'\t' read -r typ a b c d; do
    case $typ in
      S) RUN_START=$a ;;
      F) FEED+=("$a"$'\t'"$b") ;;
      R) REASON[$a]=$b ;;
      C) CRITIC[$a]="$b"$'\t'"$c"$'\t'"$d" ;;
      W) WOKE_TS=$a WOKE_FOR=$b ;;
      A) ACKED=$a ;;
      P) REPORT[$a]="$b"$'\t'"$c"$'\t'"$d" ;;
    esac
  done < <(unc1 "$LOG" | awk -f "$EVENTS" -f "$SKILL/lib/watch.awk")
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    UNITS+=("$line"); id=${line%%"$US"*}
    STATE[$id]=$(cut -d"$US" -f2 <<< "$line")
  done < <(model units)
  RELAY_PID=$(cat "$RUN/relay.pid" 2>/dev/null || true)
  RELAY_UP=0; alive "$RELAY_PID" && RELAY_UP=1
  UNDELIVERED=$(model undelivered | grep -c . || true)
  INFLIGHT=$(model inflight)
  RESEARCH_LIVE=$(model research)
  AUTO=0; [ "$(cfg_val "$CONFIG" autonomy)" = auto-merge ] && AUTO=1
  OPEN=0
  for line in "${UNITS[@]}"; do case $(cut -d"$US" -f2 <<< "$line") in merged|dropped) ;; *) OPEN=$((OPEN + 1)) ;; esac; done
  # the wake process is only missed while something is left to deliver or do
  STUCK=0
  [ "$RELAY_UP" = 1 ] || { [ "$OPEN" -eq 0 ] && [ "$UNDELIVERED" -eq 0 ] && [ "${#UNITS[@]}" -gt 0 ]; } || STUCK=1
}

# watch_items: the WORK list, in a stable order: units in progress (creation
# order), open decisions, unread research reports, live researchers. ITEMS
# holds "kind<TAB>id"; NEED lists what waits on the user, NEED_IX the item
# each entry selects.
need() { NEED+=("$1"); NEED_IX+=($(( ${#ITEMS[@]} - 1 ))); }
watch_items() {
  local row id st g slug pid
  ITEMS=(); NEED=(); NEED_IX=()
  for row in "${UNITS[@]}"; do
    IFS=$US read -r id st _ <<< "$row"
    case $st in todo|merged|dropped) continue ;; esac
    ITEMS+=("unit"$'\t'"$id")
    needs_you "$row" && need "$(glyph "$st") $id"
  done
  if [ -f "$RUN/gates.tsv" ]; then
    while IFS=$'\t' read -r g st _; do [ "$st" = open ] && { ITEMS+=("gate"$'\t'"$g"); need "? $g"; }; done < "$RUN/gates.tsv"
  fi
  for slug in $(printf '%s\n' "${!REPORT[@]}" | sort -t. -k2 -n); do
    grep -qxF "$slug" "$RUN/watch.read" 2>/dev/null || { ITEMS+=("report"$'\t'"$slug"); need "≡ $slug"; }
  done
  while IFS=$US read -r slug pid _; do
    [ -n "$slug" ] && alive "$pid" && ITEMS+=("research"$'\t'"$slug")
  done <<< "$RESEARCH_LIVE"
  [ "${#ITEMS[@]}" -gt 0 ] || { SEL=0; return 0; }
  [ "$SEL" -lt "${#ITEMS[@]}" ] || SEL=$(( ${#ITEMS[@]} - 1 ))
}

# needs_you <row>: a unit that waits on the user
needs_you() {
  local st notes risk
  IFS=$US read -r _ st _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ risk _ notes <<< "$1"
  case $st in
    blocked) return 0 ;;
    passed) [ "$AUTO" != 1 ] || [ -n "$notes" ] || [ -n "$risk" ] ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------- frame

GLYPH_todo='○' GLYPH_working='◐' GLYPH_built='◒' GLYPH_reviewing='◑' GLYPH_passed='▲' GLYPH_approved='◆'
GLYPH_handback='↩' GLYPH_stalled='✗' GLYPH_blocked='■' GLYPH_merged='✓' GLYPH_dropped='–'
glyph() {
  local v="GLYPH_$1" g; g=${!v:-?}
  case $1 in passed) m y "$g" ;; stalled|blocked) m r "$g" ;; merged|dropped) m d "$g" ;; *) printf '%s' "$g" ;; esac
}
EVL_none='○○○' EVL_typecheck='●○○' EVL_tests='●●○' EVL_live='●●●'

# sentence <row>: what a unit is doing, in words
sentence() {
  local id st kind round deps d waits="" notes risk
  IFS=$US read -r id st kind round _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ deps risk _ notes <<< "$1"
  case $st in
    todo)
      local IFS=,
      for d in $deps; do case ${STATE[$d]:-} in merged|dropped) ;; *) waits+="${waits:+, }$d" ;; esac; done
      [ -n "$waits" ] && printf 'waiting on %s' "$waits" || printf 'ready to start' ;;
    working)   printf 'being built · round %s' "$round" ;;
    built)     printf 'built · waiting for review' ;;
    reviewing) printf 'being reviewed · round %s' "$round" ;;
    passed)
      if [ -n "$notes" ]; then m y 'passed with notes · needs you'
      elif [ -n "$risk" ] || [ "$AUTO" != 1 ]; then m y 'passed · needs your approval'
      else printf 'passed · merging'; fi ;;
    approved)  printf 'approved · merging' ;;
    handback)  printf 'sent back: %s' "$(clean "${REASON[$id]:-see its history}")" ;;
    stalled)   m r 'agent died · restarting' ;;
    blocked)   m r "blocked: $(clean "${REASON[$id]:-}")" ;;
    merged)    printf 'merged' ;;
    dropped)   printf 'dropped' ;;
  esac
}

item_keys() { # the keys for the selected item
  local kind=${1%%$'\t'*} id=${1#*$'\t'}
  case $kind in
    unit) case ${STATE[$id]} in
            passed)  printf '%s approve  %s reject  ' "$(m k a)" "$(m k r)" ;;
            blocked) printf '%s reopen  %s drop  ' "$(m k o)" "$(m k x)" ;;
          esac ;;
    gate)   printf '%s confirm  %s change  ' "$(m k c)" "$(m k d)" ;;
    report) printf '%s read  ' "$(m k v)" ;;
  esac
}

box() { # box <title> <right> <color> <width> lines... : a heavy box
  local title=$1 right=$2 k=$3 w=$4 l fill tail
  shift 4
  tail=${right:+" $right ━"}"┓"
  fill=$((w - 4 - ${#title} - ${#tail})); [ "$fill" -ge 0 ] || fill=0
  echo "$(m "$k" '┏━ ')$(m "${k}b" "$title")$(m "$k" " $(rep ━ "$fill")$tail")"
  for l in "$@"; do echo "$(m "$k" ┃) $(fit "$l" $((w - 4))) $(m "$k" ┃)"; done
  echo "$(m "$k" "┗$(rep ━ $((w - 2)))┛")"
}

# last_line <log>: the latest thing an agent printed, as one clean line
last_line() {
  [ -s "$1" ] || { printf 'no output yet'; return; }
  tail -c 4000 "$1" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tr -d '\r' | awk 'NF { l = $0 } END { gsub(/[ \t]+/, " ", l); sub(/^ /, "", l); print l }'
}

# agent_state <role> <round> <dispatched> <timebox> <log>: "worker r2 · 18/30m · output 4s ago"
agent_state() {
  local used lim age t live
  used=$(( (NOW - ${3%.*}) / 60 )); lim=$(( ${4:-1800} / 60 ))
  age=$(( NOW - $(stat -c %Y "$5" 2>/dev/null || echo "${3%.*}") ))
  t="$used/${lim}m"; [ $((used * 100)) -ge $((lim * 85)) ] && t=$(m y "$t")
  if [ "$age" -ge 120 ]; then live=$(m y "quiet $(span "$age")"); else live=$(m d "output $(span "$age") ago"); fi
  printf '%s %s · %s · %s' "$(m d "$1")" "$(m d "r$2")" "$t" "$live"
}

# wt_changes <worktree>: "3 files (1 new) +42 −8", from git
wt_changes() {
  local short new files=0 ins=0 del=0
  [ -d "$1" ] || return 0
  short=$(git -C "$1" diff --shortstat HEAD 2>/dev/null || true)
  new=$(git -C "$1" ls-files --others --exclude-standard 2>/dev/null | grep -c . || true)
  [[ $short =~ ([0-9]+)\ file ]] && files=${BASH_REMATCH[1]}
  [[ $short =~ ([0-9]+)\ insertion ]] && ins=${BASH_REMATCH[1]}
  [[ $short =~ ([0-9]+)\ deletion ]] && del=${BASH_REMATCH[1]}
  files=$((files + new))
  if [ "$files" -eq 0 ]; then printf 'no changes yet'; return; fi
  printf '%s file%s' "$files" "$([ "$files" = 1 ] || echo s)"
  [ "$new" -eq 0 ] || printf ' (%s new)' "$new"
  printf ' %s %s' "$(m g "+$ins")" "$(m r "−$del")"
  # the changed files' names, newest work first in the eye: basenames, comma-separated
  printf ' %s %s' "$(m d ·)" "$( { git -C "$1" diff --name-only HEAD 2>/dev/null; git -C "$1" ls-files --others --exclude-standard 2>/dev/null; } | awk -F/ 'NF { printf "%s%s", (n++ ? ", " : ""), $NF }')"
}

# item_lines <index> <width>: one WORK item's lines
item_lines() {
  local item=${ITEMS[$1]} w=$2 kind id mark=" " row st round role owes pid wt br logf disp tb notes l
  kind=${item%%$'\t'*} id=${item#*$'\t'}
  [ "$1" = "$SEL" ] && mark=$(m y ▸)
  case $kind in
    unit)
      for row in "${UNITS[@]}"; do [ "${row%%"$US"*}" = "$id" ] && break; done
      IFS=$US read -r _ st _ round role owes pid wt br _ _ logf disp tb _ _ _ _ _ _ _ _ notes <<< "$row"
      local head; head="$mark$(glyph "$st") $(m b "$id")  $(sentence "$row")"
      if [ -z "$owes" ]; then echo "$head"
      elif [ "$w" -ge 80 ]; then echo "$(lr "$head" "$(agent_state "$role" "$round" "$disp" "$tb" "$logf") " "$w")"
      else echo "$head"; echo "    $(agent_state "$role" "$round" "$disp" "$tb" "$logf")"; fi
      [ -z "$owes" ] || echo "    $(m d └) $(clean "$(last_line "$logf")")"
      [ -z "$wt" ] || echo "    $(m c "$br") $(m d ·) $(wt_changes "$wt") $(m d "· ${wt#"$REPO"/}")"
      if [ "$st" = passed ]; then
        if [ -n "$notes" ]; then
          while IFS= read -r l; do echo "    $(m y "$l")"; done < <(wrap "notes: $(clean "$notes")" $((w - 6)) 3)
        elif needs_you "$row"; then
          local cr cl cs; IFS=$'\t' read -r cr cl cs <<< "${CRITIC[$id]:-}"
          [ -z "$cs" ] || while IFS= read -r l; do echo "    $(m d "$l")"; done < <(wrap "critic: $(clean "$cs")" $((w - 6)) 2)
        fi
      fi ;;
    gate)
      local g q opts def
      IFS=$US read -r g st q opts def _ < <(awk -F'\t' -v OFS="$US" -v id="$id" '$1 == id { $1 = $1; print }' "$RUN/gates.tsv")
      echo "$mark$(m y ?) $(m b "decision $g")  $(clean "$q")"
      echo "    default: $(clean "$def") $(m d '· the coordinator went with it')" ;;
    report)
      local summary; IFS=$'\t' read -r _ _ summary <<< "${REPORT[$id]}"
      echo "$mark$(m y ≡) $(m b "$id")  report ready: $(clean "$summary")" ;;
    research)
      local slug rep lg
      while IFS=$US read -r slug pid rep lg disp tb; do [ "$slug" = "$id" ] && break; done <<< "$RESEARCH_LIVE"
      echo "$(lr "$mark≡ $(m b "$id")  researching" "$(agent_state researcher 1 "$disp" "$tb" "$lg") " "$w")"
      echo "    $(m d └) $(clean "$(last_line "$lg")")" ;;
  esac
}

queue_lines() { # up next and done, one line each; unit names are u (click opens)
  local row id st next="" done_=""
  for row in "${UNITS[@]}"; do
    IFS=$US read -r id st _ <<< "$row"
    case $st in
      todo) next+="$(m d '  ○ ')$(m u "$id")$( [ "$(sentence "$row")" = 'ready to start' ] || m d ", $(sentence "$row")")" ;;
      merged|dropped) done_+="  $(glyph "$st") $(m u "$id")" ;;
    esac
  done
  [ -z "$next" ] || echo "$(m d '   up next')$next"
  [ -z "$done_" ] || echo "$(m d "   done   ")$done_"
}

coordinator_line() {
  local s
  if [ "$STUCK" = 1 ]; then s=$(m r '✗ stuck: the wake process is down')
  elif [ "${#UNITS[@]}" -gt 0 ] && [ "$OPEN" -eq 0 ]; then s="○ idle $(m d '· run finished')"
  elif [ -n "$INFLIGHT" ]; then
    s="● working on a turn $(m d "· $(span $((NOW - ${WOKE_TS:-$NOW})))")"
    [ -z "$WOKE_FOR" ] || s+=" $(m d '· woke for:') $WOKE_FOR"
  elif [ "$UNDELIVERED" -gt 0 ]; then s="◌ wake queued $(m d "· $UNDELIVERED event(s)")"
  # a delivered wake may still be queued inside the harness (codex): say when, not "idle"
  elif [ -n "$ACKED" ]; then s="○ last woken $(hm "$ACKED") $(m d "· $(span $((NOW - ACKED))) ago")"
  else s="○ not woken yet"
  fi
  printf ' coordinator  %s' "$s"
}

# watch_frame <width> <height>: FRAME (body lines), KEYS, and the click map
# taken from the same lines: HIT[row] ("item <i>", need, work, queue, feed)
# and NEED_HIT ("from to item" per "needs you" entry). With a unit open
# (VIEW), the unit view instead.
watch_frame() {
  local w=$1 h=$2 body=() l i n row st
  FRAME=(); HIT=(); NEED_HIT=(); W_W=$w W_H=$h
  [ -z "$VIEW" ] || { unit_frame "$w" "$h"; return; }
  if ! watch_gather; then
    FRAME=(" $(m b 'filo watch')" '' "   $(m d 'No run here yet. Ask your agent to coordinate some work;')" "   $(m d 'this screen follows it as soon as it starts.')")
    KEYS=" $(m k q) quit"; return
  fi
  watch_items
  local right; right="run $(span $((NOW - ${RUN_START:-$NOW}))) · $(printf '%(%H:%M:%S)T' "$NOW")"
  body+=("$(lr " $(m b 'filo watch') $(m d ·) ${REPO##*/}" "$(m d "$right") " "$w")")
  body+=("$(coordinator_line)")
  if [ "${#NEED[@]}" -gt 0 ]; then
    local nl=" $(m yb 'needs you')    " x c
    for x in "${!NEED[@]}"; do
      [ "$x" = 0 ] || nl+=" $(m d ·) "
      c=$(( $(vis "$nl") + 1 )); nl+=${NEED[x]}
      NEED_HIT+=("$c $(vis "$nl") ${NEED_IX[x]}")
    done
    HIT[${#body[@]}]=need; body+=("$nl")
  fi
  body+=('')
  if [ "$STUCK" = 1 ]; then
    local why=() last
    last=$(clean "$(tail -n1 "$RUN/log/relay.log" 2>/dev/null)")
    why=("$(m r ✗) The wake process isn't running, so the coordinator"
         "  won't hear about ${UNDELIVERED} queued event(s) until it is.")
    [ -z "$last" ] || why+=("  $(m d "last said: $last")")
    why+=("  $(m k w) restart it")
    mapfile -t -O "${#body[@]}" body < <(box 'NOTHING WILL MOVE' '' r "$w" "${why[@]}")
    body+=('')
  fi
  if [ "${#UNITS[@]}" -gt 0 ] && [ "$OPEN" -eq 0 ]; then
    local shipped=() id round lvl goal merged=0 evl
    for row in "${UNITS[@]}"; do
      IFS=$US read -r id st _ round _ _ _ _ _ _ _ _ _ _ _ _ lvl _ _ _ _ goal _ <<< "$row"
      evl="EVL_${lvl:-none}"
      [ "$st" = merged ] && merged=$((merged + 1))
      shipped+=("$(glyph "$st") $(printf '%-13s ' "$id")$(m d "$(printf 'r%-3s' "$round")${!evl}")  $(clean "$goal")")
    done
    shipped+=('' "$(m d 'rounds · evidence ○○○ none ●○○ types ●●○ tests ●●● live')")
    mapfile -t -O "${#body[@]}" body < <(box 'RUN FINISHED' "$merged merged" g "$w" "${shipped[@]}")
    body+=('')
  else
    HIT[${#body[@]}]=work; body+=("$(rule WORK "$(m d "${#ITEMS[@]} active")" "$w")")
    if [ "${#ITEMS[@]}" -gt 0 ]; then
      for i in "${!ITEMS[@]}"; do
        n=${#body[@]}
        mapfile -t -O "$n" body < <(item_lines "$i" "$w")
        while [ "$n" -lt "${#body[@]}" ]; do HIT[n++]="item $i"; done
      done
    elif [ "${#UNITS[@]}" -eq 0 ]; then body+=("$(m d '   nothing yet: the coordinator is still planning')")
    else body+=("$(m d '   nothing in progress')"); fi
    n=${#body[@]}
    mapfile -t -O "$n" body < <(queue_lines)
    while [ "$n" -lt "${#body[@]}" ]; do HIT[n++]=queue; done
    body+=('')
  fi
  # the feed, newest first, FEED_OFF entries scrolled back by the wheel
  [ "$FEED_OFF" -lt "${#FEED[@]}" ] || FEED_OFF=$(( ${#FEED[@]} > 0 ? ${#FEED[@]} - 1 : 0 ))
  HIT[${#body[@]}]=feed; body+=("$(rule RECENT "$( [ "$FEED_OFF" = 0 ] || m d "↑ $FEED_OFF newer")" "$w")")
  n=$(( h - 3 - ${#body[@]} ))
  for (( i = ${#FEED[@]} - 1 - FEED_OFF; i >= 0 && n > 0; i--, n-- )); do
    HIT[${#body[@]}]=feed; body+=("$(m d " $(hm "${FEED[i]%%$'\t'*}")")  ${FEED[i]#*$'\t'}")
  done
  FRAME=("${body[@]:0:$((h - 3))}")
  local pk=""
  [ "${#ITEMS[@]}" -eq 0 ] || pk="$(item_keys "${ITEMS[$SEL]}")"
  [ "${#ITEMS[@]}" -lt 2 ] || pk+="$(m k j/k) move  "
  [ "$STUCK" = 0 ] || pk+="$(m k w) restart wake  "
  KEYS=" $pk$(m k ↵) open  $(m k m) message  $(m k '?') keys  $(m k q) quit"
}

# ---------------------------------------------------------------- unit view

# One unit, full screen, in six tabs: the Claude Design's drill-down (screens
# 3a-3f of "coord watch.dc.html"). VIEW is the open unit, TAB the tab (1-6),
# TSCROLL the first line shown, TFOLLOW 1 while the output tab sticks to the
# tail, OUT_IX which round's output (-1 always the newest; OUT_AT is the one
# this frame shows). Every tab writes its own indented lines.
TABS=(brief findings diff log output history)
TABS_SHORT=(brief finds diff log out hist)   # under 60 columns

# unc1 [file]: the text without DEL and UTF-8 C1 controls, byte-wise (awk
# can't match them in a UTF-8 locale; C0 is its q()'s job)
unc1() { LC_ALL=C sed 's/\x7f//g; s/\xc2[\x80-\x9f]//g' "$@"; }

# plain: untrusted text as lines: no escapes, tabs expanded, no control
# characters (C0, DEL, and UTF-8 C1)
plain() { LC_ALL=C sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\xc2[\x80-\x9f]//g' | expand -t 4 | tr -d '\000-\010\013-\037\177'; }

# out_logs <id>: the unit's agent output files, oldest first
out_logs() { ls -tr "$RUN/log/$1".r*.*.log 2>/dev/null || true; }

# EV_AWK: the start of an awk program over the event log, run after
# lib/events.awk (-v id=<unit>): each event of that unit lands in E as display
# text (lists joined by US), t is its type; hm() is a clock time, wrap()
# prints words wrapped to width w after an indent
EV_AWK='
  function hm(s) { return strftime("%H:%M", s) }
  function wrap(s, w, ind, ind2,   n, a, i, l) {
    n = split(s, a, " "); l = ""
    for (i = 1; i <= n; i++) {
      if (l != "" && length(l) + 1 + length(a[i]) > w) { print ind l; l = a[i]; ind = ind2 }
      else l = (l == "" ? a[i] : l " " a[i])
    }
    if (l != "") print ind l
  }
  BEGIN { split(evl, g, ","); EVL["none"] = g[1]; EVL["typecheck"] = g[2]; EVL["tests"] = g[3]; EVL["live"] = g[4] }
  !parse() || E["unit"] != id { next }
  { shown() }
  { t = E["type"] }
'
ev_awk() { local id=$1 prog=$2; shift 2; unc1 "$LOG" | awk -v id="$id" -v w="$W_W" -v evl="$EVL_none,$EVL_typecheck,$EVL_tests,$EVL_live" "$@" -f "$EVENTS" -f <(printf '%s' "$EV_AWK$prog"); }

# brief_fields: one headed section per brief field: the ones the worker acts
# on first, then the brief's others in its order
brief_fields() {
  local f fields=() order=(GOAL SCOPE REPRO ACCEPTANCE VERIFY) name body l x cmds=()
  mapfile -t fields < <(brief "$U_BRIEF" fields 2>/dev/null || true)
  body=$(brief "$U_BRIEF" get "" 2>/dev/null | plain || true)   # prose before the first field
  [ -z "$body" ] || { fold -s -w $((W_W - 4)) <<< "$body" | sed 's/ *$//; s/^/   /'; echo; }
  for f in "${fields[@]}"; do case " ${order[*]} TIMEBOX " in *" $f "*) ;; *) order+=("$f") ;; esac; done
  for f in "${order[@]}"; do
    body=$(brief "$U_BRIEF" get "$f" 2>/dev/null | plain) || continue
    case $f in
      ACCEPTANCE) name='Done when' ;; VERIFY) name=Checks ;;
      *) name=${f//_/ }; name=${name,,}; name=${name^} ;;
    esac
    echo " $(m b "$name")"
    case $f in
      VERIFY)
        mapfile -t cmds < <(brief "$U_BRIEF" verify 2>/dev/null | plain || true)
        l=""; for x in "${cmds[@]}"; do l+="${l:+  ·  }$x"; done
        if [ "$(( ${#l} + 3 ))" -le "$W_W" ]; then echo "   $l"; else printf '   %s\n' "${cmds[@]}"; fi ;;
      ACCEPTANCE)
        while IFS= read -r l; do
          l=$(sed -E 's/^[[:space:]]*([-*·][[:space:]]*)?//' <<< "$l"); [ -n "$l" ] || continue
          fold -s -w $((W_W - 6)) <<< "$l" | sed 's/ *$//' | awk 'NR == 1 { print "   · " $0; next } { print "     " $0 }'
        done <<< "$body" ;;
      *) fold -s -w $((W_W - 4)) <<< "$body" | sed 's/ *$//; s/^/   /' ;;
    esac
    echo
  done
}

# 3a: the brief as the worker received it, then what it depends on and blocks
brief_tab() {
  local blocks="" row x deps
  if [ -f "$U_BRIEF" ]; then brief_fields
  else echo " $(m d 'no brief yet: the unit has not been dispatched')"; echo; fi
  for row in "${UNITS[@]}"; do
    IFS=$US read -r x _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ deps _ <<< "$row"
    [[ ",$deps," != *",$VIEW,"* ]] || blocks+="${blocks:+, }$x"
  done
  deps=${U_DEPS//,/, }
  echo " $(m b 'Depends on')  ${deps:-none}"
  echo " $(m b 'Blocks')      ${blocks:-none}"
  [ ! -f "$U_BRIEF" ] || { echo; echo " $(m d "Written by the coordinator at $(date -r "$U_BRIEF" +%H:%M).")"; }
}

# 3b: the critic's rounds, newest first; earlier rounds collapse to their
# outcome (and what became of them: a failed merge, a note, a merge)
findings_tab() {
  ev_awk "$VIEW" '
    t == "dispatched" && E["role"] == "critic" {   # a critic restarted after a death stays the same round
      if (!(n && R[n] == E["round"] && RES[n] ~ /died/)) n++
      R[n] = E["round"]; RES[n] = "being reviewed"; next }
    t == "finished" && E["role"] == "critic" && n {
      RES[n] = E["result"] == "pass" ? "passed" : E["result"] == "handback" ? "sent back" : E["result"]
      LV[n] = E["level"]; TS[n] = E["ts"]; SUM[n] = E["summary"]; NOTE[n] = E["notes"]; CMD[n] = E["ran"]; next }
    t == "converted" && n { RES[n] = "sent back"; OUT[n] = OUT[n] "\n" m("y", "↩") " the pass lacked evidence: " E["reason"] }
    t == "died" && E["slug"] ~ /critic$/ && n { RES[n] = m("r", "the critic died") }
    t == "verify_failed" && n { OUT[n] = OUT[n] "\n" m("r", "✗") " the merge re-ran the checks: exit " E["exit"] " " m("d", "(see 4 log)") }
    t == "rejected" && n { OUT[n] = OUT[n] "\n" (E["by"] == "engine" ? m("r", "✗") " the merge conflicted with the base" : m("y", "↩") " you sent it back: \"" E["text"] "\"") }
    t == "merged" && n { OUT[n] = OUT[n] "\n" m("g", "✓") " merged " m("d", substr(E["sha"], 1, 7)) }
    END {
      if (!n) { print " " m("d", "no review yet"); exit }
      for (i = n; i >= 1; i--) {
        e = LV[i] == "" ? "" : m("d", " · ") "evidence " EVL[LV[i]] " " LV[i]
        print " " m("b", "Round " R[i]) "  " RES[i] e (TS[i] == "" ? "" : m("d", " · " hm(TS[i])))
        if (i == n) {
          if (SUM[i] != "") { print ""; wrap("\"" SUM[i] "\"", w - 4, "   ", "    ") }
          if (CMD[i] != "" || LV[i] != "") {
            print ""; print " " m("b", "Checks"); k = split(CMD[i], c, US); for (j = 1; j <= k; j++) print "   $ " c[j]
            if (LV[i] != "" && LV[i] != "live") print "   " m("d", "– live check  not run")
          }
          if (NOTE[i] != "") { print ""; print " " m("b", "Findings"); k = split(NOTE[i], c, / \| /); for (j = 1; j <= k; j++) wrap(c[j], w - 10, "   " m("y", "note") "  ", "         ") }
          if (OUT[i] != "") print ""
        }
        k = split(substr(OUT[i], 2), c, "\n"); for (j = 1; j <= k; j++) print "   " c[j]
        if (i > 1) print ""
      }
    }'
}

# 3c: a file summary, then the diff (a merged unit: its merge commit), one
# "── path ──" rule per file. A worktree's new files join the diff through a
# scratch index that marks them intent-to-add, so a few git calls cover any
# number of files.
diff_tab() {
  local g=(git -c core.quotePath=false) info
  if [ "$U_STATE" = merged ] && [ -n "$U_SHA" ]; then
    g+=(-C "$REPO"); set -- "$U_SHA^1" "$U_SHA"; info="merge commit ${U_SHA:0:7}"
  elif [ -d "$U_WT" ]; then
    # a copy of the worktree's own index keeps its stat cache: only changed files get hashed
    local -x GIT_INDEX_FILE="$W_TMP.index"
    cp "$(git -C "$U_WT" rev-parse --path-format=absolute --git-path index 2>/dev/null)" "$GIT_INDEX_FILE" 2>/dev/null \
      || { rm -f "$GIT_INDEX_FILE"; "${g[@]}" -C "$U_WT" read-tree HEAD 2>/dev/null || true; }
    "${g[@]}" -C "$U_WT" add -A -N 2>/dev/null || true
    g+=(-C "$U_WT"); set -- HEAD; info="branch $U_BRANCH (round $U_ROUND)"
  else
    echo " $(m d 'no changes: no worktree yet')"; return 0
  fi
  { "${g[@]}" diff --name-only --diff-filter=A "$@" 2>/dev/null || true; echo $'\001'
    "${g[@]}" diff --numstat "$@" 2>/dev/null || true; } > "$W_TMP.stat"
  # the summary; fails when there is nothing to show
  awk -F'\t' -v w="$W_W" -v info="$(clean "$info")" '
    function m(k, s) { return "\001" k "\002" s "\003" }
    function lr(l, lv, r, rv,   g) { g = w - lv - rv; if (g < 1) g = 1; return l sprintf("%" g "s", "") r }
    $0 == "\001" { stat = 1; next }
    !stat { NEW[$0] = 1; next }
    NF >= 3 {
      f = $3; gsub(/[\001-\037\177]/, " ", f); n++
      if ($1 == "-") { r = "binary"; rv = 6; rk = "d" }
      else { A += $1; D += $2; r = m("g", "+" $1) ($3 in NEW || $2 == 0 ? "" : " " m("r", "−" $2)); rv = 1 + length($1) + ($3 in NEW || $2 == 0 ? 0 : 2 + length($2)) }
      l = "   " f ($3 in NEW ? " " m("d", "(new)") : "")
      ROW[n] = lr(l, 3 + length(f) + ($3 in NEW ? 6 : 0), r "  ", rv + 2)
    }
    END {
      if (!n) { print " " m("d", "no changes yet"); exit 1 }
      l = " " m("b", n " file" (n == 1 ? "" : "s")) "  " m("g", "+" A) " " m("r", "−" D)
      print lr(l, 1 + length(n " file" (n == 1 ? "" : "s")) + 2 + length(A) + 1 + 2 + length(D), m("d", info) " ", length(info) + 1)
      print ""
      for (i = 1; i <= n; i++) print ROW[i]
    }' "$W_TMP.stat" || return 0
  echo
  { "${g[@]}" diff "$@" 2>/dev/null || true; } | plain | awk -v w="$W_W" '
    function m(k, s) { return "\001" k "\002" s "\003" }
    /^diff --git / { f = $0; sub(/^diff --git a\//, "", f); sub(/ b\/.*$/, "", f); h = " ── " f " "
                     r = ""; for (i = length(h); i < w - 1; i++) r = r "─"; print m("d", h r); hdr = 1; next }
    hdr && /^(index |--- |\+\+\+ |new file mode|deleted file mode|old mode|new mode|similarity index|rename from|rename to)/ { next }
    /^Binary files/ { print " " m("d", $0); next }
    /^@@/ { hdr = 0; print " " m("c", $0); next }
    /^\+/ { print " " m("g", $0); next }
    /^-/  { print " " m("r", $0); next }
    /^\\/ { print " " m("d", $0); next }
    { print " " $0 }'
}

# 3d: the engine's own merge checks: which round, when, how it ended
log_tab() {
  local f="$RUN/log/$VIEW.verify.log" head
  [ -f "$f" ] || { echo " $(m d "the merge's checks haven't run")"; return 0; }
  head=$(ev_awk "$VIEW" '
    t == "dispatched" { r = E["round"] }
    t == "approved" { k = "" }   # a new merge: its checks are the ones in the log now
    t == "verify_failed" { k = "f"; ts = E["ts"]; x = E["exit"]; rr = r }
    t == "merged" { k = "m"; ts = E["ts"]; sha = substr(E["sha"], 1, 7); rr = r }
    END {
      # the merge rewrites the log as it starts: a log newer than the last result
      # (an auto-merge records no approval) is a merge still running
      if (k != "" && lm > int(ts) + 1) k = ""
      if (k == "f") { print " " m("b", "Merge of round " rr) "  " hm(ts) m("d", " · ") m("r", "✗ failed") m("d", " · exit " x)
                      print m("d", " exit " x " · sent back to the worker at " hm(ts)) }
      else if (k == "m") { print " " m("b", "Merge of round " rr) "  " hm(ts) m("d", " · ") m("g", "✓ passed")
                           print m("d", " merged as " sha) }
      else { print " " m("b", "Merge") "  " m("d", "running"); print "" }
    }' -v lm="$(stat -c %Y "$f")")
  head -n1 <<< "$head"; echo
  plain < "$f" | awk '
    function m(k, s) { return "\001" k "\002" s "\003" }
    /^\$ / { print m("d", " " $0); next }
    /FAIL|^E / { print " " m("r", $0); next }
    { print " " $0 }'
  echo; tail -n1 <<< "$head"
}

# 3e: one round's agent output under what it was: role, round, time, end
output_tab() {
  local f slug role r now
  mapfile -t OUTS < <(out_logs "$VIEW")
  [ "${#OUTS[@]}" -gt 0 ] || { echo " $(m d 'no output yet')"; return 0; }
  OUT_AT=$OUT_IX
  [ "$OUT_AT" -ge 0 ] && [ "$OUT_AT" -lt "${#OUTS[@]}" ] || OUT_AT=$(( ${#OUTS[@]} - 1 ))
  f=${OUTS[OUT_AT]} slug=${f##*/}; slug=${slug%.log}; role=${slug##*.}; r=${slug#"$VIEW".r}; r=${r%%.*}
  ev_awk "$VIEW" '
    E["slug"] != slug { next }
    t == "dispatched" { d = E["ts"]; tb = E["timebox"]; e = ""; how = "" }   # a restart reuses the slug
    t == "finished" { e = E["ts"]; how = "finished at " hm(e) " · " E["result"] }
    t == "died" { e = E["ts"]; how = m("r", (E["reason"] == "timeout" ? "killed at its time limit" : "died") " at " hm(e)) }
    END {
      used = int(((e ? e : now) - d) / 60); lim = int((tb ? tb : 1800) / 60)
      print " " m("b", role " · round " r) "  " used "m of " lim "m" m("d", " · ") (how == "" ? "running" : how)
    }' -v slug="$slug" -v role="$role" -v r="$r" -v now="$NOW"
  echo
  plain < "$f" | sed 's/^/ /'
  if [ "${#OUTS[@]}" -gt 1 ]; then
    echo
    local hint=""
    [ "$OUT_AT" -eq 0 ] || hint="[ an earlier round"
    [ "$OUT_AT" -ge $(( ${#OUTS[@]} - 1 )) ] || hint+="${hint:+ · }] a later one"
    echo " $(m d "${#OUTS[@]} outputs for this unit: $hint")"
  fi
}

# 3f: the unit's story, oldest first, in the feed's words
history_tab() {
  unc1 "$LOG" | awk -F'\t' -v id="$VIEW" 'index($0, "\tunit=" id "\t")' | awk -f "$EVENTS" -f "$SKILL/lib/watch.awk" \
    | awk -F'\t' '$1 == "F" { print " \001d\002" strftime("%H:%M", $2) "\003  " $3; n++ } END { if (!n) print " \001d\002no events yet\003" }'
}

# tab_body <tab>: the tab's lines, as markup
tab_body() {
  case $1 in
    1) brief_tab ;; 2) findings_tab ;; 3) diff_tab ;; 4) log_tab ;; 5) output_tab ;; 6) history_tab ;;
  esac
}

# open_unit <id>: open the unit view on its brief, or on its merge checks'
# log when they failed
open_unit() {
  unit_row "$1" || { W_REPLY=" $(m r ✗) no unit \"$(clean "$1")\""; return 1; }
  VIEW=$1 TAB=1 TSCROLL=0 TFOLLOW=1 OUT_IX=-1 W_REPLY=""
  [[ ${REASON[$1]:-} != "the merge's checks failed"* ]] || [ "$U_STATE" = merged ] || TAB=4
}
set_tab() { TAB=$1 TSCROLL=0 TFOLLOW=1; }
scroll() { TSCROLL=$((TSCROLL + $1)); [ "$TSCROLL" -ge 0 ] || TSCROLL=0; TFOLLOW=0; }

# unit_frame <width> <height>: the open unit: "esc ‹" and where it stands, its
# goal, the tabs, the tab's lines. HIT rows: back, tabs, tab; TAB_HIT has
# each tab's columns.
unit_frame() {
  local w=$1 h=$2 id=$VIEW row="" i t pad sep it c total rows max body=() f="$W_TMP.tab" ind=""
  watch_gather || true
  unit_row "$id" || { VIEW=""; watch_frame "$w" "$h"; return; }
  for row in "${UNITS[@]}"; do [ "${row%%"$US"*}" = "$id" ] && break; done
  HIT[0]=back
  local left right
  left=" $(m d 'esc ‹')  $(m b "$id")  $(m d "$U_KIND · round $U_ROUND")"
  right="$(glyph "$U_STATE") $(sentence "$row") "   # the sentence, or just the state when it won't fit
  if [ $(( $(vis "$left") + $(vis "$right") )) -ge "$w" ]; then
    case $U_STATE in
      passed) if needs_you "$row"; then right=$(m y 'needs approval'); else right='merging'; fi ;;
      stalled|blocked) right=$(m r "$U_STATE") ;;
      merged|dropped) right=$(m d "$U_STATE") ;;
      *) right=$U_STATE ;;
    esac
    right="$(glyph "$U_STATE") $right "
  fi
  body+=("$(lr "$left" "$right" "$w")")
  body+=("           $(m d "$(clean "$U_GOAL")")" '')
  TABBAR=" " TAB_HIT=()
  for i in 1 2 3 4 5 6; do
    t=${TABS[i - 1]} pad=' ' sep=''; [ "$w" -ge 60 ] || t=${TABS_SHORT[i - 1]} pad='' sep=' '
    it="$pad$i $t$pad"; c=$(( $(vis "$TABBAR") + 1 ))
    if [ "$i" = "$TAB" ]; then TABBAR+=$(m I "$it"); else TABBAR+="$pad$(m d "$i") $t$pad"; fi
    TAB_HIT+=("$c $((c + ${#it} - 1)) $i"); TABBAR+=$sep
  done
  HIT[3]=tabs; body+=("$TABBAR")
  tab_body "$TAB" > "$f"
  total=$(wc -l < "$f"); rows=$(( h - 3 - ${#body[@]} - 1 )); VIEW_ROWS=$rows
  max=$(( total > rows ? total - rows : 0 ))
  # the newest output of a running agent follows its tail until you scroll up
  if [ "$TAB" = 5 ] && [ -n "$U_OWES" ] && [ "$TFOLLOW" = 1 ] && [ "$OUT_IX" -lt 0 ]; then TSCROLL=$max; fi
  [ "$TSCROLL" -le "$max" ] || TSCROLL=$max
  [ "$TSCROLL" -lt "$max" ] || [ "$TAB" != 5 ] || TFOLLOW=1
  [ "$total" -le "$rows" ] || ind=" $((TSCROLL + 1))–$((TSCROLL + rows < total ? TSCROLL + rows : total)) of $total ─"
  body+=("$(m d "$(rep ─ $((w - ${#ind})))$ind")")
  while IFS= read -r t; do HIT[${#body[@]}]=tab; body+=("$t"); done < <(sed -n "$((TSCROLL + 1)),$((TSCROLL + rows))p" "$f")
  FRAME=("${body[@]:0:$((h - 3))}")
  local pk=""
  [ "$U_STATE" != passed ] || pk="$(m k a) approve  $(m k r) reject  "
  [ "$TAB" != 3 ] || pk+="$(m k n/N) file  "
  [ "$TAB" != 5 ] || pk+="$(m k '[/]') round  "
  # when it's too long the bar sheds "1-6 tab" (the tab bar shows the digits),
  # then "p pager"; never esc or the tab's own keys
  KEYS=" $(m k 1-6) tab  $(m k j/k) scroll  $(m k esc) back  $pk"
  [ $(( $(vis "$KEYS") - 2 )) -le "$w" ] || KEYS=" $(m k j/k) scroll  $(m k esc) back  $pk"
  [ $(( $(vis "$KEYS") + 7 )) -gt "$w" ] || KEYS+="$(m k p) pager"
  KEYS=${KEYS%  }
}

# view_key <key>: the unit view's own keys
view_key() {
  local l
  case $1 in
    [1-6]) set_tab "$1" ;;
    RIGHT) set_tab $(( TAB % 6 + 1 )) ;;
    LEFT)  set_tab $(( (TAB + 4) % 6 + 1 )) ;;
    j|DOWN) scroll 1 ;;
    k|UP)   scroll -1 ;;
    ' ')    scroll "$(( ${VIEW_ROWS:-20} - 1 ))" ;;
    n|N) [ "$TAB" = 3 ] || return 0
         if [ "$1" = n ]; then l=$(grep -n $'^\001d\002 ── ' "$W_TMP.tab" | cut -d: -f1 | awk -v s="$TSCROLL" '$1 - 1 > s { print; exit }')
         else l=$(grep -n $'^\001d\002 ── ' "$W_TMP.tab" | cut -d: -f1 | awk -v s="$TSCROLL" '$1 - 1 < s { l = $1 } END { print l }'); fi
         [ -z "$l" ] || { TSCROLL=$((l - 1)) TFOLLOW=0; } ;;
    '['|']') [ "$TAB" = 5 ] || return 0
         mapfile -t OUTS < <(out_logs "$VIEW")
         [ "$OUT_IX" -ge 0 ] || OUT_IX=$(( ${#OUTS[@]} - 1 ))
         if [ "$1" = '[' ]; then [ "$OUT_IX" -le 0 ] || OUT_IX=$((OUT_IX - 1))
         else OUT_IX=$((OUT_IX + 1)); fi
         # past the last round: back to "the newest", which follows a live agent
         [ "$OUT_IX" -lt $(( ${#OUTS[@]} - 1 )) ] || OUT_IX=-1
         TSCROLL=0 TFOLLOW=1 ;;
    p) sed $'s/\001[a-zA-Z]*\002//g; s/\003//g' "$W_TMP.tab" > "$W_TMP.page"; page "$W_TMP.page" ;;
    ESC) VIEW="" W_REPLY="" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- terminal

W_REPLY=""
# mouse reporting (xterm SGR) is on only while the screen is ours: off for the
# pager and on exit; a terminal without it ignores the request
term_on()  { stty -echo -icanon 2>/dev/null; printf '\e[?1049h\e[?25l\e[?1000h\e[?1006h'; W_FULL=1; }
term_off() { printf '\e[?1006l\e[?1000l\e[?25h\e[?1049l'; [ -z "${W_STTY:-}" ] || stty "$W_STTY" 2>/dev/null; }

draw() {
  local w h i line out=""
  w=$(tput cols 2>/dev/null || echo 80); h=$(tput lines 2>/dev/null || echo 24)
  [ "$w" -ge 44 ] || w=44; [ "$w" -le 100 ] || w=100   # one column reads best up to 100
  [ "$w:$h" = "${W_SIZE:-}" ] || { W_SIZE="$w:$h"; W_FULL=1; W_PREV=(); printf '\e[2J'; }
  watch_frame "$w" "$h"
  local rows=("${FRAME[@]}")
  while [ "${#rows[@]}" -lt $((h - 3)) ]; do rows+=(''); done
  rows+=("$(m d "$(rep ─ "$w")")" "$W_REPLY" "$KEYS")
  for i in "${!rows[@]}"; do
    line=$(ansi "$(fit "${rows[i]}" "$w")")
    if [ "${W_FULL:-0}" = 1 ] || [ "$line" != "${W_PREV[i]:-}" ]; then
      out+=$'\e['"$((i + 1));1H$line"; W_PREV[i]=$line
    fi
  done
  printf '%s' "$out"; W_FULL=0
}

# read_key <fd> [timeout]: one key -> KEY: a character ("" is ↵), UP, DOWN,
# LEFT, RIGHT, ESC, M:<b>;<x>;<y><M|m> for an SGR mouse report, or NONE for any other
# escape sequence (read whole, so its tail isn't taken for keys)
read_key() {
  local c s="" t=()
  [ -z "${2:-}" ] || t=(-t "$2")
  IFS= read -rsn1 -u "$1" "${t[@]}" KEY || return 1
  [ "$KEY" = $'\e' ] || return 0
  KEY=ESC
  IFS= read -rsn1 -u "$1" -t 0.01 c && [ "$c" = '[' ] || return 0
  while IFS= read -rsn1 -u "$1" -t 0.01 c; do
    s+=$c; case $c in [A-Za-z~]) break ;; esac; [ "${#s}" -lt 24 ] || break
  done
  # a terminal with mouse mode but not SGR sends ESC [ M and three raw bytes:
  # read them here, or they would land as keys (wheel-down is "a")
  # (as bytes: past column 162 one reads as the start of a UTF-8 character)
  [ "$s" != M ] || LC_ALL=C IFS= read -rsn3 -u "$1" -t 0.01 c || true
  case $s in A) KEY=UP ;; B) KEY=DOWN ;; C) KEY=RIGHT ;; D) KEY=LEFT ;; '<'*[Mm]) KEY="M:${s#<}" ;; *) KEY=NONE ;; esac
}

# drain: drop input queued while a slow action ran (a second click, a key
# pressed twice), so it can't act on whatever is selected afterwards
drain() { local c; [ "$W_LIVE" != 1 ] || while IFS= read -rsn1 -t 0.05 c; do :; done; }

# mouse <M:b;x;y[Mm]>: MB MX MY for a press (b 0 left, 64/65 wheel up/down);
# fails on a release or any other button
mouse() {
  local r=${1#M:}
  [[ $r == *M ]] || return 1
  IFS=';' read -r MB MX MY <<< "${r%M}"
  case $MB in 0|64|65) ;; *) return 1 ;; esac
}

# ask <prompt markup>: one line typed on the reply row -> ANSWER (empty =
# cancelled). ↵ or a click on ✓ send sends it; esc or ✗ cancel cancels.
ask() {
  local p=$1 text="" line shown room act r
  ANSWER=""; r="$(m k '✓ send')  $(m k '✗ cancel') "
  # the targets never get cut: on a narrow screen the prompt gives way
  room=$(( W_W - $(vis "$r") - 8 )); [ "$(vis "$p")" -le "$room" ] || p=$(fit "$p" "$room")
  while :; do
    room=$(( W_W - $(vis "$p") - $(vis "$r") - 1 )); [ "$room" -ge 1 ] || room=1
    shown=$(clean "$text")
    if [ "${#shown}" -gt "$room" ]; then
      if [ "$room" -lt 2 ]; then shown=…; else shown="…${shown: -$((room - 1))}"; fi
    fi
    line=$(lr "$p$shown" "$r" "$W_W")
    mapfile -t REPLY_HIT < <(hits "$line" k)
    [ "$W_LIVE" != 1 ] || printf '\e[%d;1H\e[2K%s\e[%d;%dH\e[?25h' $((W_H - 1)) "$(ansi "$(fit "$line" "$W_W")")" \
      $((W_H - 1)) $(( $(vis "$p") + ${#shown} + 1 ))
    read_key 0 || break                             # end of input: cancelled
    case $KEY in
      '') ANSWER=$text; break ;;
      ESC) break ;;
      $'\177'|$'\b') text=${text%?} ;;
      $'\025') text="" ;;
      M:*) if mouse "$KEY" && [ "$MB" = 0 ] && [ "$MY" = $((W_H - 1)) ] && act=$(at "$MX" "${REPLY_HIT[@]}"); then
             [ "$act" = '✓ send' ] && ANSWER=$text; break
           fi ;;
      UP|DOWN|NONE) ;;
      *) [[ $KEY == [[:cntrl:]] ]] || text+=$KEY ;;
    esac
  done
  [ "$W_LIVE" != 1 ] || printf '\e[?25l'; W_FULL=1
}

# run <cmd...>: a filo command, its one-line reply on the reply row
run() {
  local out
  if out=$("$SELF" "$@" 2>&1); then W_REPLY=" $(m d ›) ok: $(clean "$(head -n1 <<< "$out")")"
  else W_REPLY=" $(m r '✗ refused:') $(clean "$(sed -E 's/^REFUSED [^ ]+ [^:]+: //; s/^[a-z]+: //' <<< "$(head -n1 <<< "$out")")")"
  fi
}

page() { # page <file>
  term_off
  ${PAGER:-less -R} "$1" 2>/dev/null || cat "$1"
  term_on
}

keys_page() { ( . "$SKILL/lib/help.sh"; help_verb watch ) > "$W_TMP.page"; page "$W_TMP.page"; }

# on_mouse <M:...>: a click or wheel turn, hit-tested against the last frame.
# Click an item to select it, the selected one to open it, a "needs you"
# entry to select its item, a unit in up next or done to open it, a key in
# the bar to press it; the wheel moves the selection over WORK and scrolls
# RECENT. In the unit view: click a tab to show it, the wheel scrolls it.
on_mouse() {
  local k i hit=()
  mouse "$1" || return 0
  if [ "$MY" = "$W_H" ]; then
    mapfile -t hit < <(hits "$KEYS" k)
    [ "$MB" = 0 ] && k=$(at "$MX" "${hit[@]}") || return 0
    case $k in j/k|1-6|n/N|'[/]') return 0 ;; ↵) k='' ;; esac
    [ "$k" != esc ] || k=ESC
    on_key "$k"; return
  fi
  [ "$MY" -le "${#FRAME[@]}" ] || return 0
  case $MB:${HIT[MY - 1]:-} in
    0:back) [ "$MX" -gt 7 ] || VIEW="" W_REPLY="" ;;
    0:tabs) k=$(at "$MX" "${TAB_HIT[@]}") && set_tab "$k" ;;
    64:tab) scroll -3 ;;
    65:tab) scroll 3 ;;
    0:queue) mapfile -t hit < <(hits "${FRAME[MY - 1]}" u); k=$(at "$MX" "${hit[@]}") && open_unit "$k" ;;
    0:item*) i=${HIT[MY - 1]#item }; if [ "$i" = "$SEL" ]; then on_key ''; else SEL=$i; fi ;;
    0:need) i=$(at "$MX" "${NEED_HIT[@]}") && SEL=$i ;;
    64:item*|64:work) [ "$SEL" -eq 0 ] || SEL=$((SEL - 1)) ;;
    65:item*|65:work) [ "$SEL" -ge $(( ${#ITEMS[@]} - 1 )) ] || SEL=$((SEL + 1)) ;;
    64:feed) [ "$FEED_OFF" -eq 0 ] || FEED_OFF=$((FEED_OFF - 1)) ;;
    65:feed) FEED_OFF=$((FEED_OFF + 1)) ;;
  esac
  return 0
}

on_key() {
  local key=$1 item="" kind="" id=""
  if [ "${#ITEMS[@]}" -gt 0 ]; then item=${ITEMS[$SEL]}; kind=${item%%$'\t'*}; id=${item#*$'\t'}; fi
  if [ -n "$VIEW" ]; then   # the unit view: a, r, m, w, ?, q and the mouse act as on the main screen
    kind=unit id=$VIEW
    case $key in a|r|m|w|'?'|q|M:*) ;; *) view_key "$key"; return 0 ;; esac
  fi
  case $key in
    q) return 1 ;;
    j|$'\t'|DOWN) [ "${#ITEMS[@]}" -eq 0 ] || SEL=$(( (SEL + 1) % ${#ITEMS[@]} )) ;;
    k|UP)          [ "${#ITEMS[@]}" -eq 0 ] || SEL=$(( (SEL + ${#ITEMS[@]} - 1) % ${#ITEMS[@]} )) ;;
    a) if [ "$kind" = unit ] && [ "${STATE[$id]}" = passed ]; then
         W_REPLY=" $(m d ›) approving $id, then merging (re-running its checks)…"; [ "$W_LIVE" != 1 ] || draw
         run approve "$id" && run merge "$id"; drain
       fi ;;
    r) if [ "$kind" = unit ] && [ "${STATE[$id]}" = passed ]; then
         ask "$(m y "send $id back ›") "; [ -z "$ANSWER" ] || run reject "$id" "$ANSWER"
       fi ;;
    o) [ "$kind" = unit ] && [ "${STATE[$id]}" = blocked ] && run reopen "$id" --reason "reopened from filo watch" ;;
    x) if [ "$kind" = unit ] && [ "${STATE[$id]}" = blocked ]; then
         ask "$(m r "drop $id for good? type yes ›") "; [ "$ANSWER" != yes ] || run drop "$id" --reason "dropped from filo watch"
       fi ;;
    c) if [ "$kind" = gate ]; then
         run gate decide "$id" "$(awk -F'\t' -v id="$id" '$1 == id { print $5 }' "$RUN/gates.tsv")"
       fi ;;
    d) if [ "$kind" = gate ]; then ask "$(m y "$id: your answer ›") "; [ -z "$ANSWER" ] || run gate decide "$id" "$ANSWER"; fi ;;
    v) if [ "$kind" = report ]; then
         echo "$id" >> "$RUN/watch.read"; page "$(cut -f1 <<< "${REPORT[$id]}")"
       fi ;;
    m) ask "$(m c 'to the coordinator ›') "; [ -z "$ANSWER" ] || { run msg - "$ANSWER" && W_REPLY=" $(m d ›) ok: sent; the coordinator wakes to read it"; } ;;
    w) run relay --detach ;;
    '?') keys_page ;;
    M:*) on_mouse "$key"; return ;;
    '') case $kind in
          unit) open_unit "$id" ;;
          report) echo "$id" >> "$RUN/watch.read"; page "$(cut -f1 <<< "${REPORT[$id]}")" ;;
          research) page "$RUN/log/$id.log" ;;
          *) ask "$(m c 'open unit ›') "; [ -z "$ANSWER" ] || open_unit "$ANSWER" ;;
        esac ;;
  esac
  return 0
}

#   watch [--once] [--width N] [--height N] [--open <unit> [--tab <tab>]] [--press <keys>]
cmd_watch() {
  parse_args watch "width height press open tab" "" "once" "$@"
  SEL=0 W_LIVE=0 FEED_OFF=0 VIEW="" TAB=1
  W_TMP="$RUN/watch.$$"   # this watch's scratch files (two watches never share them)
  if [ -n "${F[open]:-}" ]; then   # --open: start in a unit's view, on --tab (a name or 1-6)
    watch_gather || true
    open_unit "${F[open]}" || { fail 2 'watch: no unit "%s"' "${F[open]}"; return; }
    local t tab=""
    for t in 1 2 3 4 5 6; do case ${F[tab]:-} in "$t"|"${TABS[t - 1]}") tab=$t ;; esac; done
    [ -z "${F[tab]:-}" ] || [ -n "$tab" ] || { fail 2 'watch: --tab is one of 1-6 or %s' "${TABS[*]}"; return; }
    [ -z "$tab" ] || set_tab "$tab"
  fi
  W_COLOR=0; { [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; } && W_COLOR=1
  if [ "${F[once]:-0}" = 1 ] || [ ! -t 0 ] || [ ! -t 1 ]; then
    local w=${F[width]:-$(tput cols 2>/dev/null || echo 80)} h=${F[height]:-40} l
    [ "$w" -ge 44 ] || w=44
    local pfd   # --press: keys (and mouse reports) to act on first (tests)
    exec {pfd}< <(printf '%s' "${F[press]:-}")
    while read_key "$pfd"; do watch_frame "$w" "$h"; on_key "$KEY" || break; done
    exec {pfd}<&-
    watch_frame "$w" "$h"
    [ -z "$W_REPLY" ] || FRAME+=("$W_REPLY")
    for l in "${FRAME[@]}" "$(m d "$(rep ─ "$w")")" "$KEYS"; do ansi "$(fit "$l" "$w")" | sed 's/ *$//'; echo; done
    rm -f "$W_TMP".*
    return 0
  fi
  W_LIVE=1 W_STTY=$(stty -g 2>/dev/null || true)
  trap 'term_off; rm -f "$W_TMP".*' EXIT
  trap 'W_FULL=1' WINCH
  term_on
  while :; do
    draw
    ! read_key 0 1 || on_key "$KEY" || break
  done
}
