#!/usr/bin/env bash
# lib/model.awk, the transition table: one row per legal move (the state it
# lands in) and one per refused move (a substring of the refusal).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
MODEL="$ROOT/lib/model.awk"
T=$'\t'

add()  { echo "type=unit_added${T}unit=$1${T}kind=feature${2:+${T}deps=$2}"; }
disp() { echo "type=dispatched${T}unit=$1${T}role=$2${T}round=$3${T}slug=$1.r$3.$2${T}pid=$4"; }
fin()  { echo "type=finished${T}unit=$1${T}slug=$1.r$3.$2${T}result=$4"; }
died() { echo "type=died${T}slug=$1.r$3.$2${T}pid=$4${T}reason=exited"; }
on()   { echo "type=$1${T}unit=$2"; }

# write_log <file> <event>...: stamp events with seq, ts, terminator
write_log() {
  local f=$1 n=0 e; shift; : > "$f"
  for e in "$@"; do n=$((n + 1)); printf 'seq=%s\tts=0\t%s\t.\n' "$n" "$e" >> "$f"; done
}

# prefixes that bring unit u to a state
to_todo=("$(add u)")
to_working=("${to_todo[@]}" "$(disp u worker 1 10)")
to_built=("${to_working[@]}" "$(fin u worker 1 done)")
to_reviewing=("${to_built[@]}" "$(disp u critic 1 11)")
to_passed=("${to_reviewing[@]}" "$(fin u critic 1 pass)")
to_handback=("${to_reviewing[@]}" "$(fin u critic 1 handback)")
to_stalled=("${to_working[@]}" "$(died u worker 1 10)")
to_approved=("${to_passed[@]}" "$(on approved u)")
to_blocked=("${to_todo[@]}" "$(on blocked u)")

# check <name> <expect> <event> <prefix...>: expect is a state, or !substring
check() {
  local name=$1 want=$2 e=$3; shift 3
  write_log "$TMP/log" "$@"
  printf 'seq=%s\tts=0\t%s\t.\n' $(( $# + 1 )) "$e" > "$TMP/cand"
  local res state
  res=$(awk -v mode=check -v cand="$TMP/cand" -f "$MODEL" "$TMP/log" "$TMP/cand" || true)
  if [[ $want == !* ]]; then
    [[ $res == *"${want#!}"* ]] || { echo "  $name: got '$res', want refusal containing '${want#!}'"; exit 1; }
    return
  fi
  [ "$res" = OK ] || { echo "  $name: refused: $res"; exit 1; }
  cat "$TMP/cand" >> "$TMP/log"
  state=$(awk -v mode=units -f "$MODEL" "$TMP/log" | awk -F$'\037' '$1 == "u" { print $2 }')
  [ "$state" = "$want" ] || { echo "  $name: state '$state', want '$want'"; exit 1; }
}

# legal moves, one per row of the SPEC table
check add               todo      "$(add u)"
check todo+worker       working   "$(disp u worker 1 10)"   "${to_todo[@]}"
check handback+worker   working   "$(disp u worker 2 12)"   "${to_handback[@]}"
check worker-done       built     "$(fin u worker 1 done)"  "${to_working[@]}"
check worker-partial    handback  "$(fin u worker 1 partial)" "${to_working[@]}"
check built+critic      reviewing "$(disp u critic 1 11)"   "${to_built[@]}"
check critic-pass       passed    "$(fin u critic 1 pass)"  "${to_reviewing[@]}"
check critic-handback   handback  "$(fin u critic 1 handback)" "${to_reviewing[@]}"
check converted         handback  "$(on converted u)"       "${to_passed[@]}"
check worker-died       stalled   "$(died u worker 1 10)"   "${to_working[@]}"
check critic-died       stalled   "$(died u critic 1 11)"   "${to_reviewing[@]}"
check stalled+worker    working   "$(disp u worker 1 13)"   "${to_stalled[@]}"
check approve           approved  "$(on approved u)"        "${to_passed[@]}"
check reject            handback  "$(on rejected u)"        "${to_passed[@]}"
check verify-failed     handback  "$(on verify_failed u)"   "${to_approved[@]}"
check merge-approved    merged    "$(on merged u)"          "${to_approved[@]}"
check merge-passed      merged    "$(on merged u)"          "${to_passed[@]}"
check block-working     blocked   "$(on blocked u)"         "${to_working[@]}"
check reopen            todo      "$(on reopened u)"        "${to_blocked[@]}"
check drop-blocked      dropped   "$(on dropped u)"         "${to_blocked[@]}"

# refused moves
check dup-id            "!id already exists"                 "$(add u)" "${to_todo[@]}"
check bad-id            "!invalid id"                        "$(add u.1)"
check unknown-dep       "!unknown dep \"ghost\""             "$(add u ghost)"
check round-skip        "!round 2, want 1"                   "$(disp u worker 2 10)" "${to_todo[@]}"
check coordinator-slug  "!want \"u.r1.worker\""              "type=dispatched${T}unit=u${T}role=worker${T}round=1${T}slug=u${T}pid=1" "${to_todo[@]}"
check critic-early      "!cannot dispatch a critic from working" "$(disp u critic 1 11)" "${to_working[@]}"
check worker-twice      "!cannot dispatch a worker from working" "$(disp u worker 2 11)" "${to_working[@]}"
check stalled-other     "!cannot dispatch a critic from stalled" "$(disp u critic 1 11)" "${to_stalled[@]}"
check stale-slug        "!DUP"                               "$(fin u worker 1 done)" "${to_handback[@]}"
check unowed-slug       "!not owed"                          "$(fin u critic 1 pass)" "${to_working[@]}"
check worker-pass       "!worker result \"pass\""            "$(fin u worker 1 pass)" "${to_working[@]}"
check died-wrong-pid    "!no live launch"                    "$(died u worker 1 99)" "${to_working[@]}"
check approve-built     "!cannot approve from built"         "$(on approved u)" "${to_built[@]}"
check merge-reviewing   "!cannot merge from reviewing"       "$(on merged u)" "${to_reviewing[@]}"
check reopen-todo       "!cannot reopen from todo"           "$(on reopened u)" "${to_todo[@]}"
check block-blocked     "!blocked not allowed from blocked"  "$(on blocked u)" "${to_blocked[@]}"
check drop-merged       "!dropped not allowed from merged"   "$(on dropped u)" "${to_approved[@]}" "$(on merged u)"
check convert-working   "!cannot convert"                    "$(on converted u)" "${to_working[@]}"

# readiness: b waits on a until a is merged or dropped
check dep-not-ready     "!not ready"                         "$(disp b worker 1 1)" "$(add a)" "$(add b a)"
write_log "$TMP/log" "$(add a)" "$(add b a)" "$(on dropped a)"
ready=$(awk -v mode=units -f "$MODEL" "$TMP/log" | awk -F$'\037' '$19 == 1 { print $1 }')
assert "$ready" "b"

# retry cap: a second death in a round leaves no third launch
write_log "$TMP/log" "${to_stalled[@]}" "$(disp u worker 1 20)" "$(died u worker 1 20)"
check third-launch      "!died 2 times in round 1"           "$(disp u worker 1 21)" "${to_stalled[@]}" "$(disp u worker 1 20)" "$(died u worker 1 20)"

# reopen after a block continues at the next unused round
check reopen-round      working "$(disp u worker 2 30)" "${to_handback[@]}" "$(on blocked u)" "$(on reopened u)"

# delivery: a wake event is undelivered, claimed, nacked, claimed, acked
write_log "$TMP/log" "${to_built[@]}"
assert "$(awk -v mode=undelivered -f "$MODEL" "$TMP/log" | wc -l)" "1"
printf 'seq=4\tts=0\ttype=claimed\tseqs=3\tbatch=b\t.\n' >> "$TMP/log"
assert "$(awk -v mode=undelivered -f "$MODEL" "$TMP/log" | wc -l)" "0"
assert "$(awk -v mode=inflight -f "$MODEL" "$TMP/log")" "3"
printf 'seq=5\tts=0\ttype=claimed\tseqs=3\t.\n' > "$TMP/cand"
has "$(awk -v mode=check -v cand="$TMP/cand" -f "$MODEL" "$TMP/log" "$TMP/cand" || true)" "already claimed"
printf 'seq=5\tts=0\ttype=nacked\tseqs=3\t.\nseq=6\tts=0\ttype=claimed\tseqs=3\t.\nseq=7\tts=0\ttype=acked\tseqs=3\t.\n' >> "$TMP/log"
assert "$(awk -v mode=undelivered -f "$MODEL" "$TMP/log" | wc -l)" "0"
assert "$(awk -v mode=inflight -f "$MODEL" "$TMP/log")" ""

echo "  model ok"
