#!/usr/bin/env bash
# Resolve first-match rules; also supplies assembly helpers to filter/spawn.
set -euo pipefail

changed_files() {
  local tracked untracked
  tracked="$(git -C "$1" diff --name-only "$2...HEAD")" || return 1
  untracked="$(git -C "$1" ls-files --others --exclude-standard)" || return 1
  printf '%s\n%s\n' "$tracked" "$untracked" | LC_ALL=C sort -u | sed '/^$/d'
}

# Small JSON reader for rules arrays, or {"rules": [...], "exclude": [...]}.
# Parse strings rather than splitting on punctuation inside rule text.
json_space() { while [[ ${json:pos:1} == [$' \t\r\n'] ]]; do pos=$((pos + 1)); done; }
json_error() { echo 'rules.sh: invalid rules.json' >&2; return 1; }
json_string() {
  local c escape hex
  value=''
  [[ ${json:pos:1} == '"' ]] || { json_error; return 1; }
  pos=$((pos + 1))
  while (( pos < ${#json} )); do
    c=${json:pos:1}; pos=$((pos + 1))
    case "$c" in
      '"') return 0 ;;
      '\')
        escape=${json:pos:1}; pos=$((pos + 1))
        case "$escape" in
          '"'|'\'|/) value+="$escape" ;;
          b) value+=$'\b' ;; f) value+=$'\f' ;; n) value+=$'\n' ;;
          r) value+=$'\r' ;; t) value+=$'\t' ;;
          u)
            hex=${json:pos:4}
            [[ $hex =~ ^[[:xdigit:]]{4}$ && $hex != 0000 ]] || { json_error; return 1; }
            printf -v c '%b' "\u$hex"; value+="$c"; pos=$((pos + 4)) ;;
          *) json_error; return 1 ;;
        esac ;;
      *) [[ $c != [[:cntrl:]] ]] || { json_error; return 1; }; value+="$c" ;;
    esac
  done
  json_error
}
json_value() {
  local context=${1:-} key path='' rule='' has_rule=false close
  json_space
  case ${json:pos:1} in
    '"') json_string || return 1
      case "$context" in exclude) excludes+=("$value");; esac ;;
    '['|'{')
      close=']'; [[ ${json:pos:1} != '{' ]] || close='}'
      pos=$((pos + 1)); json_space
      if [[ ${json:pos:1} == "$close" ]]; then pos=$((pos + 1)); return 0; fi
      while :; do
        key=$context
        if [[ $close == '}' ]]; then
          json_string || return 1; key=$value; json_space
          [[ ${json:pos:1} == ':' ]] || { json_error; return 1; }
          pos=$((pos + 1))
        fi
        json_value "$key" || return 1
        if [[ $close == '}' ]]; then
          case "$key" in path) path=$value ;; rule) rule=$value; has_rule=true ;; esac
        fi
        json_space
        if [[ ${json:pos:1} == "$close" ]]; then pos=$((pos + 1)); break; fi
        [[ ${json:pos:1} == ',' ]] || { json_error; return 1; }
        pos=$((pos + 1)); json_space
      done
      if [[ $close == '}' && $has_rule == true ]]; then
        rule_paths+=("$path"); rule_texts+=("$rule")
      fi ;;
    *) json_error; return 1 ;;
  esac
}
read_rules() {
  rule_paths=(); rule_texts=(); excludes=()
  local json pos=0 value=''
  [ -f "$1/.coordinator/rules.json" ] || return 0
  json="$(cat "$1/.coordinator/rules.json")"
  json_value || return 1
  json_space
  (( pos == ${#json} )) || { json_error; return 1; }
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  wt=${1:?worktree}; base=${2:?base}
  [ -f "$wt/.coordinator/rules.json" ] || exit 0
  changes="$(changed_files "$wt" "$base")"
  read_rules "$wt"
  printf '## Rules for this slice\n'
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    for ((i=0; i<${#rule_paths[@]}; i++)); do
      case "$path" in
        ${rule_paths[i]}) printf '%s — %s\n' "$path" "${rule_texts[i]}"; break ;;
      esac
    done
  done <<< "$changes"
fi
