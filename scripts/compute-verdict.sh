#!/usr/bin/env bash
# Derive a critic verdict from structured findings — no LLM mood call.
#
#   compute-verdict.sh <worktree> <slice>
#
# Reads <worktree>/.scratch/verdict.md, written by the critic, in this shape:
#   FINDING path:start-end severity=critical|high|medium|low category=bug|security|performance|maintainability|test|style|doc|other existing="..."
#   REVIEWED path
#   EXCLUDED path reason...
#
# The full changed-file list comes from $COORD_CHANGES (space-separated
# paths), supplied by spawn.sh — used to catch coverage holes (issue #8).
#
# Prints three lines to stdout:
#   RESULT pass|handback
#   ROLLUP <n> critical, <n> high, ...      (severity counts, empty when pass)
#   COVERAGE ok|hole
# Exits 2 on a malformed verdict file (missing, or a FINDING with a bad/absent
# severity) — never guesses.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

worktree="${1:?usage: compute-verdict.sh <worktree> <slice>}"
slice="${2:?usage: compute-verdict.sh <worktree> <slice>}"
: "$slice" # reserved for future per-slice verdict paths; unused for now

verdict_file="$worktree/.scratch/verdict.md"
[ -f "$verdict_file" ] || {
  echo "compute-verdict.sh: missing verdict file: $verdict_file" >&2
  exit 2
}

declare -A found_paths
declare -A covered_paths
crit=0 high=0 med=0 low=0
findings=0
coverage_hole=0

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING\ *)
      findings=$((findings + 1))
      rest="${line#FINDING }"
      path_range="${rest%% *}"
      path="${path_range%%:*}"
      sev=""
      case " $rest" in
        *' severity='*)
          sev="${rest#*severity=}"
          sev="${sev%% *}"
          ;;
      esac
      found_paths["$path"]=1
      case "$sev" in
        critical) crit=$((crit + 1)) ;;
        high) high=$((high + 1)) ;;
        medium) med=$((med + 1)) ;;
        low) low=$((low + 1)) ;;
        *)
          echo "compute-verdict.sh: FINDING missing/invalid severity: $line" >&2
          exit 2
          ;;
      esac
      ;;
    REVIEWED\ *)
      p="${line#REVIEWED }"
      covered_paths["$p"]=1
      ;;
    EXCLUDED\ *)
      rest="${line#EXCLUDED }"
      p="${rest%% *}"
      reason="${rest#"$p"}"
      reason="${reason# }"
      if [ -z "$reason" ]; then
        coverage_hole=1
      else
        covered_paths["$p"]=1
      fi
      ;;
  esac
done < "$verdict_file"

for p in ${COORD_CHANGES:-}; do
  if [ -z "${found_paths[$p]:-}" ] && [ -z "${covered_paths[$p]:-}" ]; then
    coverage_hole=1
  fi
done

result="pass"
if [ "$crit" -gt 0 ] || [ "$high" -gt 0 ]; then
  result="handback"
fi
if [ "$result" = "pass" ] && [ "$coverage_hole" -eq 1 ]; then
  result="handback"
fi

rollup=""
if [ "$result" = "handback" ]; then
  parts=()
  [ "$crit" -gt 0 ] && parts+=("$crit critical")
  [ "$high" -gt 0 ] && parts+=("$high high")
  [ "$med" -gt 0 ] && parts+=("$med medium")
  [ "$low" -gt 0 ] && parts+=("$low low")
  for part in "${parts[@]:-}"; do
    [ -n "$part" ] || continue
    if [ -z "$rollup" ]; then rollup="$part"; else rollup="$rollup, $part"; fi
  done
fi

echo "RESULT $result"
echo "ROLLUP $rollup"
if [ "$coverage_hole" -eq 1 ]; then
  echo "COVERAGE hole"
else
  echo "COVERAGE ok"
fi
# position anchoring (issue #10): surface unverifiable quotes same-line. only
# when findings exist; the standalone verify-quotes.sh prints the detail.
if [ "$findings" -gt 0 ]; then
  "$HERE/verify-quotes.sh" "$worktree" "$verdict_file" 2>/dev/null \
    | grep '^QUOTES ' || true
fi
