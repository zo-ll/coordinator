#!/usr/bin/env bash
# compute-verdict.sh + finish.sh --role critic: verdict derived from
# structured findings, not a free-form mood call (issues #8, #9, #13).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CV="$HERE/../scripts/compute-verdict.sh"
FIN="$HERE/../scripts/finish.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

n=0
new_wt() {
  n=$((n + 1))
  local wt="$TMP/wt-$n"
  mkdir -p "$wt/.scratch"
  printf '%s' "$wt"
}

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }
contains() { case "$1" in *"$2"*) ;; *) echo "  '$1' does not contain '$2'"; exit 1 ;; esac; }
result_of() { printf '%s\n' "$1" | sed -n 's/^RESULT //p'; }
rollup_of() { printf '%s\n' "$1" | sed -n 's/^ROLLUP //p'; }
coverage_of() { printf '%s\n' "$1" | sed -n 's/^COVERAGE //p'; }

# 1. pass from all-low/empty findings
wt="$(new_wt)"
cat > "$wt/.scratch/verdict.md" <<'EOF'
REVIEWED a.txt
EOF
out="$(COORD_CHANGES="a.txt" "$CV" "$wt" s1)"
assert "$(result_of "$out")" "pass"

cat > "$wt/.scratch/verdict.md" <<'EOF'
FINDING a.txt:1-2 severity=low category=style existing="foo"
REVIEWED a.txt
EOF
out="$(COORD_CHANGES="a.txt" "$CV" "$wt" s1)"
assert "$(result_of "$out")" "pass"

# 2. handback from a single high
wt="$(new_wt)"
cat > "$wt/.scratch/verdict.md" <<'EOF'
FINDING a.txt:1-2 severity=high category=bug existing="foo"
REVIEWED b.txt
EOF
out="$(COORD_CHANGES="a.txt b.txt" "$CV" "$wt" s1)"
assert "$(result_of "$out")" "handback"
assert "$(rollup_of "$out")" "1 high"

# 3. stated-pass vs derived-handback mismatch -> finish.sh exits 2, no marker
export COORD_ROOT="$TMP/coord3"
if (cd "$wt" && "$FIN" --event s3.critic --role critic --result pass --head abc --summary x 2>"$TMP/err3"); then
  echo "  mismatch accepted"; exit 1
fi
grep -qi 'does not match' "$TMP/err3" || { echo "  unclear mismatch error:"; cat "$TMP/err3"; exit 1; }
[ ! -e "$wt/.scratch/status/s3.critic.done" ] || { echo "  marker written on protocol error"; exit 1; }

# 4. coverage hole (a changed path with no finding/reviewed line) downgrades pass -> handback
wt="$(new_wt)"
cat > "$wt/.scratch/verdict.md" <<'EOF'
REVIEWED a.txt
EOF
out="$(COORD_CHANGES="a.txt b.txt" "$CV" "$wt" s1)"
assert "$(result_of "$out")" "handback"
assert "$(coverage_of "$out")" "hole"

# 5. EXCLUDED without a reason is a coverage hole; with a reason it's fine
wt="$(new_wt)"
cat > "$wt/.scratch/verdict.md" <<'EOF'
EXCLUDED a.txt
EOF
out="$(COORD_CHANGES="a.txt" "$CV" "$wt" s1)"
assert "$(result_of "$out")" "handback"
assert "$(coverage_of "$out")" "hole"

cat > "$wt/.scratch/verdict.md" <<'EOF'
EXCLUDED a.txt generated file, not reviewable
EOF
out="$(COORD_CHANGES="a.txt" "$CV" "$wt" s1)"
assert "$(result_of "$out")" "pass"
assert "$(coverage_of "$out")" "ok"

# 6. rollup string appears in the enqueued ping line
wt="$(new_wt)"
cat > "$wt/.scratch/verdict.md" <<'EOF'
FINDING a.txt:1-2 severity=high category=bug existing="foo"
FINDING a.txt:3-4 severity=high category=bug existing="bar"
FINDING b.txt:1-1 severity=medium category=style existing="baz"
EOF
export COORD_ROOT="$TMP/coord6"
export COORD_CHANGES="a.txt b.txt"
(cd "$wt" && "$FIN" --event s6.critic --role critic --result handback --head deadbeef --summary 'needs work' >/dev/null)
ping="$(cat "$COORD_ROOT/queue/"*.ping)"
contains "$ping" "2 high, 1 medium"
assert "$ping" "VERDICT s6: handback: 2 high, 1 medium @ deadbeef — needs work"

echo "  verdict ok"
