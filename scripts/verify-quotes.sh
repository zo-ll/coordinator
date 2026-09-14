#!/usr/bin/env bash
# Position anchoring (issue #10): verify every critic quote really exists in
# the worktree at the stated location. Deterministic, zero LLM.
#
#   verify-quotes.sh <worktree> [verdict.md]
#
# Reads FINDING lines from the verdict file (default
# <worktree>/.scratch/verdict.md), in the schema used by compute-verdict.sh:
#   FINDING path:start-end severity=… category=… existing="exact quoted code"
# For each finding it greps the quoted text (fixed string, no regex) in
# <worktree>/<path> and checks the matched line falls inside start-end.
#
# Output (stdout):
#   UNVERIFIED <path>:<start-end> — <reason>      (quote absent / no quote)
#   SHIFTED    <path>:<start-end> — quoted text found at lines <n,…>
#   QUOTES verified=<n> shifted=<n> missing=<n>    (summary; "QUOTES n/a" when
#                                                  the verdict has no findings)
# Exit: 0 when every quote is verified (or no findings); 1 when any quote is
# shifted or missing. Problems are also echoed to stderr.
set -euo pipefail

worktree="${1:?usage: verify-quotes.sh <worktree> [verdict.md]}"
verdict_file="${2:-$worktree/.scratch/verdict.md}"
[ -r "$verdict_file" ] || { echo "verify-quotes: no verdict file: $verdict_file" >&2; exit 2; }

verified=0 shifted=0 missing=0 findings=0

log() { echo "$*"; echo "$*" >&2; }

grep_exact_lines() { # <file> <quote> -> matched line numbers (newline separated)
  grep -nF -- "$2" "$1" 2>/dev/null | cut -d: -f1 || true
}

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    FINDING\ *)
      findings=$((findings + 1))
      rest="${line#FINDING }"
      path_range="${rest%% *}"
      path="${path_range%%:*}"
      span="${path_range#*:}"
      start="${span%-*}"; start="${start:-0}"
      end="${span#*-}";   [ "$end" = "$span" ] && end="$start"; end="${end:-$start}"
      quote=""
      case " $rest" in
        *' existing='*)
          quote="${rest##*existing=}"
          quote="${quote#\"}"; quote="${quote%\"}"
          ;;
      esac
      reason=""
      if [ -z "$quote" ]; then
        reason="no existing= quote on the finding line"
      elif [[ "$path" == ..* || "$path" == /* ]]; then
        reason="path escapes the worktree: $path"
      elif [ ! -f "$worktree/$path" ]; then
        reason="file missing in worktree: $path"
      else
        lines="$(grep_exact_lines "$worktree/$path" "$quote")"
        if [ -z "$lines" ]; then
          reason="quoted text not found in $path"
        elif ! awk -v s="$start" -v e="$end" -v ns="$lines" '
            { ok=0; n=split(ns,a,/\n/); for(i=1;i<=n;i++) if (a[i]+0>=s && a[i]+0<=e) ok=1; exit ok?0:1 }' <<<"x"; then
          log "SHIFTED    $path_range — quoted text found at lines $(tr '\n' ' ' <<<"$lines") (stated $start-$end)"
          shifted=$((shifted + 1))
          continue
        fi
      fi
      if [ -n "$reason" ]; then
        log "UNVERIFIED $path_range — $reason"
        missing=$((missing + 1))
      else
        verified=$((verified + 1))
      fi
      ;;
  esac
done < "$verdict_file"

if [ "$findings" -eq 0 ]; then
  echo "QUOTES n/a"
  exit 0
fi
echo "QUOTES verified=$verified shifted=$shifted missing=$missing"
[ "$shifted" -eq 0 ] && [ "$missing" -eq 0 ]