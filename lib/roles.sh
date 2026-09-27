# roles.sh: who each role agent is (harness, model, skills), layered: the
# repo's config.conf over the user's roles.conf (sourced by bin/coord).
#
# Roles: worker (lane default), worker:<lane>, critic, researcher; their
# config prefixes: lane.default, lane.<lane>, critic, researcher.

ROLES_GLOBAL=${COORD_ROLES:-$COORD_HOME/roles.conf}

cfg_keys() { [ ! -f "$1" ] || "$SKILL/libexec/cfg.sh" keys "$1"; }

# role_prefix <role>: its config prefix, or 1
role_prefix() {
  case "$1" in
    worker) echo lane.default ;;
    worker:*) [[ ${1#worker:} =~ ^[a-z][a-z0-9_-]*$ ]] && echo "lane.${1#worker:}" ;;
    critic|researcher) echo "$1" ;;
    *) return 1 ;;
  esac
}

# role_get <prefix> <field>: the repo's value, else the user's; empty counts
# as unset, so a repo keeps the user's model unless it sets one
role_get() {
  local v
  v=$(cfg_val "$CONFIG" "$1.$2")
  [ -n "$v" ] || v=$(cfg_val "$ROLES_GLOBAL" "$1.$2")
  printf '%s' "$v"
}

# skill_dirs <harness>: where skills live, the harness's own first
skill_dirs() {
  local ch=${CLAUDE_CONFIG_DIR:-$HOME/.claude} cx=${CODEX_HOME:-$HOME/.codex}
  case "$1" in
    claude)   echo "$REPO/.claude/skills"; echo "$ch/skills" ;;
    codex)    echo "$REPO/.codex/skills"; echo "$cx/skills" ;;
    pi)       echo "$REPO/.pi/skills"; echo "$HOME/.pi/agent/skills" ;;
    opencode) echo "$REPO/.opencode/skills"; echo "$HOME/.config/opencode/skills" ;;
  esac
  printf '%s\n' "$REPO/.agents/skills" "$HOME/.agents/skills" "$ch/skills" "$cx/skills" \
    "$HOME/.pi/agent/skills" "$HOME/.config/opencode/skills"
}

# skill_path <harness> <name>: the SKILL.md a role on <harness> reads, or 1
skill_path() {
  local d
  [[ $2 =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  while IFS= read -r d; do
    [ -f "$d/$2/SKILL.md" ] && { printf '%s' "$d/$2/SKILL.md"; return 0; }
  done < <(skill_dirs "$1")
  return 1
}

# skills_block <prefix> <harness>: the prompt section naming the role's skills
skills_block() {
  local s p out=""
  local IFS=,
  for s in $(role_get "$1" skills); do
    [ -n "$s" ] || continue
    p=$(skill_path "$2" "$s") || { printf 'SKILL_MISSING %s\n' "$s"; return 1; }
    out+="- $s: $p"$'\n'
  done
  [ -z "$out" ] || printf 'SKILLS (read each before you start and apply it to this task):\n%s' "$out"
}

role_line() { # role_line <role>
  local p; p=$(role_prefix "$1")
  printf 'ROLE %s harness=%s model=%s skills=%s\n' "$1" "$(role_get "$p" harness)" \
    "$(role_get "$p" model)" "$(role_get "$p" skills)"
}

#   role                          -> one ROLE line per role
#   role <role> [--global] [--harness H] [--model M] [--skill S]... [--drop-skill S]...
#     -> ROLE <role> harness=... model=... skills=...
cmd_role() {
  local role=${1:-} p file h m skills s l
  if [ -z "$role" ]; then
    role_line worker
    for l in $( { cfg_keys "$CONFIG"; cfg_keys "$ROLES_GLOBAL"; } | sed -n 's/^lane\.\([^.]*\)\.harness$/\1/p' | sort -u); do
      [ "$l" = default ] || role_line "worker:$l"
    done
    role_line critic; role_line researcher
    return 0
  fi
  shift
  p=$(role_prefix "$role") || { fail 2 'role: unknown role "%s" (worker, worker:<lane>, critic, researcher)' "$role"; return; }
  parse_args role "harness model" "skill drop-skill" "global" "$@"
  file=$CONFIG; [ "${F[global]:-0}" = 1 ] && file=$ROLES_GLOBAL
  h=${F[harness]:-$(role_get "$p" harness)}
  m=${F[model]-$(role_get "$p" model)}
  if [ -n "${F[harness]:-}" ] && [ -z "$(cfg_val "$ENV_CONF" "harness.$h.bin")" ]; then
    refuse "" role "\"$h\" is not a spawnable harness here (coord init detects them)"; return
  fi
  if [ -n "${F[harness]:-}${F[model]+x}" ] && [ -n "$h" ]; then
    local why; why=$("$SKILL/libexec/models.sh" "$h" "$m" 2>&1 >/dev/null) || [ $? = 2 ] || { refuse "" role "$why"; return; }
  fi
  skills=$(cfg_val "$file" "$p.skills")
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    skill_path "${h:-none}" "$s" >/dev/null || { refuse "" role "no skill \"$s\" (coord skills $role lists them)"; return; }
    [[ ,$skills, == *",$s,"* ]] || skills+="${skills:+,}$s"
  done <<< "${FM[skill]:-}"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    skills=$(tr , '\n' <<< "$skills" | grep -vx -- "$s" | paste -sd, - || true)
  done <<< "${FM[drop-skill]:-}"
  mkdir -p "$(dirname "$file")"
  [ -z "${F[harness]:-}" ] || "$SKILL/libexec/cfg.sh" set "$file" "$p.harness" "$h" >/dev/null
  [ -z "${F[model]+x}" ] || "$SKILL/libexec/cfg.sh" set "$file" "$p.model" "$m" >/dev/null
  [ -z "${FM[skill]:-}${FM[drop-skill]:-}" ] || "$SKILL/libexec/cfg.sh" set "$file" "$p.skills" "$skills" >/dev/null
  role_line "$role"
}

#   skills [<role>]  -> SKILL <name> <path>, one per skill that role's harness can read
cmd_skills() {
  local role=${1:-worker} p h d n
  p=$(role_prefix "$role") || { fail 2 'skills: unknown role "%s"' "$role"; return; }
  h=$(role_get "$p" harness)
  while IFS= read -r d; do
    for n in "$d"/*/SKILL.md; do [ ! -f "$n" ] || printf '%s\t%s\n' "$(basename "$(dirname "$n")")" "$n"; done
  done < <(skill_dirs "${h:-none}") | awk -F'\t' '!seen[$1]++ { print "SKILL " $1 " " $2 }'
}
