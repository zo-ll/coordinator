# watch.sh: coord watch, the one command the user runs (sourced by bin/coord).
# It reads the run's state, draws it on the terminal, redraws only the lines
# that changed, and turns a few keys into coord commands.
#
# Frames are built in a small markup: \001 style \002 text \003, where style is
# d dim, b bold, y yellow, yb bold yellow, r red, rb bold red, g green, gb bold green,
# c cyan, k key (bold cyan), I inverse. fit() cuts a line to the width and
# ansi() turns it into escapes (or plain text under NO_COLOR / no terminal).

shopt -s extglob

W_SO=$'\001' W_SM=$'\002' W_SE=$'\003'
m() { printf '%s' "$W_SO$1$W_SM$2$W_SE"; }
# clean <text>: one line of untrusted text, no markup or control characters
clean() { local s=${1//[$'\001'-$'\037']/ }; printf '%s' "${s//$'\177'/}"; }

vis() { local s=${1//$W_SO+([a-zA-Z])$W_SM/}; s=${s//$W_SE/}; printf '%s' "${#s}"; }

# fit <markup> <width>: exactly <width> visible columns, … where cut
fit() {
  local s=$1 w=$2 out="" n=0 k t room
  while [ -n "$s" ] && [ "$n" -lt "$w" ]; do
    if [[ $s == "$W_SO"* ]]; then
      k=${s:1}; k=${k%%"$W_SM"*}; s=${s#*"$W_SM"}; t=${s%%"$W_SE"*}; s=${s#*"$W_SE"}
    else
      k=""; t=${s%%"$W_SO"*}; s=${s:${#t}}
    fi
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
  for k in yb rb gb d b y r g c k I; do
    case $k in d) c=2 ;; b) c=1 ;; y) c=33 ;; yb) c='1;33' ;; r) c=31 ;; rb) c='1;31' ;;
               g) c=32 ;; gb) c='1;32' ;; c) c=36 ;; k) c='1;36' ;; I) c=7 ;; esac
    s=${s//"$W_SO$k$W_SM"/$'\e['"${c}m"}
  done
  printf '%s' "${s//$W_SE/$'\e[0m'}"
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
  UNITS=(); FEED=(); PEND=(); AGENTS=()
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
  done < <(awk -f "$SKILL/lib/watch.awk" "$LOG")
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
  OPEN=0
  for line in "${UNITS[@]}"; do case $(cut -d"$US" -f2 <<< "$line") in merged|dropped) ;; *) OPEN=$((OPEN + 1)) ;; esac; done
  # the wake process is only missed while something is left to deliver or do
  STUCK=0
  [ "$RELAY_UP" = 1 ] || { [ "$OPEN" -eq 0 ] && [ "$UNDELIVERED" -eq 0 ] && [ "${#UNITS[@]}" -gt 0 ]; } || STUCK=1
}

# the run's pending items, in order: blocked, passed, open gates, unread reports
watch_pending() {
  local row id st g slug
  for row in "${UNITS[@]}"; do IFS=$US read -r id st _ <<< "$row"; [ "$st" = blocked ] && PEND+=("unit"$'\t'"$id"); done
  for row in "${UNITS[@]}"; do IFS=$US read -r id st _ <<< "$row"; [ "$st" = passed ] && PEND+=("unit"$'\t'"$id"); done
  if [ -f "$RUN/gates.tsv" ]; then
    while IFS=$'\t' read -r g st _; do [ "$st" = open ] && PEND+=("gate"$'\t'"$g"); done < "$RUN/gates.tsv"
  fi
  for slug in $(printf '%s\n' "${!REPORT[@]}" | sort -t. -k2 -n); do
    grep -qxF "$slug" "$RUN/watch.read" 2>/dev/null || PEND+=("report"$'\t'"$slug")
  done
  [ "${#PEND[@]}" -gt 0 ] || { SEL=0; return 0; }
  [ "$SEL" -lt "${#PEND[@]}" ] || SEL=$(( ${#PEND[@]} - 1 ))
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
  local id st kind round deps d waits=""
  IFS=$US read -r id st kind round _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ deps _ <<< "$1"
  case $st in
    todo)
      local IFS=,
      for d in $deps; do case ${STATE[$d]:-} in merged|dropped) ;; *) waits+="${waits:+, }$d" ;; esac; done
      [ -n "$waits" ] && printf 'waiting on %s' "$waits" || printf 'ready to start' ;;
    working)   printf 'being built · round %s' "$round" ;;
    built)     printf 'built · waiting for review' ;;
    reviewing) printf 'being reviewed · round %s' "$round" ;;
    passed)    m y 'passed · needs approval' ;;
    approved)  printf 'approved · merging' ;;
    handback)  printf 'sent back: %s' "$(clean "${REASON[$id]:-see its history}")" ;;
    stalled)   m r 'agent died · restarting' ;;
    blocked)   m r "blocked: $(clean "${REASON[$id]:-}")" ;;
    merged)    printf 'merged' ;;
    dropped)   printf 'dropped' ;;
  esac
}

pend_keys() { # the keys for the selected pending item
  local kind=${1%%$'\t'*} id=${1#*$'\t'}
  case $kind in
    unit) case ${STATE[$id]} in
            passed)  printf '%s approve  %s reject  %s details' "$(m k a)" "$(m k r)" "$(m k ↵)" ;;
            blocked) printf '%s reopen  %s drop  %s details' "$(m k o)" "$(m k x)" "$(m k ↵)" ;;
          esac ;;
    gate)   printf '%s confirm  %s change' "$(m k c)" "$(m k d)" ;;
    report) printf '%s read' "$(m k v)" ;;
  esac
}

# pend_lines <index> <width>: an item's lines inside the box
pend_lines() {
  local item=${PEND[$1]} w=$2 kind id mark="  " crit round level summary l g st q opts def
  kind=${item%%$'\t'*} id=${item#*$'\t'}
  [ "$1" = "$SEL" ] && mark="$(m y ▸) "
  case $kind in
    unit)
      if [ "${STATE[$id]}" = passed ]; then
        IFS=$'\t' read -r round level summary <<< "${CRITIC[$id]:-}"
        local evl="EVL_${level:-none}"
        echo "$mark$(glyph passed) $(m b "$id")  passed review $(m d ·) round ${round:-?} $(m d ·) ${!evl:-} ${level:-none}"
        [ -z "$summary" ] || while IFS= read -r l; do echo "    $l"; done < <(wrap "\"$(clean "$summary")\"" $((w - 8)) 2)
      else
        echo "$mark$(glyph blocked) $(m b "$id")  $(m r "blocked: $(clean "${REASON[$id]:-}")")"
      fi ;;
    gate)
      IFS=$US read -r g st q opts def _ < <(awk -F'\t' -v OFS="$US" -v id="$id" '$1 == id { $1 = $1; print }' "$RUN/gates.tsv")
      echo "$mark$(m y ?) $(m b decision)  $(clean "$q")"
      echo "    default: $(clean "$def") $(m d '· the coordinator went with it')" ;;
    report)
      IFS=$'\t' read -r _ _ summary <<< "${REPORT[$id]}"
      echo "$mark$(m y ≡) $(m b report)  $(clean "$summary")" ;;
  esac
  [ "$1" != "$SEL" ] || echo "    $(pend_keys "$item")"
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

agent_lines() { # agent_lines <width>
  local w=$1 row id st kind round role owes pid wt br base wb logf disp tb used lim live age warn slug rep lg
  for row in "${UNITS[@]}"; do
    IFS=$US read -r id st kind round role owes pid wt br base wb logf disp tb _ <<< "$row"
    [ -n "$owes" ] || continue
    AGENTS+=("$id")
    used=$(( (NOW - ${disp%.*}) / 60 )); lim=$(( ${tb:-1800} / 60 ))
    age=$(( NOW - $(stat -c %Y "$logf" 2>/dev/null || echo "${disp%.*}") ))
    warn=0; [ "$age" -ge 120 ] && warn=1
    live="output $(span "$age") ago"; [ "$warn" = 1 ] && live=$(m y "quiet $(span "$age")") || live=$(m d "$live")
    local t="$used/${lim}m"; [ $((used * 100)) -ge $((lim * 85)) ] && t=$(m y "$t")
    local g=◐; [ "$role" = critic ] && g=◑
    echo "$(lr " $g $(m b "$id")  $(m d "$role · round $round")" "$t  $live " "$w")"
    echo "   $(m d └) $(clean "$(last_line "$logf")")"
  done
  while IFS=$US read -r slug pid rep lg disp tb; do
    [ -n "$slug" ] && alive "$pid" || continue
    AGENTS+=("$slug")
    age=$(( NOW - $(stat -c %Y "$lg" 2>/dev/null || echo "${disp%.*}") ))
    echo "$(lr " ≡ $(m b "$slug")  $(m d researcher)" "$(( (NOW - ${disp%.*}) / 60 ))/$(( ${tb:-1800} / 60 ))m  $(m d "output $(span "$age") ago") " "$w")"
    echo "   $(m d └) $(clean "$(last_line "$lg")")"
  done <<< "$RESEARCH_LIVE"
}

unit_lines() { # unit_lines <width>
  local w=$1 row id st kind next="" done_="" col
  for row in "${UNITS[@]}"; do
    IFS=$US read -r id st kind _ <<< "$row"
    case $st in
      todo) next+="  ○ $id$( [ "$(sentence "$row")" = 'ready to start' ] || printf ', %s' "$(sentence "$row")")" ;;
      merged|dropped) done_+="  $(glyph "$st") $id" ;;
      *) if [ "$w" -ge 56 ]; then col=$(printf '%-10s' "$kind"); col=$(m d "$col"); else col=""; fi
         echo " $(glyph "$st") $(printf '%-13s ' "$id")$col$(sentence "$row")" ;;
    esac
  done
  [ -z "$next" ] || echo "$(m d "   up next$next")"
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
  elif [ -n "$ACKED" ]; then s="○ idle $(m d "· last turn $(hm "$ACKED")")"
  else s="○ idle"
  fi
  printf ' coordinator  %s' "$s"
}

# watch_frame <width> <height>: FRAME (body lines), KEYS
watch_frame() {
  local w=$1 h=$2 body=() l i n row st
  FRAME=()
  if ! watch_gather; then
    FRAME=(" $(m b 'coord watch')" '' "   $(m d 'No run here yet. Ask your agent to coordinate some work;')" "   $(m d 'this screen follows it as soon as it starts.')")
    KEYS=" $(m k q) quit"; return
  fi
  watch_pending
  local right; right="run $(span $((NOW - ${RUN_START:-$NOW}))) · $(printf '%(%H:%M:%S)T' "$NOW")"
  body+=("$(lr " $(m b 'coord watch') $(m d ·) ${REPO##*/}" "$(m d "$right") " "$w")")
  body+=("$(coordinator_line)" '')
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
  if [ "${#PEND[@]}" -gt 0 ]; then
    local items=()
    for i in "${!PEND[@]}"; do
      [ "$i" = 0 ] || items+=('')
      mapfile -t -O "${#items[@]}" items < <(pend_lines "$i" "$w")
    done
    mapfile -t -O "${#body[@]}" body < <(box PENDING "${#PEND[@]}" y "$w" "${items[@]}")
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
    local ag; mapfile -t ag < <(agent_lines "$w")
    body+=("$(rule AGENTS "$( [ "${#ag[@]}" -gt 0 ] && m d "$(( ${#ag[@]} / 2 )) running")" "$w")")
    [ "${#ag[@]}" -gt 0 ] && body+=("${ag[@]}") || body+=("$(m d '   none running')")
    body+=('' "$(rule UNITS "$(m d "${#UNITS[@]}")" "$w")")
    if [ "${#UNITS[@]}" -gt 0 ]; then mapfile -t -O "${#body[@]}" body < <(unit_lines "$w")
    else body+=("$(m d '   none yet: the coordinator is still planning')"); fi
    body+=('')
  fi
  body+=("$(rule RECENT '' "$w")")
  n=$(( h - 3 - ${#body[@]} ))
  for (( i = ${#FEED[@]} - 1; i >= 0 && n > 0; i--, n-- )); do
    body+=("$(m d " $(hm "${FEED[i]%%$'\t'*}")")  ${FEED[i]#*$'\t'}")
  done
  FRAME=("${body[@]:0:$((h - 3))}")
  local pk=""; [ "${#PEND[@]}" -eq 0 ] || pk="$(pend_keys "${PEND[$SEL]}")  "
  [ "${#PEND[@]}" -lt 2 ] || pk+="$(m k tab) next  "
  [ "$STUCK" = 0 ] || pk+="$(m k w) restart wake  "
  [[ $pk == *↵* ]] || pk+="$(m k ↵) open  "
  KEYS=" $pk$(m k m) message  $(m k '?') keys  $(m k q) quit"
}

# ---------------------------------------------------------------- terminal

W_REPLY=""
term_on()  { stty -echo -icanon 2>/dev/null; printf '\e[?1049h\e[?25l'; W_FULL=1; }
term_off() { printf '\e[?25h\e[?1049l'; [ -z "${W_STTY:-}" ] || stty "$W_STTY" 2>/dev/null; }

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

# ask <prompt markup>: one line typed on the reply row -> ANSWER (empty = cancelled)
ask() {
  local h; h=$(tput lines 2>/dev/null || echo 24)
  printf '\e[%d;1H\e[2K%s\e[?25h' "$((h - 1))" "$(ansi "$1")"
  stty echo icanon 2>/dev/null
  IFS= read -r ANSWER || ANSWER=""
  stty -echo -icanon 2>/dev/null; printf '\e[?25l'; W_FULL=1
}

# run <cmd...>: a coord command, its one-line reply on the reply row
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

unit_page() { # unit_page <id> -> a file with everything about one unit
  local id=$1 f="$RUN/watch.page" l
  unit_row "$id" || { W_REPLY=" $(m r ✗) no unit \"$(clean "$id")\""; return 1; }
  {
    echo "== $id · $U_KIND · $U_STATE · round $U_ROUND"
    echo "$U_GOAL"; echo
    echo "== brief"; cat "$U_BRIEF" 2>/dev/null || echo "(none yet)"; echo
    if [ -n "${CRITIC[$id]:-}" ]; then
      local cr cl cs; IFS=$'\t' read -r cr cl cs <<< "${CRITIC[$id]}"
      echo "== critic passed round $cr · evidence: ${cl:-none}"; echo "$cs"; echo
    fi
    echo "== changes"
    if [ "$U_STATE" = merged ] && [ -n "$U_SHA" ]; then git -C "$REPO" diff --stat -p "$U_SHA^1" "$U_SHA"
    elif [ -d "$U_WT" ]; then
      git -C "$U_WT" diff --stat -p HEAD
      git -C "$U_WT" ls-files --others --exclude-standard | sed 's/^/new file: /'
    fi; echo
    [ ! -f "$RUN/log/$id.verify.log" ] || { echo "== the merge's checks"; cat "$RUN/log/$id.verify.log"; echo; }
    for l in "$RUN/log/$id".r*.*.log; do [ -f "$l" ] && { echo "== output: ${l##*/}"; tail -n 200 "$l" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g'; echo; }; done
    echo "== history"; cmd_log "$id"
  } > "$f" 2>&1
  page "$f"
}

keys_page() {
  local f="$RUN/watch.page"
  cat > "$f" <<'EOF'
coord watch keys

On the ▸ waiting item
  tab     next waiting item
  a       approve a passed unit (then merge it, re-running its checks)
  r       send a passed unit back, with a note
  o / x   reopen / drop a blocked unit (drop asks first; it is final)
  c / d   confirm / change an open decision
  v       read a research report

Anywhere
  ↵       open the ▸ unit: brief, critic, changes, checks, output, history
          (with nothing selected, asks which unit)
  m       send the coordinator a message
  w       restart the wake process, when it is down
  ?       this page
  q       quit (the run keeps going)
EOF
  page "$f"
}

on_key() {
  local key=$1 item="" kind="" id=""
  if [ "${#PEND[@]}" -gt 0 ]; then item=${PEND[$SEL]}; kind=${item%%$'\t'*}; id=${item#*$'\t'}; fi
  case $key in
    q) return 1 ;;
    $'\t') [ "${#PEND[@]}" -eq 0 ] || SEL=$(( (SEL + 1) % ${#PEND[@]} )) ;;
    a) if [ "$kind" = unit ] && [ "${STATE[$id]}" = passed ]; then
         W_REPLY=" $(m d ›) approving $id, then merging (re-running its checks)…"; [ "$W_LIVE" != 1 ] || draw
         run approve "$id" && run merge "$id"
       fi ;;
    r) if [ "$kind" = unit ] && [ "${STATE[$id]}" = passed ]; then
         ask "$(m y "send $id back ›") "; [ -z "$ANSWER" ] || run reject "$id" "$ANSWER"
       fi ;;
    o) [ "$kind" = unit ] && [ "${STATE[$id]}" = blocked ] && run reopen "$id" --reason "reopened from coord watch" ;;
    x) if [ "$kind" = unit ] && [ "${STATE[$id]}" = blocked ]; then
         ask "$(m r "drop $id for good? type yes ›") "; [ "$ANSWER" != yes ] || run drop "$id" --reason "dropped from coord watch"
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
    '') case $kind in
          unit) unit_page "$id" ;;
          report) echo "$id" >> "$RUN/watch.read"; page "$(cut -f1 <<< "${REPORT[$id]}")" ;;
          *) ask "$(m c 'open unit ›') "; [ -z "$ANSWER" ] || unit_page "$ANSWER" ;;
        esac ;;
  esac
  return 0
}

#   watch [--once] [--width N] [--height N]
cmd_watch() {
  parse_args watch "width height press" "" "once" "$@"
  SEL=0 W_LIVE=0
  W_COLOR=0; { [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; } && W_COLOR=1
  if [ "${F[once]:-0}" = 1 ] || [ ! -t 0 ] || [ ! -t 1 ]; then
    local w=${F[width]:-$(tput cols 2>/dev/null || echo 80)} h=${F[height]:-40} l
    [ "$w" -ge 44 ] || w=44
    local keys=${F[press]:-} i   # --press: keys to act on first (tests)
    for (( i = 0; i < ${#keys}; i++ )); do watch_frame "$w" "$h"; on_key "${keys:i:1}" || break; done
    watch_frame "$w" "$h"
    [ -z "$W_REPLY" ] || FRAME+=("$W_REPLY")
    for l in "${FRAME[@]}" "$(m d "$(rep ─ "$w")")" "$KEYS"; do ansi "$(fit "$l" "$w")" | sed 's/ *$//'; echo; done
    return 0
  fi
  W_LIVE=1 W_STTY=$(stty -g 2>/dev/null || true)
  trap 'term_off' EXIT
  trap 'W_FULL=1' WINCH
  term_on
  local key k2
  while :; do
    draw
    if IFS= read -rsn1 -t 1 key; then
      if [ "$key" = $'\e' ]; then IFS= read -rsn5 -t 0.01 k2 || true; continue; fi
      on_key "$key" || break
    fi
  done
}
