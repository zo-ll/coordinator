#!/usr/bin/env bash
# filo role / filo skills: per-role harness, model, and skills; the repo's
# config over the user's global roles.conf; skills named in every prompt.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
setup_run
brief "$TMP/brief"
cd "$REPO"
export HOME="$TMP/home"; mkdir -p "$HOME"

# skills: fake has no skill dir of its own, so the shared ones
mkdir -p "$HOME/.agents/skills/code-review" "$CLAUDE_CONFIG_DIR/skills/python" "$REPO/.agents/skills/repo-style"
for d in "$HOME/.agents/skills/code-review" "$CLAUDE_CONFIG_DIR/skills/python" "$REPO/.agents/skills/repo-style"; do
  printf -- '---\nname: x\n---\n' > "$d/SKILL.md"
done
out="$("$FILO" skills critic)"
has "$out" "SKILL code-review $HOME/.agents/skills/code-review/SKILL.md"
has "$out" "SKILL repo-style $REPO/.agents/skills/repo-style/SKILL.md"

# the view: one line per role
assert "$("$FILO" role | grep '^ROLE critic ')" "ROLE critic harness=fake model= skills="

# global defaults apply to every repo; the repo's own setting wins
assert "$("$FILO" role critic --global --skill code-review --model m1)" "ROLE critic harness=fake model=m1 skills=code-review"
grep -qx 'critic.skills=code-review' "$FILO_ROLES" || { echo "  not global"; exit 1; }
assert "$("$FILO" role critic --model m2)" "ROLE critic harness=fake model=m2 skills=code-review"
assert "$("$FILO" role worker --skill python --skill repo-style)" "ROLE worker harness=fake model= skills=python,repo-style"
assert "$("$FILO" role worker --drop-skill python)" "ROLE worker harness=fake model= skills=repo-style"

# refused: unknown role, unknown skill, a harness that isn't here, a model
# the harness doesn't list
refuses 'unknown role "boss"' "$FILO" role boss --model x
refuses 'no skill "nope"' "$FILO" role worker --skill nope
refuses '"ghost" is not a spawnable harness' "$FILO" role critic --harness ghost
printf 'harness.claude.bin=%s\n' "$TMP/bin/fake" >> "$FILO_ENV_CONF"
refuses 'is not a claude model' "$FILO" role critic --harness claude --model gpt-6-luna
assert "$("$FILO" role critic)" "ROLE critic harness=fake model=m2 skills=code-review"

# every prompt names the role's skills with the SKILL.md to read
"$FILO" unit add a --kind chore --goal a >/dev/null
"$FILO" dispatch a --role worker --brief "$TMP/brief" >/dev/null
wait_for is_state a built
grep -q "^- repo-style: $REPO/.agents/skills/repo-style/SKILL.md$" .filo/briefs/a.r1.worker.md || { echo "  worker prompt lacks its skill"; exit 1; }
FAKE_CRITIC=sleep "$FILO" dispatch a --role critic >/dev/null
grep -q "^- code-review: $HOME/.agents/skills/code-review/SKILL.md$" .filo/briefs/a.r1.critic.md || { echo "  critic prompt lacks its skill"; exit 1; }
grep -q 'repo-style' .filo/briefs/a.r1.critic.md && { echo "  critic got the worker's skills"; exit 1; }

# a configured skill that has since disappeared stops the launch, loudly
rm -rf "$REPO/.agents/skills/repo-style"
"$FILO" unit add b --kind chore --goal b >/dev/null
refuses 'lane.default: no skill "repo-style" installed' "$FILO" dispatch b --role worker --brief "$TMP/brief"

echo "  role ok"
