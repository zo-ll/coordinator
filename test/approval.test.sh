#!/usr/bin/env bash
# Approval integrity (issue #14): a headless resumed coordinator turn must
# never be able to record its own merge approval. coord.sh approve is the
# only writer of $COORD_ROOT/approvals/<id>, and it refuses under
# COORD_HEADLESS=1 — the env a headless resume runs with. Only a human,
# running coord.sh approve from their own terminal (no COORD_HEADLESS), can
# produce the file merge.sh gates on.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COORD="$HERE/../scripts/coord.sh"
MERGE="$HERE/../scripts/merge.sh"
STATE="$HERE/../scripts/state.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export COORD_ROOT="$TMP/coord"
export COORD_CONFIG="$TMP/repo/.coordinator/config.conf"
export COORD_LEDGER="$TMP/repo/.coordinator/ledger.tsv"
export COORD_REPO="$TMP/repo"
mkdir -p "$(dirname "$COORD_CONFIG")" "$COORD_ROOT"

git init -q -b main "$COORD_REPO"
git -C "$COORD_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$COORD_REPO" config user.email t@t
git -C "$COORD_REPO" config user.name t
printf 'autonomy=approve-merge\nmerge.base=main\n' > "$COORD_CONFIG"

state_hash() { git -C "$1" diff HEAD | sha256sum | cut -d' ' -f1; }

# a fake harness/env.conf, standing in for a real installed harness — approve
# does not consult it, but a resume recipe would live here in a real run.
mkdir -p "$TMP/home/.coordinator"
export COORD_HOME="$TMP/home/.coordinator"
export COORD_ENV_CONF="$COORD_HOME/env.conf"
printf 'current=fakeharness\nharness.fakeharness.resume=echo|__BATCH__\n' > "$COORD_ENV_CONF"

git -C "$COORD_REPO" worktree add -q -b coord/1-s1 "$TMP/wt" main
echo hi > "$TMP/wt/file.txt"
git -C "$TMP/wt" add -A
head="$(state_hash "$TMP/wt")"
"$STATE" add s1 "slice one" >/dev/null
"$STATE" dispatch s1 0 "$TMP/wt" coord/1-s1 s1 >/dev/null
"$STATE" verdict s1 1 pass "$head" >/dev/null

# --- fake headless resume: the coordinator's own resumed turn tries to
# approve the very merge it is asking about. COORD_HEADLESS=1 is the marker
# a headless resume runs under. ---
if COORD_HEADLESS=1 "$COORD" approve s1 >"$TMP/out" 2>"$TMP/err"; then
  echo "  headless turn was able to record its own approval"; exit 1
fi
grep -qi "headless" "$TMP/err" || { echo "  refusal did not explain why:"; cat "$TMP/err"; exit 1; }
[ ! -e "$COORD_ROOT/approvals/s1" ] || { echo "  approvals/s1 exists after a headless attempt"; exit 1; }

if "$MERGE" --slice s1 >/dev/null 2>"$TMP/err2"; then
  echo "  merge proceeded with no recorded approval"; exit 1
fi
grep -q "no recorded user approval" "$TMP/err2" || { echo "  unclear merge refusal:"; cat "$TMP/err2"; exit 1; }
[ "$("$STATE" get s1 status)" != "merged" ] || { echo "  slice merged without approval"; exit 1; }

# --- human path: a real, interactive coord.sh approve (no COORD_HEADLESS) ---
out="$("$COORD" approve s1)"
[ "$out" = "APPROVED s1" ] || { echo "  bad approve output: $out"; exit 1; }
[ -e "$COORD_ROOT/approvals/s1" ] || { echo "  approve did not record approvals/s1"; exit 1; }

out2="$("$MERGE" --slice s1)"
case "$out2" in MERGE\ s1\ base=main\ sha=*) ;; *) echo "  merge did not proceed after approval: $out2"; exit 1 ;; esac
[ "$("$STATE" get s1 status)" = "merged" ] || { echo "  slice not marked merged after approval"; exit 1; }

echo "  approval integrity ok"

# belt-and-suspenders: with an approvals file present, COORD_HEADLESS=1 must
# still refuse (headless turns never self-merge) — issue #14
"$STATE" dispatch s2 1 "$(dirname "$COORD_LEDGER")/../../nothing" coord/s2 main >/dev/null 2>&1 || true
printf 'pre-approved\n' > "$COORD_ROOT/approvals/s2"
if COORD_HEADLESS=1 "$MERGE" --slice s2 >/dev/null 2>"$TMP/hl.err"; then
  echo "  merge must refuse under COORD_HEADLESS=1"; exit 1
fi
grep -q 'COORD_HEADLESS' "$TMP/hl.err" || { echo "  no headless refusal message:"; cat "$TMP/hl.err"; exit 1; }
[ "$("$STATE" get s2 status)" != "merged" ] || { echo "  headless merge marked merged"; exit 1; }
echo "  headless refusal ok"
