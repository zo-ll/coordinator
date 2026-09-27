#!/usr/bin/env bash
# Flat key=value config reader/writer. Values are literal (never eval'd), so a
# committed value cannot execute.
#
#   cfg.sh get <file> <key>          -> value (exit 1 if absent)
#   cfg.sh set <file> <key> [value]  -> key=value (empty value allowed)
#   cfg.sh unset <file> <key>
#   cfg.sh keys <file> [prefix]
set -euo pipefail

cmd="${1:-}"; shift || true
file="${1:-}"; shift || true

tmp_for() { mktemp "${file}.XXXXXX"; }

case "$cmd" in
  get)
    key="${1:?key}"
    [ -f "$file" ] || exit 1
    awk -v k="$key" '
      index($0, k"=") == 1 { v = substr($0, length(k) + 2); found = 1 }
      END { if (found) print v; else exit 1 }
    ' "$file"
    ;;

  set)
    key="${1:?key}"
    value="${2:-}"
    [ -f "$file" ] || : > "$file"
    tmp="$(tmp_for)"
    awk -v k="$key" -v v="$value" '
      index($0, k"=") == 1 { if (!done) { print k"="v; done = 1 }; next }
      { print }
      END { if (!done) print k"="v }
    ' "$file" > "$tmp"
    mv -T -- "$tmp" "$file"
    ;;

  unset)
    key="${1:?key}"
    [ -f "$file" ] || exit 0
    tmp="$(tmp_for)"
    awk -v k="$key" 'index($0, k"=") == 1 { next } { print }' "$file" > "$tmp"
    mv -T -- "$tmp" "$file"
    ;;

  keys)
    prefix="${1:-}"
    [ -f "$file" ] || exit 0
    awk -F= -v p="$prefix" '
      /^[[:space:]]*#/ { next }
      /^[[:space:]]*$/ { next }
      { if (p == "" || index($1, p) == 1) print $1 }
    ' "$file"
    ;;

  *)
    echo "usage: cfg.sh get|set|unset|keys <file> ..." >&2
    exit 2
    ;;
esac
