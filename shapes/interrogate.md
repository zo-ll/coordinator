# Shape: interrogate

Extra independent reviewers on a unit that passed, before the user is asked
to approve it. For changes where a miss is expensive (security, migrations,
concurrency, money) or when the user asks to stress-test one. Not for every
unit: the critic is the review.

1. When the unit is `passed`, ask two or three read-only reviewers (helpers,
   on different models if you can), each given the worktree, GOAL, SCOPE,
   and ACCEPTANCE and a different focus: correctness; concurrency and
   failure paths; security and data safety. Concrete defects only: location,
   failure mode, smallest fix.
2. Sort the findings: **act on** what two reviewers raised (the critic
   counts as one) or one proved with a failing command; **consider** the
   plausible single ones; **dismiss** style and out-of-SCOPE.
3. Anything to act on: `coord reject <unit> "<the findings>"`, then a
   correction brief listing each one. Otherwise ask the user to approve,
   listing the *consider* items.
