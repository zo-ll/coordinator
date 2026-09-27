---
kind=refactor
brief.require=GOAL,SCOPE,ACCEPTANCE,VERIFY
evidence.floor=tests
timebox=45m
lane=default
---
## worker
Behavior must not change. Run the existing tests before and after; do not
edit a test to make it pass unless ACCEPTANCE says the test itself moves.
Migrate every caller, then delete the old path.

## critic
Look for behavior changes: edited assertions, changed defaults, dropped error
paths, reordered side effects. Any unrequested behavior change is a handback.
