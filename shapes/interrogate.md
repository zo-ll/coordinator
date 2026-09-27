# Shape: interrogate

Extra independent reviewers on a unit that passed, before the user is asked
to approve it. Agreement between reviewers is the signal.

**Use when** a unit is risky enough that one critic isn't enough: security,
data migrations, concurrency, money, anything hard to undo after merge. Also
when the user asks to "stress test" or "tear apart" a change.

**How**

1. When the unit is `passed`, ask two or three reviewers, each a read-only
   helper (your harness's native subagents if it has them, on different
   models if it allows; else `coord research` launches). Give each the unit's
   worktree and its criteria (GOAL, SCOPE, ACCEPTANCE), ask for concrete
   defects only (location, failure mode, smallest fix), and a different
   focus: correctness, concurrency and failure paths, security and data
   safety. Reviewers only read and run; they never edit.
2. Read the reports (they are findings, not diffs). Sort them:
   - **act on**: raised by two or more reviewers (the critic counts as one),
     or a single proven defect with a failing command;
   - **consider**: plausible, raised once, no proof;
   - **dismiss**: style, preference, out of SCOPE.
3. If anything is *act on*: `coord reject <unit> "<the findings>"` (this puts
   them in the log, whoever the reviewers were), then write
   a correction brief that lists each finding with its location. The next
   round gets a fresh critic as usual.
4. Otherwise report to the user: the unit passed review and interrogation,
   with the *consider* items listed, and ask for approval.

**Don't** interrogate every unit; it multiplies cost. The critic is the
review; interrogation is for the few units where a miss is expensive.
