#!/usr/bin/env bash
# verify-quotes.sh (issue #10): quotes must exist in the worktree at the
# stated lines. Deterministic grep gate, no LLM.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VQ="$HERE/../scripts/verify-quotes.sh"
CV="$HERE/../scripts/compute-verdict.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WT="$TMP/wt"
mkdir -p "$WT/src" "$WT/.scratch"
cat > "$WT/src/a.txt" <<'EOF'
01: first line
02: second line with marker-here
03: third line
04: fourth
EOF

# findings: one verified (line 2 marker within stated 2-2), one shifted (the
# marker actually at 2 but stated at 4-4), one missing (no such text), one with
# no quote at all
cat > "$WT/.scratch/verdict.md" <<'EOF'
FINDING src/a.txt:2-2 severity=high category=bug existing="second line with marker-here"
FINDING src/a.txt:4-4 severity=medium category=style existing="second line with marker-here"
FINDING src/a.txt:3-3 severity=low category=doc existing="this text does not exist anywhere"
FINDING src/a.txt:1-1 severity=high category=bug
EOF

# staged: git repo not required, skip verbose
out="$("$VQ" "$WT" 2>/dev/null)" || rc=$?
rc="${rc:-0}"
echo "$out" | grep -qx 'QUOTES verified=1 shifted=1 missing=2' \
  || { echo "  bad summary: $(echo "$out" | grep '^QUOTES')"; exit 1; }
echo "$out" | grep -q '^SHIFTED    src/a.txt:4-4 ' || { echo "  no SHIFTED line"; exit 1; }
echo "$out" | grep -q '^UNVERIFIED src/a.txt:3-3 ' || { echo "  no UNVERIFIED line"; exit 1; }
echo "$out" | grep -q 'no existing= quote' || { echo "  quote-less finding not flagged"; exit 1; }
[ "$rc" = 1 ] || { echo "  expected exit 1 on unverified quotes, got $rc"; exit 1; }

# clean run: all verified -> exit 0
cat > "$WT/.scratch/verdict.md" <<'EOF'
FINDING src/a.txt:2-2 severity=high category=bug existing="second line with marker-here"
EOF
out="$("$VQ" "$WT")"
echo "$out" | grep -qx 'QUOTES verified=1 shifted=0 missing=0' || { echo "  clean summary wrong"; exit 1; }

# no findings -> n/a
: > "$WT/.scratch/verdict.md"
out="$("$VQ" "$WT")"
[ "$out" = "QUOTES n/a" ] || { echo "  n/a case wrong: $out"; exit 1; }

# integration: compute-verdict.sh surfaces the QUOTES line
cat > "$WT/.scratch/verdict.md" <<'EOF'
FINDING src/a.txt:2-2 severity=high category=bug existing="second line with marker-here"
FINDING src/a.txt:3-3 severity=low category=doc existing="nonexistent ghost quote"
REVIEWED src/a.txt
EOF
COORD_CHANGES="src/a.txt" "$CV" "$WT" s1 | grep -qx 'QUOTES verified=1 shifted=0 missing=1' \
  || { echo "  compute-verdict did not surface QUOTES"; COORD_CHANGES="src/a.txt" "$CV" "$WT" s1; exit 1; }

echo "  verify-quotes ok"