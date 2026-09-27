---
kind=chore
brief.require=GOAL,SCOPE,VERIFY
evidence.floor=none
timebox=20m
lane=default
---
## worker
Keep it mechanical: docs, config, dependency bumps, renames. If the change
turns out to alter behavior, stop and finish with --result partial saying so.

## critic
Confirm the change is what GOAL says and nothing more, and that VERIFY passes.
