# Sourced by every test: a temp dir, the coord binary, assertions, and (via
# setup_run) a git repo with a fake harness that plays every role.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
export COORD="$ROOT/bin/coord"
TMP="$(mktemp -d)"
# never read this machine's harness state: no codex model list, no skills
export CODEX_HOME="$TMP/codex-home" CLAUDE_CONFIG_DIR="$TMP/claude-home" COORD_ROLES="$TMP/roles.conf"
cleanup() {
  pkill -f -- "$TMP/" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

assert() { [ "$1" = "$2" ] || { echo "  assert failed: '$1' != '$2'"; exit 1; }; }
has() { case "$1" in *"$2"*) ;; *) echo "  expected '$2' in: $1"; exit 1 ;; esac; }
hasnt() { case "$1" in *"$2"*) echo "  unexpected '$2' in: $1"; exit 1 ;; esac; }
# refuses <substring> <cmd...>: the command must fail with the substring on stderr
refuses() {
  local want="$1"; shift
  if "$@" >/dev/null 2>"$TMP/err"; then echo "  expected refusal: $*"; exit 1; fi
  grep -qF -- "$want" "$TMP/err" || { echo "  wanted '$want', got:"; cat "$TMP/err"; exit 1; }
}
wait_for() { # wait_for <cmd...>: poll up to 10s
  local i
  for i in $(seq 1 100); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done
  echo "  timed out waiting for: $*"; exit 1
}
state_of() { "$COORD" status | awk -v id="$1" '$1=="UNIT" && $2==id {print $3}'; }
is_state() { [ "$(state_of "$1")" = "$2" ]; }

# setup_run: $REPO (main, one commit), .coordinator config, the fake harness.
setup_run() {
  export COORD_HOME="$TMP/home" COORD_ENV_CONF="$TMP/home/env.conf"
  export REPO="$TMP/repo"
  export COORD_EVENTS="$REPO/.coordinator/events.log"
  export COORD_AGENTS="$TMP/no-agents"
  export FAKE_DIR="$TMP/fake"
  mkdir -p "$COORD_HOME" "$REPO" "$TMP/bin" "$FAKE_DIR"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email t@t
  git -C "$REPO" config user.name t
  echo base > "$REPO/file.txt"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m init
  mkdir -p "$REPO/.coordinator"

  # the fake harness: acts on the slug it owes (COORD_OWES) per FAKE_* env
  cat > "$TMP/bin/fake" <<'FAKE'
#!/usr/bin/env bash
prompt="${@: -1}"
printf '%s\n' "$prompt" > "$FAKE_DIR/prompt.${COORD_OWES:-none}"
case "${COORD_OWES:-}" in
  *.worker)   act="${FAKE_WORKER:-done}" ;;
  *.critic)   act="${FAKE_CRITIC:-pass}" ;;
  research.*) act="${FAKE_RESEARCH:-report}" ;;
  *) exit 0 ;;
esac
case "$act" in
  done)     echo "change by $COORD_OWES" >> file.txt
            exec "$COORD" finish --result done --summary "did it" ;;
  partial)  exec "$COORD" finish --result partial --summary "half done" ;;
  pass)     exec "$COORD" finish --result pass --evidence tests --ran "test -f file.txt" --summary "looks right" ;;
  weakpass) exec "$COORD" finish --result pass --evidence typecheck --ran "true" --summary "compiles" ;;
  handback) exec "$COORD" finish --result handback --summary "needs tests" ;;
  report)   report="$(printf '%s\n' "$prompt" | sed -n 's/^Write your decision brief to \(.*\), then:$/\1/p')"
            echo "# decision: option B" > "$report"
            exec "$COORD" finish --result done --summary "recommend B" ;;
  exit)     exit 0 ;;
  sleep)    sleep 30 ;;
esac
FAKE
  chmod +x "$TMP/bin/fake"
  export PATH="$TMP/bin:$PATH"

  cat > "$COORD_ENV_CONF" <<ENV
current=fake
harness.fake.bin=$TMP/bin/fake
harness.fake.exec=fake|__PROMPT__
harness.fake.resume=fake-resume|__SESSION__|__BATCH__
ENV
  cat > "$REPO/.coordinator/config.conf" <<CONF
critic.harness=fake
researcher.harness=fake
lane.default.harness=fake
autonomy=approve-merge
merge.base=main
timebox.grace=1s
CONF
}

# brief <file> [kind]: a complete brief (CONTEXT is coordinator framing the
# critic must never see)
brief() {
  cat > "$1" <<'BRIEF'
Please do the thing.
GOAL: file.txt gains a line
SCOPE: file.txt only
CONTEXT: coordinator framing: the user is impatient
REPRO: cat file.txt shows one line
ACCEPTANCE: file.txt has more than one line
VERIFY:
  $ test "$(wc -l < file.txt)" -gt 1
BRIEF
}

# fake coordinator resume: records its argv
fake_resume() {
  export RELAY_LOG="$TMP/resume.log"
  : > "$RELAY_LOG"
  cat > "$TMP/bin/fake-resume" <<'RES'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RELAY_LOG"
RES
  chmod +x "$TMP/bin/fake-resume"
  export COORD_RESUME="fake-resume|__SESSION__|__BATCH__"
  export COORD_SESSION="sess-1"
}
