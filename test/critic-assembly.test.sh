#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$HERE/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export COORD_ROOT="$TMP/coord" COORD_HOME="$TMP/coord"
export COORD_ENV_CONF="$TMP/env.conf" COORD_CONFIG="$TMP/config.conf"
export COORD_LEDGER="$TMP/ledger.tsv" COORD_AGENTS="$TMP/agents"
export CAPTURE="$TMP/capture"
mkdir -p "$COORD_ROOT" "$COORD_AGENTS"
cat > "$TMP/fake" <<'HARNESS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$COORD_CHANGES" > "$CAPTURE.changes"
printf '%s' "$1" > "$CAPTURE.prompt"
printf '%q ' env "COORD_CHANGES=$COORD_CHANGES" "$0" "$@" > "$CAPTURE.argv"
printf '\n' >> "$CAPTURE.argv"
touch "$CAPTURE.done"
HARNESS
chmod +x "$TMP/fake"
printf 'harness.fake.exec=%s|__PROMPT__\n' "$TMP/fake" > "$COORD_ENV_CONF"
printf 'critic.harness=fake\n' > "$COORD_CONFIG"
printf 'Critic preamble\n' > "$COORD_AGENTS/critic.md"
printf 'Review this slice.\n' > "$TMP/brief"
git init -q -b main "$TMP/repo"
git -C "$TMP/repo" -c user.name=test -c user.email=t@t commit -qm base --allow-empty
git -C "$TMP/repo" worktree add -qb slice "$TMP/wt"
WT="$TMP/wt"
mkdir -p "$WT/src" "$WT/generated" "$WT/.coordinator"
printf '[{"path":"src/*","rule":"Check \\"quotes\\" and commas, too."},{"path":"*","rule":"Fallback"}]\n' > "$WT/.coordinator/rules.json"
# Local rules are configuration, not part of this fixture's changed set.
printf '.coordinator/\n' > "$TMP/repo/.git/info/exclude"
printf 'one\n' > "$WT/src/one.txt"
printf 'lock\n' > "$WT/package-lock.json"
printf 'generated\n' > "$WT/generated/output.txt"
git -C "$WT" add .
git -C "$WT" -c user.name=test -c user.email=t@t commit -qm change
printf 'two\n' > "$WT/src/two.txt"
expected=$'generated/output.txt\npackage-lock.json\nsrc/one.txt\nsrc/two.txt'
"$SCRIPTS/state.sh" add s1 test >/dev/null
args=(--role critic --prompt "$TMP/brief" --worktree "$WT" --slice s1)
"$SCRIPTS/spawn.sh" --preview "${args[@]}" > "$TMP/preview"
"$SCRIPTS/spawn.sh" --preview "${args[@]}" > "$TMP/preview-again"
cmp "$TMP/preview" "$TMP/preview-again"
[ ! -f "$CAPTURE.done" ]
"$SCRIPTS/spawn.sh" "${args[@]}" >/dev/null
for _ in {1..50}; do [ ! -f "$CAPTURE.done" ] || break; sleep 0.1; done
[ -f "$CAPTURE.done" ]
cmp "$TMP/preview" "$CAPTURE.argv"
[ "$(cat "$CAPTURE.changes")" = "$expected" ]
grep -Fxq 'package-lock.json — lockfile' "$CAPTURE.prompt"
grep -Fxq 'generated/output.txt — generated' "$CAPTURE.prompt"
grep -Fxq 'src/one.txt — Check "quotes" and commas, too.' "$CAPTURE.prompt"
[ "$(sed -n '/^## Changed files$/,/^$/p' "$CAPTURE.prompt" | sed '1d;/^$/d')" = "$expected" ]
order="$(grep -E '^(Critic preamble|Review this slice\.|## |FINISH CONTRACT)' "$CAPTURE.prompt")"
[ "$order" = $'Critic preamble\nReview this slice.\n## Changed files\n## Excluded\n## Rules for this slice\nFINISH CONTRACT (do not skip; this is the completion protocol):' ]
# Exercise remaining exclusions and the churn marker without dropping files.
printf '{"rules":[],"exclude":["src/*"]}\n' > "$WT/.coordinator/rules.json"
printf '\000\001' > "$WT/data.bin"
printf '%41000s' text > "$WT/large.txt"
"$SCRIPTS/filter-diff.sh" "$WT" main > "$TMP/exclusions"
grep -Fxq 'src/two.txt — user-excluded' "$TMP/exclusions"
grep -Fxq 'data.bin — binary' "$TMP/exclusions"
grep -Fxq 'large.txt — too-large' "$TMP/exclusions"
mkdir "$WT/many"
for n in {1..61}; do printf 'text\n' > "$WT/many/$n"; done
"$SCRIPTS/filter-diff.sh" "$WT" main > "$TMP/exclusions"
grep -Fxq churn-capped "$TMP/exclusions"
rm "$WT/.coordinator/rules.json"
[ -z "$("$SCRIPTS/rules.sh" "$WT" main)" ]
echo '  critic assembly ok'
