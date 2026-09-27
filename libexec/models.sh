#!/usr/bin/env bash
# Is <model> a model <harness> can run?
#
#   models.sh <harness> <model>   exit 0: yes | 1: no (reason on stderr) | 2: cannot tell
#
# codex: its cached model list; pi: `pi --list-models`; claude: an alias or a
# claude-* name. An empty model means the harness default and is always fine.
set -euo pipefail

h=${1:-} m=${2:-}
[ -n "$m" ] || exit 0
case "$h" in
  codex)
    f="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
    [ -r "$f" ] || exit 2
    grep -q "\"slug\": *\"$m\"" "$f" && exit 0
    echo "\"$m\" is not in codex's model list ($f)" >&2; exit 1 ;;
  pi)
    list=$(timeout 15 pi --list-models 2>/dev/null) || exit 2
    id=${m%%:*}
    awk -v id="$id" 'NR > 1 && ($2 == id || $1 "/" $2 == id) { found = 1 } END { exit !found }' <<< "$list" && exit 0
    echo "\"$m\" is not in pi --list-models" >&2; exit 1 ;;
  claude)
    case "$m" in
      claude-*|opus|sonnet|haiku|fable|opus\[1m\]|sonnet\[1m\]|default|best|opusplan) exit 0 ;;
    esac
    echo "\"$m\" is not a claude model (use an alias like sonnet or opus, or a claude-* name)" >&2; exit 1 ;;
  *) exit 2 ;;
esac
