#!/usr/bin/env bash
# Slice ledger: the coordinator's memory. state.sh is the ONLY parser; the LLM
# reads its one-line outputs, never the TSV.
#
#   state.sh add <id> "<goal>" [--blockers 1,2]
#   state.sh ready                      -> unlock todo slices whose blockers are terminal
#   state.sh next                       -> ready ids (space-separated)
#   state.sh get <id> <field>
#   state.sh dispatch <id> <pid> <wt> <branch> <task>
#   state.sh review <id> <round>
#   state.sh verdict <id> <round> <pass|handback> <head>
#   state.sh merged <id> <sha>
#   state.sh blocked <id>
#   state.sh resolve <task>                    -> the slice id, or exit 1
#       (exact ledger id; else trailing -<suffix> stripped; else an error
#        listing the rejected candidates — never a guess)
#   state.sh drop <id>
#   state.sh list                       -> "id <TAB> status <TAB> pid <TAB> verdict <TAB> goal"
#   state.sh done                       -> exit 0 iff every slice is merged|dropped
#   state.sh render                     -> write COORDINATION.md
#
# Row: id \t status \t blockers \t task \t round \t worktree \t branch \t pid \t head \t verdict \t merge \t goal
# status: todo | ready | dispatched | reviewing | handback | merged | blocked | dropped
set -euo pipefail

ledger="${COORD_LEDGER:-$PWD/.coordinator/ledger.tsv}"
dashboard="${COORD_DASHBOARD:-$PWD/COORDINATION.md}"

cmd="${1:-}"; shift || true

# Read-only queries are often predicates; a false predicate is not a failure.
case "$cmd" in
  add|ready|dispatch|review|verdict|merged|blocked|drop|render)
    source "$(dirname "${BASH_SOURCE[0]}")/progress.sh"
    progress_start "state.$cmd" "slice=${1:--}"
    case "$cmd" in
      verdict) progress_context="slice=${1:--} round=${2:--} verdict=${3:--}" ;;
      blocked) progress_result=WAIT; progress_note="slice is blocked; coordinator must explain the blocker" ;;
    esac
    ;;
esac

writable() { mkdir -p "$(dirname "$ledger")"; [ -f "$ledger" ] || : > "$ledger"; }

mutate() { # mutate <id> <awk-body> [awk -v assignments...]
  local id="$1" body="$2"; shift 2
  [ -f "$ledger" ] || exit 1
  local tmp
  tmp="$(mktemp "${ledger}.XXXXXX")"
  awk -F'\t' -v OFS='\t' -v id="$id" "$@" "$body" "$ledger" > "$tmp"
  mv -T -- "$tmp" "$ledger"
}

field_num() {
  case "$1" in
    id) echo 1 ;; status) echo 2 ;; blockers) echo 3 ;; task) echo 4 ;;
    round) echo 5 ;; worktree) echo 6 ;; branch) echo 7 ;; pid) echo 8 ;;
    head) echo 9 ;; verdict) echo 10 ;; merge) echo 11 ;; goal) echo 12 ;;
    *) echo "state: unknown field: $1" >&2; exit 2 ;;
  esac
}

case "$cmd" in
  add)
    id="${1:?id}"; goal="${2:-}"; shift 2 || true
    blockers="-"
    while [ $# -gt 0 ]; do
      case "$1" in
        --blockers) blockers="$2"; shift 2 ;;
        *) echo "state: unknown arg: $1" >&2; exit 2 ;;
      esac
    done
    writable
    if awk -F'\t' -v id="$id" '$1==id { found=1 } END { exit(found ? 0 : 1) }' "$ledger"; then
      echo "state: id already exists: $id" >&2
      exit 1
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" todo "$blockers" "" 1 "" "" "" "" "" "" "$goal" >> "$ledger"
    printf 'ADDED %s\n' "$id"
    ;;

  ready)
    writable
    tmp="$(mktemp "${ledger}.XXXXXX")"
    rf="$(mktemp)"
    awk -F'\t' -v OFS='\t' -v readyfile="$rf" '
      NR==FNR { st[$1] = $2; next }
      {
        if ($2 == "todo") {
          ok = 1
          n = split($3, b, ",")
          for (i = 1; i <= n; i++) {
            bid = b[i]
            if (bid == "-" || bid == "") continue
            s = st[bid]
            if (s != "merged" && s != "dropped") ok = 0
          }
          if (ok) { $2 = "ready"; print $1 > readyfile }
        }
        print
      }
    ' "$ledger" "$ledger" > "$tmp"
    mv -T -- "$tmp" "$ledger"
    if [ -s "$rf" ]; then
      printf 'READY %s\n' "$(paste -sd' ' - < "$rf")"
    fi
    rm -f "$rf"
    ;;

  next)
    [ -f "$ledger" ] || exit 0
    awk -F'\t' '$2 == "ready" { print $1 }' "$ledger" | paste -sd' ' -
    ;;

  get)
    id="${1:?id}"; field="${2:?field}"
    n="$(field_num "$field")"
    awk -F'\t' -v id="$id" -v n="$n" '
      $1 == id { print $n; found = 1 }
      END { if (!found) exit 1 }
    ' "$ledger"
    ;;

  dispatch)
    id="${1:?id}"; pid="${2:-}"; wt="${3:-}"; branch="${4:-}"; task="${5:-}"
    mutate "$id" '$1==id { $2="dispatched"; $4=task; $6=wt; $7=branch; $8=pid } { print }' \
      -v pid="$pid" -v wt="$wt" -v branch="$branch" -v task="$task"
    printf 'DISPATCHED %s\n' "$id"
    ;;

  review)
    id="${1:?id}"; round="${2:?round}"
    mutate "$id" '$1==id { $2="reviewing"; $5=round } { print }' -v round="$round"
    printf 'REVIEWING %s\n' "$id"
    ;;

  verdict)
    id="${1:?id}"; round="${2:?round}"; v="${3:?pass|handback}"; head="${4:-}"
    if [ "$v" = "pass" ]; then
      mutate "$id" '$1==id { $2="reviewing"; $5=round; $9=head; $10="pass" } { print }' \
        -v round="$round" -v head="$head"
    else
      mutate "$id" '$1==id { $2="handback"; $5=round; $9=head; $10="handback" } { print }' \
        -v round="$round" -v head="$head"
    fi
    printf 'VERDICT %s %s\n' "$id" "$v"
    ;;

  merged)
    id="${1:?id}"; sha="${2:-}"
    mutate "$id" '$1==id { $2="merged"; $11=sha } { print }' -v sha="$sha"
    printf 'MERGED %s\n' "$id"
    ;;

  blocked)
    id="${1:?id}"
    mutate "$id" '$1==id { $2="blocked" } { print }'
    printf 'BLOCKED %s\n' "$id"
    ;;

  drop)
    id="${1:?id}"
    mutate "$id" '$1==id { $2="dropped" } { print }'
    printf 'DROPPED %s\n' "$id"
    ;;

  resolve)
    # task -> slice id, mechanically; the coordinator never guesses.
    # Decorations: a trailing `-<suffix>` (codex worktree suffix, issue #18)
    # or a trailing `.<round>` (round-2 slugs) both reduce to the base id.
    task="${1:?task}"
    [ -f "$ledger" ] || { echo "resolve: no ledger at $ledger" >&2; exit 1; }
    ledger_has() { awk -F'\t' -v id="$1" '$1==id { f=1 } END { exit(f ? 0 : 1) }' "$ledger"; }
    if ledger_has "$task"; then printf '%s\n' "$task"; exit 0; fi
    for cand in "${task%-*}" "${task%%.*}"; do
      [ -n "$cand" ] && [ "$cand" != "$task" ] && ledger_has "$cand" && { printf '%s\n' "$cand"; exit 0; }
    done
    # neither an id nor an id-plus-decoration is a protocol error: surface the
    # rejected candidates, never resolve to a guess
    echo "resolve: no ledger id for '$task' (rejected: exact id; '-<suffix>' base '${task%-*}'; '.<round>' base '${task%%.*}')" >&2
    exit 1
    ;;

  list)
    [ -f "$ledger" ] || exit 0
    awk -F'\t' -v OFS='\t' '{ print $1, $2, $8, $10, $12 }' "$ledger"
    ;;

  done)
    [ -f "$ledger" ] || exit 0
    awk -F'\t' '$2 != "merged" && $2 != "dropped" { bad = 1 } END { exit(bad ? 1 : 0) }' "$ledger"
    ;;

  render)
    [ -f "$ledger" ] || exit 0
    mkdir -p "$(dirname "$dashboard")"
    {
      printf '# COORDINATION\n\n'
      printf '| id | status | round | verdict | head | merge | goal |\n'
      printf '|---|---|---|---|---|---|---|\n'
      awk -F'\t' '{ printf "| %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $5, $10, $9, $11, $12 }' "$ledger"
    } > "$dashboard"
    printf 'RENDERED %s\n' "$dashboard"
    ;;

  *)
    echo "usage: state.sh add|ready|next|get|dispatch|review|verdict|merged|blocked|drop|resolve|list|done|render" >&2
    exit 2
    ;;
esac
