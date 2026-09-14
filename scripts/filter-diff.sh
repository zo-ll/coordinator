#!/usr/bin/env bash
# List deterministic exclusions, retaining a marker for excessive review churn.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/rules.sh"
wt=${1:?worktree}; base=${2:?base}
changes="$(changed_files "$wt" "$base")"
read_rules "$wt"
remaining=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  reason=''
  case "$path" in
    *.png|*.jpg|*.jpeg|*.gif|*.ico|*.pdf|*.zip|*.gz|*.woff|*.woff2|*.exe|*.so|*.o) reason=binary ;;
  esac
  if [ -z "$reason" ] && [ -s "$wt/$path" ] && command -v file >/dev/null 2>&1; then
    encoding="$(file -b --mime-encoding -- "$wt/$path")"
    [ "$encoding" != binary ] || reason=binary
  fi
  if [ -z "$reason" ]; then
    case "${path##*/}" in lockfile*|*.lock|package-lock.json|pnpm-lock.yaml|go.sum) reason=lockfile ;; esac
  fi
  if [ -z "$reason" ]; then
    case "/$path" in */gen/*|*/generated/*) reason=generated ;; esac
  fi
  if [ -z "$reason" ] && [ -f "$wt/$path" ] && [ "$(wc -c < "$wt/$path")" -gt 40960 ]; then reason=too-large; fi
  if [ -z "$reason" ]; then
    for pattern in "${excludes[@]}"; do
      case "$path" in $pattern) reason=user-excluded; break ;; esac
    done
  fi
  if [ -n "$reason" ]; then
    printf '%s — %s\n' "$path" "$reason"
  else
    remaining=$((remaining + 1))
  fi
done <<< "$changes"
if [ "$remaining" -gt 60 ]; then printf 'churn-capped\n'; fi
