---
kind=bugfix
brief.require=GOAL,SCOPE,REPRO,ACCEPTANCE,VERIFY
evidence.floor=tests
evidence.require=red-green
timebox=45m
lane=default
---
## worker
Reproduce first, following REPRO. Write the failing test before the fix and
run it to see it fail. Fix the root cause, not the symptom; if the same defect
exists at other sites, cover them with the same test.

## critic
Prove red-green: run the new test against the base commit (stash the change
or check out the base in a scratch worktree) and confirm it fails there, then
passes on the reviewed state. Only then pass with --flag red-green.
