# Research protocol (research-first features)

For parked/new features needing a decision before implementation (#33, #71,
#72 style): the coordinator dispatches RESEARCH to the researcher window
(configured model, `.coordinator/config.json`), gets a brief back, and routes
it to the user. Research NEVER commits code and never decides — it returns a
brief.

## Dispatch

1. Write the STUDY to `/tmp/shipwright/<project>/<task>/study.md`:
   - the feature spec + why it exists (from the issue, config-only
     constraints, etc.)
   - acceptance goals / non-goals
   - repo pointers (run loop, contracts, prior decisions, journal entries)
   - OPEN QUESTIONS the researcher must answer
   - the DELIVERABLE PATH for the brief (usually
     `docs/design/<project>/<feature>-research.md` next to the issue, or a
     /tmp path for exploratory items the user hasn't adopted yet)
2. Verify the researcher window is IDLE (prompt, no Working, no queued
   pointer).
3. Deliver a SINGLE-LINE pointer: `researcher: read <study.md> in full,
   execute the researcher procedure, brief to <deliverable path>`.
   Single-line only — pi fragments multi-line pastes (verified).

## Receive

- The researcher pings when done; the brief sits at the deliverable path.
- REQUIRED before accepting completion: READ every delivered part fully and
  compare it to the study's expected sections and questions. Verify all
  expected sections are present, there is no truncation sentinel (such as
  `...[truncated ...]`), the ending is complete, and there is an explicit
  unresolved-questions list (write `None` if every question was resolved).
  A finish marker or ping alone is NOT proof of artifact completeness.
- If anything is missing, record the brief as incomplete and request a
  narrowly scoped completion only after the researcher is idle. Do not
  summarize it to the user as a finished study.
- Once complete, route it to the user with a 5-line condensation
  (recommendation + the possibility spread + risks).
- The user decides (pick a direction, park, or ask for a re-study with
  narrower questions). Research results do NOT create worktrees or
  branches — a decided direction becomes a new issue + slice dispatch.

## Ground rules

- Large studies must be split into named parts with a manifest listing each
  filename, expected sections, and reading order. Cap each part at 8 KB
  (UTF-8 bytes), well below the observed roughly 11 KB truncated artifact;
  this is a conservative working limit, not a provider guarantee. Check
  completeness even below the cap. The manifest and all listed parts form
  ONE deliverable; missing parts mean it is incomplete.
- A study files ONE deliverable per assignment; re-studies get their own study file
  (narrower questions) — never an edit-loop on a live researcher turn.
- If the researcher handbacks (missing deliverable path/questions), fix the
  study and re-dispatch only when idle.
- Research is severable: give the study, never your lean — the brief should
  survive being wrong about what you assumed.
